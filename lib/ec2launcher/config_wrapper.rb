#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'

require 'ec2launcher/config_loader'
require 'ec2launcher/environment_processor'
require 'ec2launcher/application_processor'

module EC2Launcher
  class ConfigWrapper
    attr_accessor :config
    attr_accessor :applications
    attr_accessor :environments

    def initialize(base_directory)
      # Load configuration data
      config_loader = ConfigLoader.new(base_directory)
      @config = config_loader.config

      env_processor = EnvironmentProcessor.new(base_directory, @config.environments)
      app_processor = ApplicationProcessor.new(base_directory, @config.applications)

      @environments = env_processor.environments
      @applications = app_processor.applications
    end
  end
end