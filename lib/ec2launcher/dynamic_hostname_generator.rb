#
# Copyright (c) 2012-2013 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'

require 'ec2launcher/hostnames/host_name_generation'

module EC2Launcher
  # Helper class to generate unique host names
  class DynamicHostnameGenerator
    include HostNames::HostNameGeneration

    # Creates a new generator for dynamic host names.
    #
    # @param [String] prefix  Optional prefix for the hostname.
    # @param [String] suffix  Optional suffix for the hostname.
    def initialize(prefix = nil, suffix = nil)
      @prefix = prefix
      @suffix = suffix
    end

    # Given an instance id, generates a dynamic short hostname typically in the form:
    #
    #   prefix + INSTANCE ID + application + environment
    #
    # Examples:
    #   9803da2.web.prod (no prefix)   
    #   app-d709aa2ab.server.dev (prefix = "app-")
    #
    # @param [String] instance_id   AWS EC2 instance id
    #
    def generate_dynamic_hostname(instance_id)
      instance_id_name = (instance_id =~ /^i-/ ? instance_id.gsub(/^i-/, '') : instance_id)

      short_name = nil
      short_name = @prefix if @prefix
      short_name += instance_id_name
      short_name += ".#{@suffix}" if @suffix

      short_name
    end
  end
end
