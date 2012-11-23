#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'
require 'log4r'

require 'ec2launcher/aws_initializer'
require 'ec2launcher/backoff_runner'
require 'ec2launcher/route53'

module EC2Launcher
  class Terminator
    include AWSInitializer
    include BackoffRunner

    def initialize(config_directory, environment_name)
      @log = Logger.new 'ec2launcher'
      log_output = Outputter.stdout
      log_output.formatter = PatternFormatter.new :pattern => "%m"
      @log.outputters = log_output

      ##############################
      # Load configuration data
      ##############################
      config_wrapper = ConfigWrapper.new(config_directory)

      @config = config_wrapper.config
      @environments = config_wrapper.environments

      ##############################
      # ENVIRONMENT
      ##############################
      unless @environments.has_key? environment_name
        @log.fatal "Environment not found: #{environment_name}"
        exit 2
      end
      @environment = @environments[environment_name]
    end

    # Terminates a given server instance.
    #
    # @param[String] server_name Name of the server instance
    # @param[String] access_key Amazon IAM access key
    # @param[String] secret Amazon IAM secret key
    # @param[Boolean] snapshot_removal Remove EBS snapshots for EBS volumes attached to the instance.
    def terminate(server_name, access_key, secret, snapshot_removal = true)
      ##############################
      # Initialize AWS and create EC2 connection
      ##############################
      initialize_aws(access_key, secret)
      ec2 = AWS::EC2.new
      
      ##############################
      # Create Route53 connection
      ##############################
      aws_route53 = AWS::Route53.new if @environment.route53_zone_id
      route53 = EC2Launcher::Route53.new(aws_route53, @environment.route53_zone_id, @log)

      ##############################
      # Find instance
      ##############################
      instance = nil
      AWS.memoize do
        instances = ec2.instances.filter("tag:Name", server_name)
        instances.each do |i|
          unless i.status == :shutting_down || i.status == :terminated
            instance = i
            break
          end # unless status
        end # instance loop
      end # memoize

      if instance
        # Remove EBS snapshots
        AWS.memoize do
          remove_snapshots(ec2, instance) if snapshot_removal
        end

        private_ip_address = instance.private_ip_address
        
        run_with_backoff(30, 1, "terminating instance: #{server_name} [#{instance.instance_id}]") do
          instance.terminate
        end

        if route53
          @log.info("Deleting A record from Route53: #{server_name} => #{private_ip_address}")
          route53.delete_record_by_name(server_name, 'A')
        end

        @log.info("Deleting node/client from Chef: #{server_name}")
        node_result = `echo "Y" |knife node delete #{server_name}`
        client_result = `echo "Y" |knife client delete #{server_name}`
        @log.debug("Deleted Chef node: #{node_result}")
        @log.debug("Deleted Chef client: #{client_result}")
      else
        @log.error("Unable to find instance: #{server_name}")
      end
    end

    def remove_snapshots(ec2, instance)
      # Find EBS volumes for instance
      volumes = instance.block_device_mappings.values

      # Iterate over over volumes to find snapshots
      @log.info("  Searching for snapshots...")
      snapshots = []
      volumes.each do |vol|
        volume_snaps = ec2.snapshots.filter("volume-id", vol.id)
        snapshots += volume_snaps
      end

      @log.info("  Deleting #{snapshots.size} snapshots...")
      snapshots.each {|snap| snap.delete }
    end
  end
end