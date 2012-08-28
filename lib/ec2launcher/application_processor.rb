#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'log4r'

require 'ec2launcher/directory_processing'
require 'ec2launcher/dsl/application'
require 'ec2launcher/dsl/environment'

include Log4r

module EC2Launcher
  class ApplicationProcessor
    attr_accessor :applications

    include DirectoryProcessing

    def initialize(base_directory, applications_directories)
      app_dirs = process_directory_list(base_directory, applications_directories, "applications", "Applications", true)

      # Load applications
      @applications = {}
      app_dirs.each do |app_dir|
        Dir.entries(app_dir).each do |application_name|
          filename = File.join(app_dir, application_name)
          next if File.directory?(filename)

          apps = EC2Launcher::DSL::ApplicationDSL.execute(File.read(filename)).applications
          apps.each do |new_application|
            @applications[new_application.name] = new_application
            validate_application(filename, new_application)
          end
        end
      end

      # Process inheritance rules for applications
      @applications.values.each do |app|
        next if app.inherit.nil?

        new_app = process_application_inheritance(app)
        @applications[new_app.name] = new_app
      end
    end

    private

    def process_application_inheritance(app)
        return app if app.inherit.nil?

        # Find base application
        base_app = @applications[app.inherit]
        abort("Invalid inheritance '#{app.inherit}' in #{app.name}") if base_app.nil?

        new_app = nil
        if base_app.inherit.nil?
          # Clone base application
          new_app = Marshal::load(Marshal.dump(base_app))
        else
          new_app = process_application_inheritance(base_app)
        end
        new_app.merge(app)
        new_app
    end

    # Validates all settings in an application file
    #
    # @param [String] filename name of the application file
    # @param [EC2Launcher::DSL::Application] application application object to validate
    #
    def validate_application(filename, application)
      unless application.availability_zone.nil? || AVAILABILITY_ZONES.include?(application.availability_zone)
        abort("Invalid availability zone '#{application.availability_zone}' in application '#{application.name}' (#{filename})")
      end

      unless application.instance_type.nil? || INSTANCE_TYPES.include?(application.instance_type)
        abort("Invalid instance type '#{application.instance_type}' in application '#{application.name}' (#{filename})")
      end
    end
  end
end