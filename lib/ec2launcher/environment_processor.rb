#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'log4r'

require 'ec2launcher/directory_processing'

include Log4r

module EC2Launcher
  class EnvironmentProcessor
    attr_accessor :environments

    include DirectoryProcessing

    def initialize(base_directory)
      @environments_directories = process_directory_list(base_directory, "environments", "Environments", false)

      # Load other environments
      @environments = { }
      environments_directories.each do |env_dir|
        Dir.entries(env_dir).each do |env_name|
          filename = File.join(env_dir, env_name)
          next if File.directory?(filename)

          new_env = load_environment_file(filename)
          validate_environment(filename, new_env)

          @environments[new_env.name] = new_env
          new_env.aliases.each {|env_alias| @environments[env_alias] = new_env }
        end
      end

      # Process inheritance rules for environments
      @environments.values.each do |env|
        new_env = process_environment_inheritance(env)
        @environments[new_env.name] = new_env
      end

      private

      def process_environment_inheritance(env)
          return env if env.inherit.nil?

          # Find base environment
          base_env = @environments[env.inherit]
          abort("Invalid inheritance '#{env.inherit}' in #{env.name}") if base_env.nil?

          new_env = nil
          if base_env.inherit.nil?
            # Clone base environment
            new_env = Marshal::load(Marshal.dump(base_env))
          else
            new_env = process_environment_inheritance(base_env)
          end
          new_env.merge(env)
          new_env
      end
    end
  end
end