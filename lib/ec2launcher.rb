#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'optparse'
require 'ostruct'
require 'aws-sdk'

require "ec2launcher/version"
require "ec2launcher/config"
require "ec2launcher/defaults"

require 'ec2launcher/application'
require 'ec2launcher/environment'
require 'ec2launcher/block_device_builder'

module EC2Launcher
  class AmiDetails
    attr_reader :ami_name, :ami_id

    def initialize(name, id)
      @ami_name = name
      @ami_id = id
    end
  end

  class Launcher
    # Runs an AWS request inside a Ruby block with an exponential backoff in case
    # we exceed the allowed AWS RequestLimit.
    #
    # @param [Integer] max_time maximum amount of time to sleep before giving up.
    # @param [Integer] sleep_time the initial amount of time to sleep before retrying.
    # @param [message] message message to display if we get an exception.
    # @param [Block] block Ruby code block to execute.
    def run_with_backoff(max_time, sleep_time, message, &block)
      if sleep_time > max_time
        puts "AWS::EC2::Errors::RequestLimitExceeded ... failed #{message}"
        return false
      end
      
      begin
        yield
      rescue AWS::EC2::Errors::RequestLimitExceeded
        puts "AWS::EC2::Errors::RequestLimitExceeded ... retrying #{message} in #{sleep_time} seconds"
        sleep sleep_time
        run_with_backoff(max_time, sleep_time * 2, message, &block)
      end  
      true
    end

    def launch(options)
      @options = options
      
      # Load configuration data
      @config = load_config_file

      environments_directories = process_directory_list(@config.environments, "environments", "Environments", false)
      applications_directories = process_directory_list(@config.applications, "applications", "Applications", true)

      # Attempt to load default environment data
      @default_environment = nil
      environments_directories.each do |env_dir|
        filename = File.join(env_dir, "default.rb")
        @default_environment = load_environment_file(filename)
        unless @default_environment.nil?
          validate_environment(filename, @default_environment)
          break
        end
      end
      @default_environment ||= EC2Launcher::Environment.new

      # Load other environments
      @environments = { }
      environments_directories.each do |env_dir|
        Dir.entries(env_dir).each do |env_name|
          filename = File.join(env_dir, env_name)
          next if File.directory?(filename)
          next if filename == "default.rb"

          new_env = load_environment_file(filename, @default_environment)
          validate_environment(filename, new_env)

          @environments[new_env.name] = new_env
          new_env.aliases.each {|env_alias| @environments[env_alias] = new_env }
        end
      end

      # Load applications
      @applications = {}
      applications_directories.each do |app_dir|
        Dir.entries(app_dir).each do |application_name|
          filename = File.join(app_dir, application_name)
          next if File.directory?(filename)

          apps = ApplicationDSL.execute(File.read(filename)).applications
          apps.each do |new_application|
            @applications[new_application.name] = new_application
            validate_application(filename, new_application)
          end
        end
      end

      # Process inheritance rules for environments
      @environments.values.each do |env|
        next if env.inherit.nil?

        new_env = process_environment_inheritance(env)
        @environments[new_env.name] = new_env
      end

      # Process inheritance rules for applications
      @applications.values.each do |app|
        next if app.inherit.nil?

        new_app = process_application_inheritance(app)
        @applications[new_app.name] = new_app
      end
    
      if @options.list
        puts ""
        env_names = @environments.keys.sort.join(", ")
        puts "Environments: #{env_names}"

        app_names = @applications.keys.sort.join(", ")
        puts "Applications: #{app_names}"
        exit 0
      end

      ##############################
      # ENVIRONMENT
      ##############################
      unless @environments.has_key? options.environ
        puts "Environment not found: #{options.environ}"
        exit 2
      end
      @environment = @environments[options.environ]

      ##############################
      # APPLICATION
      ##############################
      unless @applications.has_key? options.application
        puts "Application not found: #{options.application}"
        exit 3
      end
      @application = @applications[options.application]

      # Initialize AWS and create EC2 connection
      initialize_aws()
      @ec2 = AWS::EC2.new

      ##############################
      # SUBNET
      ##############################
      subnet = nil
      subnet = @application.subnet unless @application.subnet.nil?
      subnet ||= @environment.subnet unless @environment.subnet.nil?

      ec2_subnet = nil
      unless subnet.nil?
        # Find the matching EC2 subnet
        ec2_subnet = @ec2.subnets[subnet]
      end

      ##############################
      # AVAILABILITY ZONES
      ##############################
      availability_zone = options.zone
      if availability_zone.nil?
        availability_zone = @application.availability_zone
        availability_zone ||= @environment.availability_zone
        availability_zone ||= @default_environment.availability_zone
        availability_zone ||= "us-east-1a"
      end

      ##############################
      # SSH KEY
      ##############################
      key_name = @environment.key_name
      key_name ||= @default_environment.key_name
      if key_name.nil?
        puts "Unable to determine SSH key name."
        exit 4
      end

      ##############################
      # SECURITY GROUPS
      ##############################
      security_groups = []
      security_groups += @environment.security_groups unless @environment.security_groups.nil?
      security_groups += @application.security_groups_for_environment(@environment.name)

      # Build mapping of existing security group names to security group objects
      sg_map = { }
      AWS.start_memoizing
      @ec2.security_groups.each do |sg|
        unless ec2_subnet.nil?
          next unless ec2_subnet.vpc_id == sg.vpc_id
        end
        sg_map[sg.name] = sg
      end
      AWS.stop_memoizing

      # Convert security group names to security group ids
      security_group_ids = []
      security_groups.each do |sg_name|
        security_group_ids << sg_map[sg_name].security_group_id
      end

      ##############################
      # INSTANCE TYPE
      ##############################
      instance_type = options.instance_type
      instance_type ||= @application.instance_type
      instance_type ||= "m1.small"

      ##############################
      # ARCHITECTURE
      ##############################
      instance_architecture = "x86_64"

      instance_virtualization = case instance_type
        when "cc1.4xlarge" then "hvm"
        when "cc2.8xlarge" then "hvm"
        when "cg1.4xlarge" then "hvm"
        else "paravirtual"
      end

      ##############################
      # AMI
      ##############################
      ami_name_match = @application.ami_name
      ami_name_match ||= @environment.ami_name
      ami = find_ami(instance_architecture, instance_virtualization, ami_name_match, @options.ami_id)

      ##############################
      # HOSTNAME
      ##############################
      hostname = @options.hostname
      if hostname.nil?
        short_hostname = generate_hostname()
        hostname = short_hostname

        unless @environment.domain_name.nil?
          hostname += ".#{@environment.domain_name}"
        end
      else
        short_hostname = hostname
        unless @environment.domain_name.nil?
          short_hostname = hostname.gsub(/.#{@environment.domain_name}/, '')
        end
      end

      ##############################
      # Block devices
      ##############################
      builder = EC2Launcher::BlockDeviceBuilder.new(@ec2, @options.volume_size)
      builder.generate_block_devices(hostname, short_hostname, instance_type, @environment, @application, @options.clone_host)
      block_device_mappings = builder.block_device_mappings
      block_device_tags = builder.block_device_tags

      ##############################
      # ELB
      ##############################
      elb_name = nil
      elb_name = @application.elb_for_environment(@environment.name) unless @application.elb.nil?

      ##############################
      # Roles
      ##############################
      roles = []
      roles += @environment.roles unless @environment.roles.nil?
      roles += @application.roles_for_environment(@environment.name)

      ##############################
      # Gems - preinstall
      ##############################
      gems = []
      gems += @environment.gems unless @environment.gems.nil?
      gems += @application.gems unless @application.gems.nil?

      ##############################
      # Packages - preinstall
      ##############################
      packages = []
      packages += @environment.packages unless @environment.packages.nil?
      packages += @application.packages unless @application.packages.nil?

      ##############################
      # Email Notification
      ##############################
      email_notifications = nil
      email_notifications = @application.email_notifications
      email_notifications ||= @environment.email_notifications

      ##############################
      # Chef Validation PEM
      ##############################
      chef_validation_pem_url = nil
      chef_validation_pem_url = @options.chef_validation_url
      chef_validation_pem_url ||= @environment.chef_validation_pem_url

      ##############################
      # File on new instance containing AWS keys
      ##############################
      aws_keyfile = @environment.aws_keyfile

      ##############################
      # Build JSON for setup scripts
      ##############################
      setup_json = {
        'hostname' => hostname,
        'short_hostname' => short_hostname,
        'roles' => roles,
        'chef_server_url' => @environment.chef_server_url,
        'chef_validation_pem_url' => chef_validation_pem_url,
        'aws_keyfile' => aws_keyfile,
        'gems' => gems,
        'packages' => packages
      }
      unless @application.block_devices.nil? || @application.block_devices.empty?
        setup_json['block_devices'] = @application.block_devices
      end
      unless email_notifications.nil?
        setup_json['email_notifications'] = email_notifications
      end

      ##############################
      # Build launch command
      user_data = "#!/bin/sh
export HOME=/root
echo '#{setup_json.to_json}' > /tmp/setup.json"

      # pre-commands, if necessary
      unless @environment.precommands.nil? || @environment.precommands.empty?
        precommands = @environment.precommands.join("\n")
        user_data += "\n" + precommands
      end

      # Primary setup script
      user_data += "\ncurl http://bazaar.launchpad.net/~alestic/runurl/trunk/download/head:/runurl-20090817053347-o2e56z7xwq8m9tt6-1/runurl -o /tmp/runurl
chmod +x /tmp/runurl
/tmp/runurl https://raw.github.com/StudyBlue/ec2launcher/master/startup-scripts/setup.rb -e #{@environment.name} -a #{@application.name} -h #{hostname} /tmp/setup.json > /var/log/cloud-startup.log
rm -f /tmp/runurl"
      user_data += " -c #{options.clone_host}" unless options.clone_host.nil?

      # Add extra requested commands to the launch sequence
      options.commands.each {|extra_cmd| user_data += "\n#{extra_cmd}" }

      # Post commands
      unless @environment.postcommands.nil? || @environment.postcommands.empty?
        postcommands = @environment.postcommands.join("\n")
        user_data += "\n" + postcommands
      end

      ##############################
      puts
      puts "Availability zone: #{availability_zone}"
      puts "Key name            : #{key_name}"
      puts "Security groups     : #{security_groups.join(", ")}"
      puts "Security groups ids : #{security_group_ids.join(", ")}"
      puts "Instance type       : #{instance_type}"
      puts "Architecture        : #{instance_architecture}"
      puts "AMI name            : #{ami.ami_name}"
      puts "AMI id              : #{ami.ami_id}"
      puts "Name                : #{hostname}"
      puts "ELB                 : #{elb_name}" if elb_name
      puts "Chef PEM            : #{chef_validation_pem_url}"
      puts "AWS key file        : #{aws_keyfile}"
      puts "Roles               : #{roles.join(', ')}"
      puts "Gems                : #{gems.join(', ')}"
      puts "Packages            : #{packages.join(', ')}"
      puts "VPC Subnet          : #{subnet}" if subnet

      unless block_device_mappings.empty?
        block_device_mappings.keys.sort.each do |key|
          if block_device_mappings[key] =~ /^ephemeral/
              puts "  Block device   : #{key}, #{block_device_mappings[key]}"
          else
              puts "  Block device   : #{key}, #{block_device_mappings[key][:volume_size]}GB, " +
                 "#{block_device_mappings[key][:snapshot_id]}, " +
                 "(#{block_device_mappings[key][:delete_on_termination] ? 'auto-delete' : 'no delete'})"
          end
        end
      end

      puts "User data:"
      puts user_data
      puts

      if chef_validation_pem_url.nil?
        puts "***ERROR*** Missing the URL For the Chef Validation PEM file."
        exit 3
      end

      # Quit if we're only displaying the defaults
      exit 0 if @options.show_defaults

      ##############################
      # Launch the new intance
      ##############################
      instance = launch_instance(hostname, ami.ami_id, availability_zone, key_name, security_group_ids, instance_type, user_data, block_device_mappings, block_device_tags, subnet)

      ##############################
      # ELB
      ##############################
      attach_to_elb(instance, elb_name) unless elb_name.nil?

      ##############################
      # COMPLETED
      ##############################
      puts ""
      puts "Hostname   : #{hostname}"
      puts "Instance id: #{instance.id}"
      puts "Public dns : #{instance.public_dns_name}"
      puts "Private dns: #{instance.private_dns_name}"
      puts "********************"    
    end

    # Attaches an instance to the specified ELB.
    #
    # @param [AWS::EC2::Instance] instance newly created EC2 instance.
    # @param [String] elb_name name of ELB.
    #
    def attach_to_elb(instance, elb_name)
      begin
        puts ""
        puts "Adding to ELB: #{elb_name}"
        elb = AWS::ELB.new
        AWS.memoize do
          # Build list of availability zones for any existing instances
          zones = { }
          zones[instance.availability_zone] = instance.availability_zone
          elb.load_balancers[elb_name].instances.each do |elb_instance|
            zones[elb_instance.availability_zone] = elb_instance.availability_zone
          end
      
          # Build list of existing zones
          existing_zones = { }
          elb.load_balancers[elb_name].availability_zones.each do |zone|
            existing_zones[zone.name] = zone
          end
      
          # Enable zones
          zones.keys.each do |zone_name|
            elb.load_balancers[elb_name].availability_zones.enable(zones[zone_name])
          end
      
          # Disable zones
          existing_zones.keys.each do |zone_name|
            elb.load_balancers[elb_name].availability_zones.disable(existing_zones[zone_name]) unless zones.has_key?(zone_name)
          end
      
          elb.load_balancers[elb_name].instances.register(instance)
        end
      rescue StandardError => bang
        puts "Error adding to load balancers: " + bang.to_s
      end
    end

    # Given a list of possible directories, build a list of directories that actually exist.
    #
    # @param [Array<String>] directories list of possible directories
    # @return [Array<String>] directories that exist or an empty array if none of the directories exist.
    #
    def build_list_of_valid_directories(directories)
      dirs = []
      unless directories.nil?
        if directories.kind_of? Array
          directories.each {|d| dirs << d if File.directory?(d) }
        else
          dirs << directories if File.directory?(directories)
        end
      end
      dirs
    end

    # Searches for the most recent AMI matching the criteria.
    #
    # @param [String] arch system archicture, `i386` or `x86_64`
    # @param [String] virtualization virtualization type, `paravirtual` or `hvm`
    # @param [Regex] ami_name_match regular expression that describes the AMI.
    # @param [String, nil] id id of an AMI. If not nil, ami_name_match is ignored.
    #
    # @return [AmiDetails]  AMI name and id.
    def find_ami(arch, virtualization, ami_name_match, id = nil)
      puts "Searching for AMI..."
      ami_name = ""
      ami_id = ""

      # Retrieve list of AMIs
      my_images = @ec2.images.with_owner('self')

      if id.nil?
        # Search for latest AMI with the right architecture and virtualization
        my_images.each do |ami|
          next if arch != ami.architecture.to_s
          next if virtualization != ami.virtualization_type.to_s
          next unless ami.state == :available

          next if ! ami.name.match(ami_name_match)

          if ami.name > ami_name
              ami_name = ami.name
              ami_id = ami.id
          end
        end
      else
        # Look for specified AMI
        ami_arch = nil
        my_images.each do |ami|
          next if ami.id != id
          ami_id = id
          ami_name = ami.name
          ami_arch = ami.architecture
        end

        # Check that AMI exists
        if ami_id.nil?
          abort("AMI id not found: #{ami_id}")
        end

        if arch != ami_arch.to_s
          abort("Invalid AMI selection. Architecture for instance type (#{instance_type} - #{instance_architecture} - #{instance_virtualization}) does not match AMI arch (#{ami_arch.to_s}).")
        end
      end

      AmiDetails.new(ami_name, ami_id)
    end

    # Initializes connections to the AWS SDK
    #
    def initialize_aws()
      aws_access_key = @options.access_key
      aws_access_key ||= ENV['AWS_ACCESS_KEY']

      aws_secret_access_key = @options.secret
      aws_secret_access_key ||= ENV['AWS_SECRET_ACCESS_KEY']

      if aws_access_key.nil? || aws_secret_access_key.nil?
        abort("You MUST either set the AWS_ACCESS_KEY and AWS_SECRET_ACCESS_KEY environment variables or use the command line options.")
      end

      puts "Initializing AWS connection..."
      AWS.config({
        :access_key_id => aws_access_key,
        :secret_access_key => aws_secret_access_key
      })
    end

    # Generates a new hostname based on:
    #   * application base name
    #   * application name
    #   * application suffix
    #   * environment short name
    #   * environment name
    #
    def generate_hostname()
      puts "Calculating host name..."

      prefix = @application.basename
      prefix ||= @application.name

      env_suffix = @environment.short_name
      env_suffix ||= @environment.name
      
      suffix = env_suffix
      unless @application.name_suffix.nil?
        suffix = "#{@application.name_suffix}.#{env_suffix}"
      end

      regex = Regexp.new("#{prefix}(\\d+)[.]#{suffix.gsub(/[.]/, "[.]")}.*")

      server_numbers = []

      highest_server_number = 0
      lowest_server_number = 32768
      AWS.memoize do
        server_instances = @ec2.instances.filter("tag:Name", "#{prefix}*#{suffix}*")
        server_instances.each do |i|
          next if i.status == :terminated
          server_name = i.tags[:Name]
          unless regex.match(server_name).nil?
            server_num = $1.to_i
            server_numbers << server_num
          end
        end
        highest_server_number = server_numbers.max
      end

      # If the highest number server is less than 10, just add
      # 1 to it. Otherwise, find the first available
      # server number starting at 1.
      host_number = 0
      if highest_server_number.nil?
        host_number = 1
      elsif highest_server_number < 10
        host_number = highest_server_number + 1
      else
        # Try to start over with 1 and find the
        # first available host number
        server_number_set = Set.new(server_numbers)
        host_number = 1
        while server_number_set.include?(host_number) do
            host_number += 1
        end
      end

      short_hostname = "#{prefix}#{host_number}.#{suffix}"
      short_hostname
    end

    # Launches an EC2 instance.
    #
    # @param [String] FQDN for the new host.
    # @param [String] ami_id id for the AMI to use.
    # @param [String] availability_zone EC2 availability zone to use
    # @param [String] key_name EC2 SSH key to use.
    # @param [Array<String>] security_group_ids list of security groups ids
    # @param [String] instance_type EC2 instance type.
    # @param [String] user_data command data to store pass to the instance in the EC2 user-data field.
    # @param [Hash<String,Hash<String, String>, nil] block_device_mappings mapping of device names to block device details. 
    #        See http://docs.amazonwebservices.com/AWSRubySDK/latest/AWS/EC2/InstanceCollection.html#create-instance_method.
    # @param [Hash<String,Hash<String, String>>, nil] block_device_tags mapping of device names to hash objects with tags for the new EBS block devices.
    #
    # @return [AWS::EC2::Instance] newly created EC2 instance or nil if the launch failed.
    def launch_instance(hostname, ami_id, availability_zone, key_name, security_group_ids, instance_type, user_data, block_device_mappings = nil, block_device_tags = nil, vpc_subnet = nil)
      puts "Launching instance..."
      new_instance = nil
      run_with_backoff(30, 1, "launching instance") do
        new_instance = @ec2.instances.create(
          :image_id => ami_id,
          :availability_zone => availability_zone,
          :key_name => key_name,
          :security_group_ids => security_group_id,
          :user_data => user_data,
          :instance_type => instance_type,
          :block_device_mappings => block_device_mappings,
          :subnet => vpc_subnet
        )
      end
      sleep 5

      puts "  Waiting for instance to start up..."
      sleep 2
      instance_ready = false
      until instance_ready
        sleep 1
        begin
          instance_ready = new_instance.status != :pending
        rescue
        end
      end

      unless new_instance.status == :running
        puts "Instance launch failed. Aborting."
        exit 5
      end

      ##############################
      # Tag instance
      puts "Tagging instance..."
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: name, value: #{hostname}") { new_instance.add_tag("Name", :value => hostname) }
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: environment, value: #{@environment.name}") { new_instance.add_tag("environment", :value => @environment.name) }
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: application, value: #{@application.name}") { new_instance.add_tag("application", :value => @application.name) }

      ##############################
      # Tag volumes
      unless block_device_tags.empty?
        puts "Tagging volumes..."
        AWS.start_memoizing
        block_device_tags.keys.each do |device|
          v = new_instance.block_device_mappings[device].volume
          block_device_tags[device].keys.each do |tag_name|
            run_with_backoff(30, 1, "tag #{v.id}, tag: #{tag_name}, value: #{block_device_tags[device][tag_name]}") do
              v.add_tag(tag_name, :value => block_device_tags[device][tag_name])
            end
          end
        end
        AWS.stop_memoizing
      end

      new_instance
    end

    # Read in the configuration file stored in the workspace directory.
    # By default this will be './config.rb'.
    #
    # @return [EC2Launcher::Config] the parsed configuration object
    def load_config_file()
      # Load configuration file
      config_filename = File.join(@options.directory, "config.rb")
      abort("Unable to find 'config.rb' in '#{@options.directory}'") unless File.exists?(config_filename)
      ConfigDSL.execute(File.read(config_filename)).config
    end

    # Load and parse an environment file
    #
    # @param [String] name full pathname of the environment file to load
    # @param [EC2Launcher::Environment, nil] default_environment the default environment, 
    #        which will be used as the base for the new environment. Optional.
    # @param [Boolean] fail_on_missing print an error and exit if the file does not exist.
    #
    # @return [EC2Launcher::Environment] the new environment loaded from the specified file.
    #
    def load_environment_file(name, default_environment = nil, fail_on_missing = false)
      unless File.exists?(name)
        abort("Unable to read environment: #{name}") if fail_on_missing
        return nil
      end

      new_env = Marshal::load(Marshal.dump(default_environment)) unless default_environment.nil?
      new_env ||= EC2Launcher::Environment.new

      load_env = EC2Launcher::Environment.new
      load_env.load(File.read(name))

      new_env.merge(load_env)

      new_env
    end

    # Attempts to build a list of valid directories.
    #
    # @param [Array<String>, nil] target_directories list of possible directories
    # @param [String] default_directory directory to use if the target_directories list is empty or nil
    # @param [String] name name of the type of directory. Used only for error messages.
    # @param [Boolean] fail_on_error exit with an error if the list of valid directories is empty
    #
    # @return [Array<String] list of directories that exist
    #
    def process_directory_list(target_directories, default_directory, name, fail_on_error = false)
      dirs = []
      if target_directories.nil?
        dirs << File.join(@options.directory, default_directory)
      else
        target_directories.each {|d| dirs << File.join(@options.directory, d) }
      end
      valid_directories = build_list_of_valid_directories(dirs)

      if valid_directories.empty?
        temp_dirs = dirs.each {|d| "'#{d}'"}.join(", ")
        if fail_on_error
          abort("ERROR - #{name} directories not found: #{temp_dirs}")
        else
          puts "WARNING - #{name} directories not found: #{temp_dirs}"
        end
      end

      valid_directories
    end

    def process_application_inheritance(app)
        return app if app.inherit.nil?

        # Find base application
        base_app = @applications[app.inherit]
        abort("Invalid inheritance '#{app.inherit}' in #{app.name}") if base_app.nil?

        new_app = nil
        if base_app.inherit.nil?
          # Clone base application
          new_app = Marshal::load(Marshal.dump(base_app))
        else
          new_app = process_application_inheritance(base_app)
        end
        new_app.merge(app)
        new_app
    end

    def process_environment_inheritance(env)
        return env if env.inherit.nil?

        # Find base environment
        base_env = @environments[env.inherit]
        abort("Invalid inheritance '#{env.inherit}' in #{env.name}") if base_env.nil?

        new_env = nil
        if base_env.inherit.nil?
          # Clone base environment
          new_env = Marshal::load(Marshal.dump(base_env))
        else
          new_env = process_environment_inheritance(base_env)
        end
        new_env.merge(env)
        new_env
    end

    # Validates all settings in an application file
    #
    # @param [String] filename name of the application file
    # @param [EC2Launcher::Application] application application object to validate
    #
    def validate_application(filename, application)
      unless application.availability_zone.nil? || AVAILABILITY_ZONES.include?(application.availability_zone)
        abort("Invalid availability zone '#{application.availability_zone}' in application '#{application.name}' (#{filename})")
      end

      unless application.instance_type.nil? || INSTANCE_TYPES.include?(application.instance_type)
        abort("Invalid instance type '#{application.instance_type}' in application '#{application.name}' (#{filename})")
      end
    end

    # Validates all settings in an environment file
    #
    # @param [String] filename name of the environment file
    # @param [EC2Launcher::Environment] environment environment object to validate
    #
    def validate_environment(filename, environment)
      unless environment.availability_zone.nil? || AVAILABILITY_ZONES.include?(environment.availability_zone)
        abort("Invalid availability zone '#{environment.availability_zone}' in environment '#{environment.name}' (#{filename})")
      end
    end
  end
end