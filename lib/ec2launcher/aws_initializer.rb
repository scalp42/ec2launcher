#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'

module EC2Launcher
  module AWSInitializer
    # Initializes connections to the AWS SDK
    #
    def initialize_aws(access_key = nil, secret_key = nil)
      aws_access_key = access_key
      aws_access_key ||= ENV['AWS_ACCESS_KEY']

      aws_secret_access_key = secret_key
      aws_secret_access_key ||= ENV['AWS_SECRET_ACCESS_KEY']

      if aws_access_key.nil? || aws_secret_access_key.nil?
        abort("You MUST either set the AWS_ACCESS_KEY and AWS_SECRET_ACCESS_KEY environment variables or use the command line options.")
      end

      AWS.config({
        :access_key_id => aws_access_key,
        :secret_access_key => aws_secret_access_key
      })
    end
  end
end