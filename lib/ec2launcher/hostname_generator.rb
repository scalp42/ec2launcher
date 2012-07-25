#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'

module EC2Launcher
  # Helper class to generate sequential, numbered host names
  class HostnameGenerator
    # 
    # @param [AWS::EC2] ec2 EC2 object used to query for existing instances
    # @param [EC2Launcher::Environment] environment Environment to use for generating host names
    # @param [EC2Launcher::Application] application Application to use for generating hostn ames
    def initialize(ec2, environment, application)
      @ec2 = ec2
      @server_name_cache = nil

      @prefix = application.basename
      @prefix ||= application.name

      @env_suffix = environment.short_name
      @env_suffix ||= environment.name
      
      @suffix = @env_suffix
      unless application.name_suffix.nil?
        @suffix = "#{application.name_suffix}.#{@env_suffix}"
      end

      @host_number_regex = Regexp.new("#{@prefix}(\\d+)[.]#{@suffix.gsub(/[.]/, "[.]")}.*")

      # Load and cache instance names
      load_instances(@prefix, @suffix)
    end

    # Generates a new host name and automatically caches it
    # so that future requests don't use the same name.
    def generate_hostname()
      # Find next host number
      host_number = get_next_host_number()

      # Build short host name
      short_name = "#{@prefix}#{host_number}.#{@suffix}"

      # Cache the new hostname
      @server_name_cache << short_name

      short_name
    end

    def generate_long_name(short_hostname, domain_name = nil)
      hostname = short_hostname
      unless domain_name.nil?
        hostname += ".#{domain_name}"
      end

      hostname
    end

    def generate_short_name(long_name, domain_name = nil)
      short_hostname = long_name
      unless domain_name.nil?
        short_hostname = long_name.gsub(/.#{domain_name}/, '')
      end
      short_hostname
    end

    private

    # Loads and caches instance host names
    def load_instances(prefix, suffix)
      @server_name_cache = []
      AWS.memoize do
        server_instances = @ec2.instances.filter("tag:Name", "#{prefix}*#{suffix}*")
        server_instances.each do |i|
          next if i.status == :terminated
          @server_name_cache << i.tags[:Name]
        end
      end
    end

    # Determines the next available number for a host name
    def get_next_host_number()
      highest_server_number = 0
      lowest_server_number = 32768
      
      server_numbers = []

      @server_name_cache.each do |server_name|
        unless @host_number_regex.match(server_name).nil?
          server_num = $1.to_i
          server_numbers << server_num
        end
      end
      highest_server_number = server_numbers.max
    
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

      host_number
    end
  end
end