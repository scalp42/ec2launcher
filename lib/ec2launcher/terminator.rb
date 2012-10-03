#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'
require 'log4r'

require 'ec2launcher/aws_initializer'
require 'ec2launcher/backoff_runner'

module EC2Launcher
  class Terminator
    include AWSInitializer
    include BackoffRunner

    def initialize()
      @log = Logger.new 'ec2launcher'
      log_output = Outputter.stdout
      log_output.formatter = PatternFormatter.new :pattern => "%m"
      @log.outputters = log_output
    end

    def terminate(server_name, options)
      ##############################
      # Initialize AWS and create EC2 connection
      ##############################
      initialize_aws(options.access_key, options.secret)
      @ec2 = AWS::EC2.new
      instance = nil
      AWS.memoize do
        instances = @ec2.instances.filter("tag:Name", server_name)
        instances.each do |i|
          unless i.status == :shutting_down || i.status == :terminated
            instance = i
            break
          end # unless status
        end # instance loop
      end # memoize

      if instance
        @log.info("Terminating instance: #{server_name} [#{instance.instance_id}]")
        instance.terminate
        @log.info("Deleting node/client from Chef: #{server_name}")
        node_result = `echo "Y" |knife node delete #{server_name}`
        client_result = `echo "Y" |knife client delete #{server_name}`
        @log.debug("Deleted Chef node: #{node_result}")
        @log.debug("Deleted Chef client: #{client_result}")
      else
        @log.error("Unable to find instance: #{server_name}")
      end
    end
  end
end