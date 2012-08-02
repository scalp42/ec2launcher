#
# Copyright (c) 2012 Sean Laurent
#
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
      
      def initialize()
        @environments = []
        @applications = []
      end

      def environments(*environments)
        if environments.empty?
          @environments
        else
          if environments[0].kind_of? Array
            @environments = @environments[0]
          else
            @environments = [ environments[0] ]
          end
          self
        end
      end

      def applications(*applications)
        if applications.empty?
          @applications
        else
          if applications[0].kind_of? Array
            @applications = @applications[0]
          else
            @applications = [ applications[0] ]
          end
          self
        end
      end

      def package_manager(*package_manager)
        if package_manager.empty?
          @package_manager
        else
          @package_manager = package_manager[0]
        end
      end

      def config_manager(*config_manager)
        if config_manager.empty?
          @config_manager
        else
          @config_manager = config_manager[0]
        end
      end

      def gem_path(*gem_path)
        if gem_path.empty?
          @gem_path
        else
          @gem_path = gem_path[0]
        end
      end

      def ruby_path(*ruby_path)
        if ruby_path.empty?
          @ruby_path
        else
          @ruby_path = ruby_path[0]
        end
      end

      def chef_path(*chef_path)
        if chef_path.empty?
          @chef_path
        else
          @chef_path = chef_path[0]
        end
      end

      def knife_path(*knife_path)
        if knife_path.empty?
          @knife_path
        else
          @knife_path = knife_path[0]
        end
      end
    end
  end
end