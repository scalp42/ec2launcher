#!/usr/bin/ruby

require 'rubygems'

require 'optparse'
require 'ostruct'

require 'json'

require 'aws-sdk'

AWS_KEYS = "/etc/aws/startup_runner_keys"

class InitOptions
	def initialize
	    @opts = OptionParser.new do |opts|
	    	opts.banner = "Usage: #{__FILE__} [SETUP.JSON] [options]"
	    	opts.separator ""

	    	opts.on("-e", "--environment ENV", "The environment for the server.") do |env|
	    		@options.environ = env
	    	end

	    	opts.on("-a", "--application NAME", "The name of the application class for the new server.") do |app_name|
	    		@options.application = app_name
	    	end

	    	opts.on("-h", "--hostname NAME", "The name for the new server.") do |hostname|
	    		@options.hostname = hostname
	    	end

			opts.separator ""
	    	opts.separator "Additional launch options:"

			opts.on("-c", "--clone HOST", "Clone the latest snapshots from a specific host.") do |clone_host|
				@options.clone_host = clone_host
			end

	      	opts.separator ""
	      	opts.separator "Common options:"

	      	# No argument, shows at tail.  This will print an options summary.
	      	# Try it and see!
	      	opts.on_tail("-?", "--help", "Show this message") do
	        	puts opts
	        	exit
	    	end    	
	    end
	end

	def parse(args)
		@options = OpenStruct.new

		@options.environ = nil
		@options.application = nil
		@options.hostname = nil

		@options.clone_host = nil

		@opts.parse!(args)
		@options
	end

	def help
		puts @opts
	end
end

##############################
# Wrapper that retries failed calls to AWS
# with an exponential back-off rate.
def retry_aws_with_backoff(&block)
	timeout = 1
	result = nil
	while timeout < 33 && result.nil?
		begin
	  		result = yield
		rescue AWS::Errors::ServerError
			puts "Error contacting Amazon. Sleeping #{timeout} seconds."
			sleep timeout
			timeout *= 2
			result = nil
		end
	end
	result
end


# Runs a command and displays the output line by line
def run_command(cmd)
  IO.popen(cmd) do |f|
    while ! f.eof
      puts f.gets
    end
  end
end

option_parser = InitOptions.new
options = option_parser.parse(ARGV)

setup_json_filename = ARGV[0]

# Load the AWS access keys
properties = {}
File.open(AWS_KEYS, 'r') do |file|
  file.read.each_line do |line|
    line.strip!
    if (line[0] != ?# and line[0] != ?=)
      i = line.index('=')
      if (i)
        properties[line[0..i - 1].strip] = line[i + 1..-1].strip
      else
        properties[line] = ''
      end
    end
  end
end
AWS_ACCESS_KEY = properties["AWS_ACCESS_KEY"].gsub('"', '')
AWS_SECRET_ACCESS_KEY = properties["AWS_SECRET_ACCESS_KEY"].gsub('"', '')

##############################
# Find current instance data
EC2_INSTANCE_TYPE = `wget -T 5 -q -O - http://169.254.169.254/latest/meta-data/instance-type`

# Read the setup JSON file
instance_data = JSON.parse(File.read(setup_json_filename))

##############################
# Block devices
##############################

# Creates filesystem on a device
# XFS on 64-bit
# ext4 on 32-bit
def format_filesystem(system_arch, device)
	fs_type = system_arch == "x86_64" ? "XFS" : "ext4"
	puts "Formatting #{fs_type} filesystem on #{device} ..."

	command = case system_arch
		when "x86_64" then "/sbin/mkfs.xfs -f #{device}"
		else "/sbin/mkfs.ext4 -F #{device}"
	end
	IO.popen(command) do |f|
		while ! f.eof
			puts f.gets
		end
	end
end

# Creates and formats a RAID array, given a
# list of partitioned devices
def initialize_raid_array(system_arch, device_list, raid_device = '/dev/md0', raid_type = 0)
	partitions = device_list.collect {|device| "#{device}1" }

	puts "Creating RAID-#{raid_type.to_s} array #{raid_device} ..."
	command = "/sbin/mdadm --create #{raid_device} --level #{raid_type.to_s} --raid-devices #{partitions.length} #{partitions.join(' ')}"
	puts command
	puts `#{command}`

	format_filesystem(system_arch, raid_device)
end

# Creates a mount point, mounts the device and adds it to fstab
def mount_device(device, mount_point, owner, group, fs_type)
	puts `echo #{device} #{mount_point} #{fs_type} noatime 0 0|tee -a /etc/fstab`
	puts `mkdir -p #{mount_point}`
	puts `mount #{mount_point}`
	puts `chown #{owner}:#{owner} #{mount_point}`
end

# Partitions a list of mounted EBS volumes
def partition_devices(device_list)
	puts "Partioning devices ..."
	device_list.each do |device|
		puts "  * #{device}"
		`echo 0|sfdisk #{device}`
	end

	puts "Sleeping 10 seconds to reload partition tables ..."
	sleep 10
end

##############################
# Assembles a set of existing partitions into a RAID array.
def assemble_raid_array(partition_list, raid_device = '/dev/md0', raid_type = 0)
  puts "Assembling cloned RAID-#{raid_type.to_s} array #{raid_device} ..."
  command = "/sbin/mdadm --assemble #{raid_device} #{partition_list.join(' ')}"
  puts command
  puts `#{command}`
end

# Initializes a raid array with existing EBS volumes that are already attached to the instace.
# Partitions & formats new volumes.
# Returns the RAID device name.
def setup_attached_raid_array(system_arch, devices, raid_device = '/dev/md0', raid_type = 0, clone = false)
	partitions = devices.collect {|device| "#{device}1" }

	unless clone
		partition_devices(devices)
		initialize_raid_array(system_arch, devices, raid_device, raid_type)
	else
		assemble_raid_array(partitions, raid_device, raid_type)
	end
	`echo DEVICE #{partitions.join(' ')} |tee -a /etc/mdadm.conf`

  # RAID device name can be a symlink on occasion, so we
  # want to de-reference the symlink to keep everything clear.
  raid_info = "/dev/md0"
  raid_scan_info = `/sbin/mdadm --detail --scan 2>&1`
  puts "RAID Scan Info: #{raid_scan_info}"
  if raid_scan_info =~ /cannot open/
    # This happens occasionally on CentOS 6:
    #   $ /sbin/mdadm --detail --scan
    #   mdadm: cannot open /dev/md/0_0: No such file or directory
    #   mdadm: cannot open /dev/md/1_0: No such file or directory
    #
    # This is tied to how the raid array was created named. See https://bugzilla.redhat.com/show_bug.cgi?id=606481
    # for a lengthy discussion. We should really be naming RAID arrays correctly and using the HOMEHOST setting
    # to re-assemble it.
    #
    # As a stop-gap, try to use the specified raid_device name passed into this method.
    raid_info = raid_device
  else
    raid_info = raid_scan_info.split("\n")[-1].split()[1]
  end
	Pathname.new(raid_info).realpath.to_s
end

def build_block_devices(count, device = "xvdj", &block)
  device_name = device
  0.upto(count - 1).each do |index|
    yield device_name, index
    device_name.next!
  end
end

system_arch = `uname -p`.strip
default_fs_type = system_arch == "x86_64" ? "xfs" : "ext4"

#  Process ephemeral devices first
ephemeral_drive_count = case EC2_INSTANCE_TYPE
	when "m1.small" then 1
	when "m1.medium" then 1
	when "m2.xlarge" then 1
	when "m2.2xlarge" then 1
	when "c1.medium" then 1
	when "m1.large" then 2
	when "m2.4xlarge" then 2
	when "cc1.4xlarge" then 2
	when "cg1.4xlarge" then 2
	when "m1.xlarge" then 4
	when "c1.xlarge" then 4
	when "cc2.8xlarge" then 4
	else 0
end

# Partition the ephemeral drives
partition_list = []
build_block_devices(ephemeral_drive_count, "xvdf") do |device_name, index|
	partition_list << "/dev/#{device_name}"
end
partition_devices(partition_list)

# Format and mount the ephemeral drives
build_block_devices(ephemeral_drive_count, "xvdf") do |device_name, index|
	format_filesystem(system_arch, "/dev/#{device_name}1")

	mount_point = case index
		when 1 then "/mnt"
		else "/mnt/extra#{index - 1}"
	end
	mount_device("/dev/#{device_name}1", mount_point, "root", "root", default_fs_type)
end

# Process EBS volumes
unless instance_data["block_devices"].nil?
  # Install mdadm if we have any RAID devices
  raid_required = false
  instance_data["block_devices"].each do |block_device_json|
    unless block_device_json["raid_level"].nil?
      raid_required = true
      break
    end
  end
  puts `yum install mdadm -y` if raid_required

  raid_array_count = 0
	next_device_name = "xvdj"
	instance_data["block_devices"].each do |block_device_json|
		if block_device_json["raid_level"].nil?
			# If we're not cloning an existing snapshot, then we need to partition and format the drive.
			if options.clone_host.nil?
				partition_devices([ "/dev/#{next_device_name}" ])
				format_filesystem(system_arch, "/dev/#{next_device_name}1")
			end
			mount_device("#{next_device_name}1", block_device_json["mount_point"], block_device_json["owner"], block_device_json["group"], default_fs_type)
			next_device_name.next!
		else
			raid_devices = []
			build_block_devices(block_device_json["count"], next_device_name) do |device_name, index|
				raid_devices << "/dev/#{device_name}"
				next_device_name = device_name
			end
			raid_device_name = setup_attached_raid_array(system_arch, raid_devices, "/dev/md#{(127 - raid_array_count).to_s}", block_device_json["raid_level"].to_i, ! options.clone_host.nil?)
			mount_device(raid_device_name, block_device_json["mount_point"], block_device_json["owner"], block_device_json["group"], default_fs_type)
      raid_array_count += 1
		end
	end
end

##############################
# CHEF SETUP
##############################

# Path to executables
chef_path = instance_data["chef_path"]
knife_path = instance_data["knife_path"]

##############################
# Create knife configuration
knife_config = <<EOF
log_level                :info
log_location             STDOUT
node_name                '#{options.hostname}'
client_key               '/etc/chef/client.pem'
validation_client_name   'chef-validator'
validation_key           '/etc/chef/validation.pem'
chef_server_url          '#{instance_data["chef_server_url"]}'
cache_type               'BasicFile'
cache_options( :path => '/etc/chef/checksums' )
EOF
home_folder = `echo $HOME`.strip
`mkdir -p #{home_folder}/.chef && chown 700 #{home_folder}/.chef`
File.open("#{home_folder}/.chef/knife.rb", "w") do |f|
  f.puts knife_config
end
`chmod 600 #{home_folder}/.chef/knife.rb`

##############################
# Add roles
instance_data["roles"].each do |role|
  cmd = "#{knife_path} node run_list add #{options.hostname} \"role[#{role}]\""
  puts cmd
  puts `#{cmd}`
end

##############################
# Launch Chef
IO.popen(chef_path) do |f|
  while ! f.eof
    puts f.gets
  end
end

##############################
# EMAIL NOTIFICATION
##############################

unless instance_data["email_notification"].nil?
  # Email notification through SES
  AWS.config({
    :access_key_id => instance_data["email_notification"]["ses_access_key"],
    :secret_access_key => instance_data["email_notification"]["ses_secret_key"]
  })
  ses = AWS::SimpleEmailService.new
  ses.send_email(
    :from => instance_data["email_notification"]["from"],
    :to => instance_data["email_notification"]["to"],
    :subject => "Server setup complete: #{hostname}",
    :body_text => "Server setup is complete for Host: #{hostname}, Environment: #{options.environ}, Application: #{options.application}",
    :body_html => "<div>Server setup is complete for:</div><div><strong>Host:</strong> #{hostname}</div><div><strong>Environment:</strong> #{options.environ}</div><div><strong>Application:</strong> #{options.application}</div>"
  )
end
