#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'log4r'

require 'ec2launcher/directory_processing'

module EC2Launcher
  class EnvironmentProcessor
    attr_accessor :environments

    include DirectoryProcessing

    def initialize(base_directory, environments_directories)
      env_dirs = process_directory_list(base_directory, environments_directories, "environments", "Environments", false)

      # Load other environments
      @environments = { }
      env_dirs.each do |env_dir|
        Dir.entries(env_dir).each do |env_name|
          filename = File.join(env_dir, env_name)
          next if File.directory?(filename)

          new_env = load_environment_file(filename)
          validate_environment(filename, new_env)

          @environments[new_env.name] = new_env
        end
      end

      # Process inheritance rules for environments
      @environments.values.each do |env|
        new_env = process_environment_inheritance(env)
        @environments[new_env.name] = new_env
      end

      # Process aliases
      @environments.values.each do |env|
        env.aliases.each {|env_alias| @environments[env_alias] = env }
      end
    end

    private

    # Load and parse an environment file
    #
    # @param [String] name full pathname of the environment file to load
    # @param [EC2Launcher::Environment, nil] default_environment the default environment, 
    #        which will be used as the base for the new environment. Optional.
    # @param [Boolean] fail_on_missing print an error and exit if the file does not exist.
    #
    # @return [EC2Launcher::Environment] the new environment loaded from the specified file.
    #
    def load_environment_file(name, fail_on_missing = false)
      unless File.exists?(name)
        abort("Unable to read environment: #{name}") if fail_on_missing
        return nil
      end

      load_env = EC2Launcher::DSL::Environment.new
      load_env.load(File.read(name))
      load_env
    end

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
  
    # Validates all settings in an environment file
    #
    # @param [String] filename name of the environment file
    # @param [EC2Launcher::DSL::Environment] environment environment object to validate
    #
    def validate_environment(filename, environment)
      unless environment.availability_zone.nil? || AVAILABILITY_ZONES.include?(environment.availability_zone)
        abort("Invalid availability zone '#{environment.availability_zone}' in environment '#{environment.name}' (#{filename})")
      end
    end
  end
end