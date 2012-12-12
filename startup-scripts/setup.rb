#!/usr/bin/ruby

require 'rubygems'

require 'optparse'
require 'ostruct'

require 'json'

require 'ec2launcher'

SETUP_SCRIPT = "setup_instance.rb"

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

# Read the setup JSON file
instance_data = JSON.parse(File.read(setup_json_filename))

# Path to executables
gem_path = instance_data["gem_path"]
ruby_path = instance_data["ruby_path"]
chef_path = instance_data["chef_path"]

# Pre-install gems
unless instance_data["gems"].nil?
	instance_data["gems"].each {|gem_name| puts `#{gem_path} install --no-rdoc --no-ri #{gem_name}` }
end

# Pre-install packages
unless instance_data["packages"].nil?
  puts `yum install #{instance_data["packages"].join(" ")} -y`
end


# Load the AWS access keys
properties = {}
File.open(instance_data['aws_keyfile'], 'r') do |file|
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
  
# Create s3curl auth file
s3curl_auth_data = <<EOF
%awsSecretAccessKeys = (
    # personal account
    startup => {
        id => '#{AWS_ACCESS_KEY}',
        key => '#{AWS_SECRET_ACCESS_KEY}'
    }
);
EOF

home_folder = `echo $HOME`.strip
File.open("#{home_folder}/.s3curl", "w") do |f|
  f.puts s3curl_auth_data
end
`chmod 600 #{home_folder}/.s3curl`

# Retrieve validation.pem
puts "Retrieving Chef validation.pem ..."
puts `s3curl.pl --id startup #{instance_data['chef_validation_pem_url']} > /etc/chef/validation.pem`

# Setting hostname
puts "Setting hostname ... #{options.hostname}"
`hostname #{options.hostname}`
`sed -i 's/^HOSTNAME=.*$/HOSTNAME=#{options.hostname}/' /etc/sysconfig/network`

# Set Chef node name
File.open("/etc/chef/client.rb", 'a') { |f| f.write("node_name \"#{options.hostname}\"") }

# Setup Chef client
puts "Connecting to Chef ..."
`rm -f /etc/chef/client.pem`
puts `#{chef_path}`

# Retrieve secondary setup script and run it
puts "Launching role setup script ..."
command = "#{ruby_path} /tmp/#{SETUP_SCRIPT} -a #{options.application} -e #{options.environ} -h #{options.hostname} #{setup_json_filename}"
command += " -c #{options.clone_host}" unless options.clone_host.nil?
command += " 2>&1 > /var/log/cloud-init.log"
run_command(command)