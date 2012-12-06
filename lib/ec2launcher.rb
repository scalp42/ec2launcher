#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'optparse'
require 'ostruct'
require 'aws-sdk'
require 'log4r'

require 'ec2launcher/version'
require 'ec2launcher/defaults'

require 'ec2launcher/dsl/config'
require 'ec2launcher/dsl/application'
require 'ec2launcher/dsl/environment'

require 'ec2launcher/aws_initializer'
require 'ec2launcher/backoff_runner'
require 'ec2launcher/instance_paths_config'
require 'ec2launcher/block_device_builder'
require 'ec2launcher/hostname_generator'
require 'ec2launcher/route53'

require 'ec2launcher/config_wrapper'

include Log4r

module EC2Launcher

  class AmiDetails
    attr_reader :ami_name, :ami_id

    def initialize(name, id)
      @ami_name = name
      @ami_id = id
    end
  end

  class Launcher
    include AWSInitializer
    include BackoffRunner

    def initialize()
      @run_url_script_cache = nil
      @setup_script_cache = nil

      @log = Logger.new 'ec2launcher'
      log_output = Outputter.stdout
      log_output.formatter = PatternFormatter.new :pattern => "%m"
      @log.outputters = log_output
    end

    def launch(options)
      @options = options

      @log.info "ec2launcher v#{EC2Launcher::VERSION}"

      @log.level = case @options.verbosity 
        when :quiet then WARN
        when :verbose then DEBUG
        else INFO
      end
      
      # Load configuration data
      config_wrapper = ConfigWrapper.new(@options.directory)

      @config = config_wrapper.config
      @environments = config_wrapper.environments
      @applications = config_wrapper.applications
    
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
        @log.fatal "Environment not found: #{options.environ}"
        exit 2
      end
      @environment = @environments[options.environ]

      ##############################
      # APPLICATION
      ##############################
      unless @applications.has_key? options.application
        @log.fatal "Application not found: #{options.application}"
        exit 3
      end
      @application = @applications[options.application]

      ##############################
      # INSTANCE PATHS
      ##############################
      @instance_paths = EC2Launcher::InstancePathsConfig.new(@environment)

      ##############################
      # Initialize AWS and create EC2 connection
      ##############################
      initialize_aws(@options.access_key, @options.secret)
      @ec2 = AWS::EC2.new

      ##############################
      # Create Route53 connection
      ##############################
      @route53 = nil
      @route53_zone_id = nil
      @route53_domain_name = nil
      if @environment.route53_zone_id
        aws_route53 = AWS::Route53.new 
        @route53 = EC2Launcher::Route53.new(aws_route53, @environment.route53_zone_id, @log)
        @route53_zone_id = @environment.route53_zone_id
        route53_zone = aws_route53.client.get_hosted_zone({:id => @environment.route53_zone_id})
        @route53_domain_name = route53_zone[:hosted_zone][:name].chop
      end

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
        availability_zone ||= "us-east-1a"
      end

      ##############################
      # SSH KEY
      ##############################
      key_name = @environment.key_name
      if key_name.nil?
        @log.fatal "Unable to determine SSH key name."
        exit 4
      end

      ##############################
      # SECURITY GROUPS
      ##############################
      security_groups = []
      security_groups += @environment.security_groups_for_environment(@environment.name) unless @environment.security_groups_for_environment(@environment.name).nil?
      security_groups += @application.security_groups_for_environment(@environment.name)

      # Build mapping of existing security group names to security group objects
      sg_map = { }
      AWS.start_memoizing
      @ec2.security_groups.each do |sg|
        next if ec2_subnet.nil? && sg.vpc_id
        next if ec2_subnet && ec2_subnet.vpc_id != sg.vpc_id
        sg_map[sg.name] = sg
      end
      AWS.stop_memoizing

      # Convert security group names to security group ids
      security_group_ids = []
      missing_security_groups = []
      security_groups.each do |sg_name|
        missing_security_groups << sg_name unless sg_map.has_key?(sg_name)
        security_group_ids << sg_map[sg_name].security_group_id
      end

      if missing_security_groups.length > 0
        @log.fatal "ERROR: Missing security groups: #{missing_security_groups.join(', ')}"
        exit 3
      end

      ##############################
      # IAM PROFILE
      ##############################
      iam_profile = @application.iam_profile_for_environment(@environment.name)
      iam_profile ||= @environment.iam_profile

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
      ami = nil
      run_with_backoff(60, 1, "searching for ami") do
        ami = find_ami(instance_architecture, instance_virtualization, ami_name_match, @options.ami_id)
      end

      ##############################
      # DOMAIN NAME
      ##############################

      # Note: Route53 domain names override domain names specified in the environments
      @domain_name = @route53_domain_name
      @domain_name ||= @environment.domain_name

      ##############################
      # HOSTNAME
      ##############################
      hostname_generator = EC2Launcher::HostnameGenerator.new(@ec2, @environment, @application)
      short_hostnames = []
      fqdn_names = []
      if @options.count > 1
        1.upto(@options.count).each do |i|
          short_hostname = hostname_generator.generate_hostname()
          long_hostname = hostname_generator.generate_long_name(short_hostname, @domain_name)
          short_hostnames << short_hostname
          fqdn_names << long_hostname
        end
      else
        if @options.hostname.nil?
          short_hostname = hostname_generator.generate_hostname()
          long_hostname = hostname_generator.generate_long_name(short_hostname, @domain_name)
        else
          long_hostname = @options.hostname
          short_hostname = hostname_generator.generate_short_name(long_hostname, @environment.domain_name)
          if long_hostname == short_hostname
            long_hostname = hostname_generator.generate_long_name(short_hostname, @environment.domain_name)
          end
        end
        short_hostnames << short_hostname
        fqdn_names << long_hostname
      end

      ##############################
      # Block devices
      ##############################
      block_device_builder = EC2Launcher::BlockDeviceBuilder.new(@ec2, @options.volume_size)
      block_device_mappings = block_device_builder.generate_block_devices(instance_type, @environment, @application, @options.clone_host)

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
      gems << "ec2launcher"

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
      @log.info
      @log.info "Availability zone   : #{availability_zone}"
      @log.info "Key name            : #{key_name}"
      @log.info "Security groups     : " + security_groups.collect {|name| "#{name} (#{sg_map[name].security_group_id})"}.join(", ")
      @log.info "IAM profile         : #{iam_profile}" if iam_profile
      @log.info "Instance type       : #{instance_type}"
      @log.info "Architecture        : #{instance_architecture}"
      @log.info "AMI name            : #{ami.ami_name}"
      @log.info "AMI id              : #{ami.ami_id}"
      @log.info "ELB                 : #{elb_name}" if elb_name
      @log.info "Route53 Zone        : #{@route53_domain_name}" if @route53_domain_name
      @log.info "Chef PEM            : #{chef_validation_pem_url}"
      @log.info "AWS key file        : #{aws_keyfile}"
      @log.info "Roles               : #{roles.join(', ')}"
      @log.info "Gems                : #{gems.join(', ')}"
      @log.info "Packages            : #{packages.join(', ')}"
      if subnet
        cidr_block = @ec2.subnets[subnet].cidr_block
        @log.info "VPC Subnet          : #{subnet} (#{cidr_block})"
      end
      @log.info ""
      fqdn_names.each do |fqdn|
        @log.info "Name                : #{fqdn}"
      end

      unless block_device_mappings.empty?
        @log.info ""
        @log.info "Block devices     :"
        block_device_mappings.keys.sort.each do |key|
          if block_device_mappings[key] =~ /^ephemeral/
              @log.info "  Block device   : #{key}, #{block_device_mappings[key]}"
          else
              block_device_text = "  Block device   : #{key}, #{block_device_mappings[key][:volume_size]}GB, "
              block_device_text += "#{block_device_mappings[key][:snapshot_id]}" if block_device_mappings[key][:snapshot_id]
              block_device_text += ", (#{block_device_mappings[key][:delete_on_termination] ? 'auto-delete' : 'no delete'}), "
              block_device_text += "(#{block_device_mappings[key][:iops].nil? ? 'standard' : block_device_mappings[key][:iops].to_s} IOPS)"
              @log.info block_device_text
          end
        end
      end

      if chef_validation_pem_url.nil?
        @log.fatal "***ERROR*** Missing the URL For the Chef Validation PEM file."
        exit 3
      end

      # Launch options
      launch_options = {
        :ami => ami.ami_id,
        :availability_zone => availability_zone,
        :aws_keyfile => aws_keyfile,
        :block_device_mappings => block_device_mappings,
        :chef_validation_pem_url => chef_validation_pem_url,
        :email_notifications => email_notifications,
        :environment => @environment.name,
        :gems => gems, 
        :iam_profile => iam_profile,
        :instance_type => instance_type,
        :key => key_name,
        :packages => packages,
        :provisioned_iops => @application.has_provisioned_iops?(),
        :roles => roles, 
        :security_group_ids => security_group_ids,
        :subnet => subnet
      }

      # Quit if we're only displaying the defaults
      if @options.show_defaults || @options.show_user_data
        if @options.show_user_data
          user_data = build_launch_command(
            launch_options.merge({
              :fqdn => fqdn_names[0],
              :short_name => short_hostnames[0]
            })
          )
          @log.info ""
          @log.info "---user-data---"
          @log.info user_data
          @log.info "---user-data---"
        end
        exit 0
      end

      ##############################
      # Launch the new intance
      ##############################
      @log.warn ""
      instances = []
      fqdn_names.each_index do |i|
        block_device_tags = block_device_builder.generate_device_tags(fqdn_names[i], short_hostnames[i], @environment.name, @application.block_devices)
        launch_options.merge!({
          :fqdn => fqdn_names[i],
          :short_name => short_hostnames[i],
          :block_device_tags => block_device_tags,
        })
        user_data = build_launch_command(launch_options)

        instance = launch_instance(launch_options, user_data)
        instances << instance

        public_dns_name = get_instance_dns(instance, true)
        private_dns_name = get_instance_dns(instance, false)
        @log.info "Launched #{fqdn_names[i]} (#{instance.id}) [#{public_dns_name} / #{private_dns_name} / #{instance.private_ip_address} ]"
      end

      @log.info "********************"    
      fqdn_names.each_index do |i|
        public_dns_name = get_instance_dns(instances[i], true)
        private_dns_name = get_instance_dns(instances[i], false)
        @log.warn "** New instance: #{fqdn_names[i]} | #{instances[i].id} | #{public_dns_name} | #{private_dns_name} | #{instances[i].private_ip_address}"
      end

      ##############################
      # ELB
      ##############################
      unless elb_name.nil?
        instances.each {|instance| attach_to_elb(instance, elb_name, ec2_subnet) }
      end

      ##############################
      # COMPLETED
      ##############################
      @log.info "********************"    
    end

    # Attaches an instance to the specified ELB.
    #
    # @param [AWS::EC2::Instance] instance newly created EC2 instance.
    # @param [String] elb_name name of ELB.
    # @param [String] subnet subnet name or id. Defaults to nil.
    #
    def attach_to_elb(instance, elb_name, subnet = nil)
      begin
        @log.info ""
        @log.info "Adding to ELB: #{elb_name}"
        elb = AWS::ELB.new
        AWS.memoize do
          unless subnet
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
          end
      
          elb.load_balancers[elb_name].instances.register(instance)
        end
      rescue StandardError => bang
        @log.error "Error adding to load balancers: " + bang.to_s
      end
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
      @log.info "Searching for AMI..."
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

    # Retrieves either the public or private DNS entry for an EC2 Instance. Returns "n/a" if the
    # request DNS entry is undefined.
    #
    # @param [AWS::EC2::Instance] ec2 instance
    # @param [Boolean] True for public DNS or False for private DNS
    #
    # @return [String] DNS for the instance or "n/a" if undefined.
    #
    def get_instance_dns(ec2_instance, public = true)
      dns_name = public ? ec2_instance.public_dns_name : ec2_instance.private_dns_name
      dns_name.nil? ? "n/a" : dns_name
    end

    # Launches an EC2 instance.
    #
    # launch_options = {
    #   :ami
    #   :availability_zone
    #   :aws_keyfile
    #   :block_device_mappings
    #   :block_device_tags
    #   :chef_validation_pem_url
    #   :email_notifications
    #   :fqdn
    #   :gems
    #   :iam_profile
    #   :instance_type
    #   :key
    #   :packages
    #   :roles
    #   :security_group_ids
    #   :short_name
    #   :subnet
    # }
    #
    # @return [AWS::EC2::Instance] newly created EC2 instance or nil if the launch failed.
    def launch_instance(launch_options, user_data)
      @log.warn "Launching instance... #{launch_options[:fqdn]}"
      new_instance = nil
      run_with_backoff(30, 1, "launching instance") do
        launch_mapping = {
            :image_id => launch_options[:ami],
            :availability_zone => launch_options[:availability_zone],
            :key_name => launch_options[:key],
            :security_group_ids => launch_options[:security_group_ids],
            :user_data => user_data,
            :instance_type => launch_options[:instance_type]
        }
        unless launch_options[:block_device_mappings].nil? || launch_options[:block_device_mappings].keys.empty?
          if launch_options[:provisioned_iops]
            # Only include ephemeral devices if we're using provisioned IOPS for the EBS volumes
            launch_mapping[:block_device_mappings] = {}
            launch_options[:block_device_mappings].keys.sort.each do |block_device_name|
              if block_device_name =~ /^ephemeral/
                launch_mapping[:block_device_mappings][block_device_name] = launch_options[:block_device_mappings][block_device_name]
              end
            end
          else
            launch_mapping[:block_device_mappings] = launch_options[:block_device_mappings]
          end

          # Remove the block_device_mappings entry if it's empty. Otherwise the AWS API will throw an error.
          launch_mapping.delete(:block_device_mappings) if launch_mapping[:block_device_mappings].keys.empty?
        end

        launch_mapping[:iam_instance_profile] = launch_options[:iam_profile] if launch_options[:iam_profile]
        launch_mapping[:subnet] = launch_options[:vpc_subnet] if launch_options[:vpc_subnet]

        new_instance = @ec2.instances.create(launch_mapping)
      end
      sleep 5

      @log.info "  Waiting for instance to start up..."
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
        @log.fatal "Instance launch failed. Aborting."
        exit 5
      end

      ##############################
      # Tag instance
      @log.info "Tagging instance..."
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: name, value: #{launch_options[:fqdn]}") { new_instance.add_tag("Name", :value => launch_options[:fqdn]) }
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: short_name, value: #{launch_options[:short_name]}") { new_instance.add_tag("short_name", :value => launch_options[:short_name]) }
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: environment, value: #{@environment.name}") { new_instance.add_tag("environment", :value => @environment.name) }
      run_with_backoff(30, 1, "tag #{new_instance.id}, tag: application, value: #{@application.name}") { new_instance.add_tag("application", :value => @application.name) }
      if @options.clone_host
        run_with_backoff(30, 1, "tag #{new_instance.id}, tag: cloned_from, value: #{@options.clone_host}") { new_instance.add_tag("cloned_from", :value => @options.clone_host) }
      end

      ##############################
      # Tag volumes
      unless launch_options[:provisioned_iops] || launch_options[:block_device_tags].empty?
        @log.info "Tagging volumes..."
        AWS.start_memoizing
        launch_options[:block_device_tags].keys.each do |device|
          v = new_instance.block_device_mappings[device].volume
          launch_options[:block_device_tags][device].keys.each do |tag_name|
            run_with_backoff(30, 1, "tag #{v.id}, tag: #{tag_name}, value: #{launch_options[:block_device_tags][device][tag_name]}") do
              v.add_tag(tag_name, :value => launch_options[:block_device_tags][device][tag_name])
            end
          end
        end
        AWS.stop_memoizing
      end

      ##############################
      # Add to Route53
      if @route53
        @log.info "Adding A record to Route53: #{launch_options[:fqdn]} => #{new_instance.private_ip_address}"
        @route53.create_record(launch_options[:fqdn], new_instance.private_ip_address, 'A')
      end

      new_instance
    end

    # Given a string containing a command to run, replaces any inline variables.
    # Supported variables include:
    #   * @APPLICATION@ - name of the application
    #   * @APP@ - name of the application
    #   * @ENVIRONMENT@ - name of the environment
    #   * @ENV@ - name of the environment
    #   * @RUBY@ - Full pathname to the ruby executable
    #   * @GEM@ - Full pathname to the gem executable
    #   * @CHEF@ - Full pathname to the chef-client executable
    #   * @KNIFE@ - Full pathname to the knife executable
    #
    # @return [String] command with variables replaced
    def substitute_command_variables(cmd)
      substitutions = {
        /@APPLICATION@/ => @application.name,
        /@APP@/ => @application.name,
        /@ENVIRONMENT@/ => @environment.name,
        /@ENV@/ => @environment.name,
        /@RUBY@/ => @instance_paths.ruby_path,
        /@GEM@/ => @instance_paths.gem_path,
        /@CHEF@/ => @instance_paths.chef_path,
        /@KNIFE@/ => @instance_paths.knife_path
      }
      substitutions.keys.each {|key| cmd.gsub!(key, substitutions[key]) }
      cmd
    end

    # Builds the launch scripts that should run on the new instance.
    #
    # launch_options = {
    #   :ami
    #   :availability_zone
    #   :aws_keyfile
    #   :block_device_mappings
    #   :block_device_tags
    #   :chef_validation_pem_url
    #   :email_notifications
    #   :fqdn
    #   :gems
    #   :iam_profile
    #   :instance_type
    #   :key
    #   :packages
    #   :roles
    #   :security_group_ids
    #   :short_name
    #   :subnet
    # }
    #
    # @return [String] Launch commands to pass into new instance as userdata
    def build_launch_command(launch_options)
      # Build JSON for setup scripts

      # Require ec2launcher gem if cloning and using provisioned IOPS
      setup_json = {
        'hostname' => launch_options[:fqdn],
        'short_hostname' => launch_options[:short_name],
        'block_device_mappings' => launch_options[:block_device_mappings],
        'roles' => launch_options[:roles],
        'chef_server_url' => @environment.chef_server_url,
        'chef_validation_pem_url' => launch_options[:chef_validation_pem_url],
        'aws_keyfile' => launch_options[:aws_keyfile],
        'gems' => launch_options[:gems],
        'packages' => launch_options[:packages],
        'provisioned_iops' => false
      }
      setup_json["gem_path"] = @instance_paths.gem_path
      setup_json["ruby_path"] = @instance_paths.ruby_path
      setup_json["chef_path"] = @instance_paths.chef_path
      setup_json["knife_path"] = @instance_paths.knife_path

      unless @application.block_devices.nil? || @application.block_devices.empty?
        setup_json['block_devices'] = @application.block_devices

        @application.block_devices.each do |bd|
          if bd.provisioned_iops?
            setup_json['provisioned_iops'] = true
            break
          end
        end
      end
      unless launch_options[:email_notifications].nil?
        setup_json['email_notifications'] = launch_options[:email_notifications]
      end

      ##############################
      # Build launch command
      user_data = <<EOF
#!/bin/bash
cat > /tmp/setup.json <<End-Of-Message-JSON
#{setup_json.to_json}
End-Of-Message-JSON
EOF
      if @environment.use_rvm or @application.use_rvm
        user_data += <<-EOF
export HOME=/root
if [[ -s "/etc/profile.d/rvm.sh" ]] ; then
  source "/etc/profile.d/rvm.sh"
fi
EOF
      end

      # pre-commands, if necessary
      user_data += build_commands(@environment.precommand)
      user_data += build_commands(@application.precommand)

      unless @options.skip_setup
        if @run_url_script_cache.nil?
          puts "Downloading runurl script from #{RUN_URL_SCRIPT}"
          @run_url_script_cache = `curl -s #{RUN_URL_SCRIPT} |gzip -f |base64`
        end

        if @setup_script_cache.nil?
          puts "Downloading setup script from #{SETUP_SCRIPT}"
          @setup_script_cache = `curl -s #{SETUP_SCRIPT} |gzip -f |base64`
        end

        # runurl script
        user_data += "cat > /tmp/runurl.gz.base64 <<End-Of-Message\n"
        user_data += @run_url_script_cache
        user_data += "End-Of-Message"

        # setup script
        user_data += "\ncat > /tmp/setup.rb.gz.base64 <<End-Of-Message2\n"
        user_data += @setup_script_cache
        user_data += "End-Of-Message2"

        user_data += "\nbase64 -d /tmp/runurl.gz.base64 | gunzip > /tmp/runurl"
        user_data += "\nchmod +x /tmp/runurl"
        # user_data += "\nrm -f /tmp/runurl.gz.base64"

        user_data += "\nbase64 -d /tmp/setup.rb.gz.base64 | gunzip > /tmp/setup.rb"
        user_data += "\nchmod +x /tmp/setup.rb"
        # user_data += "\nrm -f /tmp/setup.rb.gz.base64"

        user_data += "\n#{setup_json['ruby_path']} /tmp/setup.rb -e #{@environment.name} -a #{@application.name} -h #{launch_options[:fqdn]} /tmp/setup.json"
        user_data += " -c #{@options.clone_host}" unless @options.clone_host.nil?
        user_data += " 2>&1 > /var/log/cloud-startup.log"
      end

      # Add extra requested commands to the launch sequence
      user_data += build_commands(@options.commands)

      # Post commands
      user_data += build_commands(@environment.postcommand)
      user_data += build_commands(@application.postcommand)

      user_data
    end

    # Builds a bash script snipp containing a list of commands to execute.
    #
    # @param [Array<String>] commands List of commands to run. Can be nil.
    #
    # @return [String] String containing newline separated bash commands to run or an empty string if no commands.
    def build_commands(commands)
      command_str = ""
      unless commands.nil? || commands.empty?
        processed_commands = commands.collect {|cmd| substitute_command_variables(cmd) }
        command_str = "\n" + processed_commands.join("\n") + "\n"
      end
      command_str
    end
  end
end
