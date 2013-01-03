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

    def initialize(config_directory)
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
    end

    # Terminates a given server instance.
    #
    # @param[String] server_name Name of the server instance
    # @param[String] access_key Amazon IAM access key
    # @param[String] secret Amazon IAM secret key
    # @param[Boolean] snapshot_removal Remove EBS snapshots for EBS volumes attached to the instance.
    # @param[Boolean] force Force instance termination even if environment is not found.
    def terminate(server_name, access_key, secret, snapshot_removal = true, force = false)
      ##############################
      # Initialize AWS and create EC2 connection
      ##############################
      initialize_aws(access_key, secret)
      ec2 = AWS::EC2.new

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
        environment_name = nil
        AWS.memoize do
          environment_name = instance.tags["environment"].strip if instance.tags["environment"]
        end

        ##############################
        # ENVIRONMENT
        ##############################
        if environment_name.nil? && ! force
          @log.fatal "No environment tag found for host. Use the --force option to override and terminate."
          exit 3
        end

        if (! @environments.has_key?(environment_name)) && (! force)
          @log.fatal "Environment not found: '#{environment_name}'"
          exit 2
        end
        @environment = @environments[environment_name] if environment_name

        ##############################
        # Create Route53 connection
        ##############################
        aws_route53 = nil
        if @environment && @environment.route53_zone_id
          aws_route53 = AWS::Route53.new
          route53 = EC2Launcher::Route53.new(aws_route53, @environment.route53_zone_id, @log)
        end

        ##############################
        # EBS Volumes
        ##############################
        # Find EBS volumes
        attachments = nil
        AWS.memoize do
          attachments = instance.block_device_mappings.values

          # Remove snapshots
          remove_snapshots(ec2, attachments) if snapshot_removal

          # Remove volumes, if necessary
          remove_volumes(ec2, attachments)
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

    def remove_snapshots(ec2, attachments)
      # Iterate over over volumes to find snapshots
      @log.info("Searching for snapshots...")
      snapshots = []
      attachments.each do |attachment|
        volume_snaps = ec2.snapshots.filter("volume-id", attachment.volume.id)
        volume_snaps.each {|volume_snapshot| snapshots << volume_snapshot }
      end

      @log.info("Deleting #{snapshots.size} snapshots...")
      snapshots.each do |snap|
        run_with_backoff(30, 1, "Deleting snapshot #{snap.id}") do
          snap.delete
        end
      end
    end

    def remove_volume(ec2, instance, device, volume)
      @log.info("  Detaching #{volume.id}...")
      run_with_backoff(30, 1, "detaching #{volume.id}") do
        volume.detach_from(instance, device)
      end

      # Wait for volume to fully detach
      detached = test_with_backoff(120, 1, "waiting for #{volume.id} to detach") do
        volume.status == :available
      end

      # Volume failed to detach - do a force detatch instead
      unless detached
        @log.info("  Failed to detach #{volume.id}")
        run_with_backoff(60, 1, "force detaching #{volume.id}") do
          unless volume.status == :available
            volume.detach_from(instance, device, {:force => true})
          end
        end
        # Wait for volume to fully detach
        detached = test_with_backoff(120, 1, "waiting for #{volume.id} to force detach") do
          volume.status == :available
        end
      end

      @log.info("  Deleting volume #{volume.id}")
      run_with_backoff(30, 1, "delete volume #{volume.id}") do
        volume.delete
      end
    end

    def remove_volumes(ec2, attachments)
      @log.info("Cleaning up volumes...")

      AWS.memoize do
        removal_threads = []
        attachments.each do |attachment|
          if attachment.exists? && ! attachment.delete_on_termination
            removal_threads << Thread.new {
              remove_volume(ec2, attachment.instance, attachment.device, attachment.volume)
            }
          end
        end

        removal_threads.each {|t| t.join }
      end
    end
  end
end