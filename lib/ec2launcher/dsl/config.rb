#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'

module EC2Launcher
  module DSL
    class ConfigDSL
      attr_reader :config

      def config(&block)
        return @config if block.nil?
        
        @config = Config.new
        @config.instance_eval &block
        @config
      end

      def self.execute(dsl)
        new.tap do |context|
          context.instance_eval(dsl)
        end
      end
    end

    class Config
      DEFAULT_CONFIG_ERB = %q{
config do
  environments "environments"
  applications "applications"

  package_manager "apt"
  config_manager "chef"
end
}.gsub(/^ /, '')

      dsl_accessor :package_manager
      dsl_accessor :config_manager

      dsl_array_accessor :applications
      dsl_array_accessor :environments
      
      def initialize()
        @environments = []
        @applications = []
      end
    end
  end
end