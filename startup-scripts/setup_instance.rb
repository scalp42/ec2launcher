#!/usr/bin/ruby

require 'rubygems'

require 'open3'
require 'optparse'
require 'ostruct'

require 'json'

require 'aws-sdk'

require 'ec2launcher'
require 'ec2launcher/dynamic_hostname_generator'

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

class InstanceSetup
  include EC2Launcher::AWSInitializer
  include EC2Launcher::BackoffRunner

  def initialize(args)
    option_parser = InitOptions.new
    @options = option_parser.parse(args)

    begin
      @logger = Log4r::Logger['ec2launcher']
      unless @logger
        @logger = Log4r::Logger.new 'ec2launcher'
        log_output = Log4r::Outputter.stdout
        log_output.formatter = PatternFormatter.new :pattern => "%m"
        @logger.outputters = log_output
      end
    rescue
    end

    @setup_json_filename = args[0]
  
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
    @AWS_ACCESS_KEY = properties["AWS_ACCESS_KEY"].gsub('"', '')
    @AWS_SECRET_ACCESS_KEY = properties["AWS_SECRET_ACCESS_KEY"].gsub('"', '')

    ##############################
    # Find current instance data
    @EC2_INSTANCE_TYPE = `wget -T 5 -q -O - http://169.254.169.254/latest/meta-data/instance-type`
    @AZ = `wget -T 5 -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone`
    @INSTANCE_ID = `wget -T 5 -q -O - http://169.254.169.254/latest/meta-data/instance-id`
  end

  def setup()
    initialize_aws(@AWS_ACCESS_KEY, @AWS_SECRET_ACCESS_KEY)

    # Read the setup JSON file
    parser = JSON::Parser.new(File.read(@setup_json_filename), { :create_additions => true })
    instance_data = parser.parse()

    ##############################
    # EXECUTABLES
    ##############################
    chef_path = instance_data["chef_path"]

    ##############################
    # HOST NAME
    ##############################
    @hostname = @options.hostname
    if instance_data["dynamic_name"]
      puts "Calculating dynamic host name..."
      hostname_generator = EC2Launcher::DynamicHostnameGenerator.new(instance_data["dynamic_name_prefix"], instance_data["dynamic_name_suffix"])
      short_hostname = hostname_generator.generate_dynamic_hostname(@INSTANCE_ID)
      @hostname = hostname_generator.generate_fqdn(short_hostname, instance_data["domain_name"])

      instance_data["short_hostname"] = short_hostname
      instance_data["hostname"] = @hostname

      # Route53
      if instance_data["route53_zone_id"]
        puts "Adding host to Route53..."

        # Find the local ip address
        local_mac_address = `curl http://169.254.169.254/latest/meta-data/mac`.strip
        local_ip_addresses = `curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/#{local_mac_address}/local-ipv4s`.strip
        local_ip_address = local_ip_addresses.split[0]

        # Add record to Route53. 
        # Note that we use the FQDN because that is what the AWS SDK requires, even though the Web Console only
        # uses the short name.
        aws_route53 = AWS::Route53.new 
        route53 = EC2Launcher::Route53.new(aws_route53, instance_data["route53_zone_id"], @logger)
        route53_zone = aws_route53.client.get_hosted_zone({:id => instance_data["route53_zone_id"]})
        route53.create_record(@hostname, local_ip_address)
      end
    end

    puts "Setting hostname ... #{@hostname}"
    `hostname #{@hostname}`
    `sed -i 's/^HOSTNAME=.*$/HOSTNAME=#{@hostname}/' /etc/sysconfig/network`

    # Set Chef node name
    File.open("/etc/chef/client.rb", 'a') { |f| f.write("node_name \"#{@hostname}\"") }

    # Setup Chef client
    puts "Connecting to Chef ..."
    `rm -f /etc/chef/client.pem`
    puts `#{chef_path}`

    ##############################
    # EBS VOLUMES
    ##############################
    @system_arch = `uname -p`.strip
    @default_fs_type = @system_arch == "x86_64" ? "xfs" : "ext4"

    # Create and setup EBS volumes
    setup_ebs_volumes(instance_data) unless instance_data["block_devices"].nil?
  
    ##############################
    # EPHEMERAL VOLUMES
    ##############################

    #  Process ephemeral devices first
    ephemeral_drive_count = case @EC2_INSTANCE_TYPE
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
      format_filesystem(@system_arch, "/dev/#{device_name}1")

      mount_point = case index
        when 0 then "/mnt"
        else "/mnt/extra#{index - 1}"
      end
      mount_device("/dev/#{device_name}1", mount_point, "root", "root", @default_fs_type)
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
node_name                '#{@hostname}'
client_key               '/etc/chef/client.pem'
validation_client_name   'chef-validator'
validation_key           '/etc/chef/validation.pem'
chef_server_url          '#{instance_data["chef_server_url"]}'
cache_type               'BasicFile'
cache_options( :path => '/etc/chef/checksums' )
EOF
    home_folder = `echo $HOME`.strip
    `mkdir -p #{home_folder}/.chef && chown 700 #{home_folder}/.chef`
    File.open("#{home_folder}/.chef/knife.rb", "w") {|f| f.puts knife_config }
    `chmod 600 #{home_folder}/.chef/knife.rb`

    ##############################
    # Add roles
    instance_data["roles"].each do |role|
      cmd = "#{knife_path} node run_list add #{@hostname} \"role[#{role}]\""
      puts cmd
      puts `#{cmd}`
    end

    result = run_chef_client(chef_path)
    unless result == 0
      puts "***** ERROR running chef-client. Relaunching chef-client in 30 seconds."
      sleep(30)
      result = run_chef_client(chef_path)
    end
    unless result == 0
      puts "***** ERROR running chef-client. Relaunching chef-client in 30 seconds."
      sleep(30)
      result = run_chef_client(chef_path)
    end

    ##############################
    # EMAIL NOTIFICATION
    ##############################
    if instance_data["email_notifications"]
      # Email notification through SES
      puts "Email notification through SES..."
      AWS.config({
        :access_key_id => instance_data["email_notifications"]["ses_access_key"],
        :secret_access_key => instance_data["email_notifications"]["ses_secret_key"]
      })
      ses = AWS::SimpleEmailService.new
      ses.send_email(
        :from => instance_data["email_notifications"]["from"],
        :to => instance_data["email_notifications"]["to"],
        :subject => "Server setup complete: #{@hostname}",
        :body_text => "Server setup is complete for Host: #{@hostname}, Environment: #{@options.environ}, Application: #{@options.application}",
        :body_html => "<div>Server setup is complete for:</div><div><strong>Host:</strong> #{@hostname}</div><div><strong>Environment:</strong> #{@options.environ}</div><div><strong>Application:</strong> #{@options.application}</div>"
      )
    else
      puts "Skipping email notification."
    end

  end

  ##############################
  # Launch Chef
  def run_chef_client(chef_path)
    result = 0
    last_line = nil
    Open3.popen3(chef_path) do |stdin, stdout, stderr, wait_thr|
      stdout.each do |line|
        last_line = line
        puts line
      end
      result = wait_thr.value if wait_thr
    end
    if last_line =~ /[ ]ERROR[:][ ]/
      result = -1
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
    $?
  end

  def attach_volume(instance, device_name, volume)
    ec2 = AWS::EC2.new

    volume_available = test_with_backoff(120, 1, "check EBS volume available #{device_name} (#{volume.id})") do
      volume.status == :available
    end

    # TODO: Handle when volume is still not available

    # Attach volume
    attachment = nil
    run_with_backoff(60, 1, "attaching volume #{volume.id} to #{device_name}") do
      attachment = volume.attach_to(instance, device_name)
    end

    volume_attached = test_with_backoff(60, 1, "check EBS volume attached #{device_name} (#{volume.id})") do
      attatched = false
      begin
        attached = attachment.status == :attached
      rescue AWS::Core::Resource::NotFound
        # This can occur when trying to access the attachment. Not sure how or why. Best to retry.
      end
      attached
    end

    # TODO: Handle when volume fails to attach

    attachment
  end

  def setup_ebs_volumes(instance_data)
    puts "Setting up EBS volumes..."

    # Install mdadm if we have any RAID devices
    raid_required = false
    instance_data["block_devices"].each do |block_device|
      unless block_device.raid_level.nil?
        raid_required = true
        break
      end
    end

    puts "RAID required: #{raid_required.to_s}"

    if raid_required
      result = run_command("yum install mdadm -y")
      unless result == 0
        run_command("yum clean all")
        run_command("yum install mdadm -y")
      end
    end

    # Create and attach the EBS volumes, if necessary
    if instance_data["provisioned_iops"]
      puts "Setup requires EBS volumes with provisioned IOPS."
      
      ec2 = AWS::EC2.new
      instance = ec2.instances[@INSTANCE_ID]

      volumes = {}
      block_creation_threads = []
      instance_data["block_device_mappings"].keys.sort.each do |device_name|
        block_data = instance_data["block_device_mappings"][device_name]
        next if block_data =~ /^ephemeral/

        block_info = {}
        block_info[:availability_zone] = @AZ
        block_info[:size] = block_data["volume_size"]
        block_info[:snapshot_id] = block_data["snapshot_id"] if block_data["snapshot_id"]
        if block_data["iops"]
          block_info[:iops] = block_data["iops"]
          block_info[:volume_type] = "io1"
        end

        # Create volume
        block_device_text = "Creating EBS volume: #{device_name}, #{block_info[:volume_size]}GB, "
        block_device_text += "#{block_info[:snapshot_id]}" if block_info[:snapshot_id]
        block_device_text += "#{block_info[:iops].nil? ? 'standard' : block_info[:iops].to_s} IOPS"
        puts block_device_text
        volume = nil
        run_with_backoff(60, 1, "creating ebs volume") do 
          volume = ec2.volumes.create(block_info)
        end

        volumes[device_name] = volume

        block_creation_threads << Thread.new {
          attach_volume(instance, device_name, volume)
        }
      end
      
      block_creation_threads.each do |t|
        t.join
      end

      AWS.memoize do
        block_device_builder = EC2Launcher::BlockDeviceBuilder.new(ec2, 60)
        block_device_tags = block_device_builder.generate_device_tags(instance_data["hostname"], instance_data["short_hostname"], instance_data["environment"], instance_data["block_devices"])
        unless block_device_tags.empty?
          puts "Tagging volumes"
          AWS.memoize do
            block_device_tags.keys.each do |device_name|
              volume = volumes[device_name]
              block_device_tags[device_name].keys.each do |tag_name|
                run_with_backoff(30, 1, "tag #{volume.id}, tag: #{tag_name}, value: #{block_device_tags[device_name][tag_name]}") do
                  volume.add_tag(tag_name, :value => block_device_tags[device_name][tag_name])
                end
              end
            end
          end
        end
      end
    end # provisioned iops

    raid_array_count = 0
    next_device_name = "xvdj"
    instance_data["block_devices"].each do |block_device|
      if block_device.raid_level.nil?
        # If we're not cloning an existing snapshot, then we need to partition and format the drive.
        if @options.clone_host.nil?
          partition_devices([ "/dev/#{next_device_name}" ])
          format_filesystem(@system_arch, "/dev/#{next_device_name}1")
        end
        
        if block_device.block_ra
          set_block_read_ahead("/dev/#{next_device_name}1", block_device.block_ra)
        end

        mount_device("/dev/#{next_device_name}1", block_device.mount, block_device.owner, block_device.group, @default_fs_type)
        next_device_name.next!
      else
        raid_devices = []
        build_block_devices(block_device.count, next_device_name) do |device_name, index|
          raid_devices << "/dev/#{device_name}"
          next_device_name = device_name
        end
        puts "Setting up attached raid array... system_arch = #{@system_arch}, raid_devices = #{raid_devices}, device = /dev/md#{(127 - raid_array_count).to_s}"
        raid_device_name = setup_attached_raid_array(@system_arch, raid_devices, "/dev/md#{(127 - raid_array_count).to_s}", block_device.raid_level.to_i, ! @options.clone_host.nil?)
        
        if block_device.block_ra
          raid_devices.each {|device_name| set_block_read_ahead("#{device_name}1", block_device.block_ra) }
          set_block_read_ahead(raid_device_name, block_device.block_ra)
        end

        mount_device(raid_device_name, block_device.mount, block_device.owner, block_device.group, @default_fs_type)
        raid_array_count += 1
      end
    end
  end

  def set_block_read_ahead(device_name, read_ahead = nil)
    if read_ahead
      puts "Setting block device read ahead to #{read_ahead} for #{device_name}"
      puts `blockdev --setra #{read_ahead} #{device_name}`
    end
  end

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
    puts "Making mount directory #{mount_point} for #{device}"
    puts `mkdir -p #{mount_point}`
    puts "Mounting #{device} at #{mount_point}"
    puts `mount #{mount_point}`
    puts "Setting ownership on #{mount_point} to #{owner}"
    puts `chown #{owner}:#{owner} #{mount_point}`
  end

  # Partitions a list of mounted EBS volumes
  def partition_devices(device_list, attempt = 0, max_attempts = 3)
    return false if attempt >= max_attempts

    puts case attempt
      when 0 then  "Partioning devices ..." 
      else "Retrying device partitioning (attempt #{attempt + 1}) ..." 
    end

    device_list.each do |device|
      puts "  * #{device}"
      `echo 0|sfdisk #{device}`
    end

    puts "Sleeping 10 seconds to reload partition tables ..."
    sleep 10

    # Verify all volumes were properly partitioned
    missing_devices = []
    device_list.each do |device|
      missing_devices << device unless File.exists?("#{device}1")
    end

    # Retry partitioning for failed volumes
    response = true
    if missing_devices.size > 0
      response = partition_devices(missing_devices, attempt + 1, max_attempts)
    end
    response
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
      # This is tied to how the raid array was created, especially if the array was created with an older version of mdadm. 
      # See https://bugzilla.redhat.com/show_bug.cgi?id=606481 for a lengthy discussion. We should really be naming RAID 
      # arrays correctly and using the HOMEHOST setting to re-assemble it.
      #
      # As a stop-gap, try to use the specified raid_device name passed into this method.
      raid_info = raid_device

      # We need to manually retrieve the UUID of the array
      array_uuid = `mdadm --detail #{raid_device}|grep UUID|awk '// { print $3; }'`.strip

      # We have to manually update mdadm.conf as well
      #`echo ARRAY #{raid_device} level=raid#{raid_type.to_s} num-devices=#{devices.count.to_s} meta-data=0.90 UUID=#{array_uuid} |tee -a /etc/mdadm.conf`
      `echo ARRAY #{raid_device} level=raid#{raid_type.to_s} num-devices=#{devices.count.to_s} UUID=#{array_uuid} |tee -a /etc/mdadm.conf`
    else
      raid_info = raid_scan_info.split("\n")[-1].split()[1]
    end
    raid_device_real_path = Pathname.new(raid_info).realpath.to_s
    puts "Using raid device: #{raid_info}. Real path: #{raid_device_real_path}"
    
    raid_device_real_path
  end

  def build_block_devices(count, device = "xvdj", &block)
    device_name = device
    0.upto(count - 1).each do |index|
      yield device_name, index
      device_name.next!
    end
  end
end

instance_setup = InstanceSetup.new(ARGV)
instance_setup.setup()
