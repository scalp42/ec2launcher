#
# Copyright (c) 2012 Sean Laurent
#
require 'aws-sdk'

module EC2Launcher
  # Helper module to run AWS requests.
  module BackoffRunner
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
        block.call
      rescue AWS::EC2::Errors::RequestLimitExceeded
        puts "AWS::EC2::Errors::RequestLimitExceeded ... retrying #{message} in #{sleep_time} seconds"
        sleep sleep_time
        run_with_backoff(max_time, sleep_time * 2, message, &block)
      rescue AWS::EC2::Errors::InstanceLimitExceeded
        puts "AWS::EC2::Errors::InstanceLimitExceeded ... aborting launch."
        return false
      rescue Exception => bang
        print "Error for #{message}: #{bang}"
        return false
      end
      true
    end

  end
end