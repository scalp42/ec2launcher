#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'log4r'

require 'ec2launcher/dsl/config'

include Log4r

module EC2Launcher
  class ConfigLoader
    attr_accessor :config

    def initialize(base_directory)
      @config = load_config_file(base_directory)
    end

    # Read in the configuration file stored in the workspace directory.
    # By default this will be './config.rb'.
    #
    # @return [EC2Launcher::Config] the parsed configuration object
    def load_config_file(base_directory)
      # Load configuration file
      config_filename = File.join(base_directory, "config.rb")
      abort("Unable to find 'config.rb' in '#{base_directory}'") unless File.exists?(config_filename)
      EC2Launcher::DSL::ConfigDSL.execute(File.read(config_filename)).config
    end
  end
end