#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'optparse'
require 'ostruct'

require 'ec2launcher/defaults'

module EC2Launcher
  class InitOptions
    attr_reader :command
    attr_reader :options
    attr_reader :location
    attr_reader :hostname

    SUB_COMMANDS = %w{init launch terminate term}

    def initialize
      @opts = OptionParser.new do |opts|
        opts.banner = "Usage: ec2launcher [COMMAND]

  where [COMMAND] is one of:

    init [LOCATION]             Initialize a repository in the specified directory.
    launch [OPTIONS]            Launch a new instance.
    terminate [name] [OPTIONS]  Terminates an instance.

  and [OPTIONS] include:

  "
        opts.separator "Query options:"

        opts.on("-l", "--list", "Show environments and applications.") do
          @options.list = true
        end

        opts.on("-s", "--show-defaults", "Show settings, but do not launch any instances. Does not display user-data.") do
          @options.show_defaults = true
        end

        opts.on("--show-user-data", "Show user-data, but do not launch any instances.") do
          @options.show_user_data = true
        end

        opts.separator ""
        opts.separator "Required Launch options:"

        opts.on("-e", "--environment ENV", "The environment for the server.") do |env|
          @options.environ = env
        end

        opts.on("-a", "--application NAME", "The name of the application class for the new server.") do |app_name|
          @options.application = app_name
        end

        opts.separator ""
        opts.separator "Additional launch options:"

        opts.on("--command [CMD]", String, "Additional command to run during launch sequence.") do |command|
          @options.commands << command
        end

        opts.on("--clone HOST", String, "Clone the latest snapshots from a specific host.") do |clone_host|
          @options.clone_host = clone_host
        end

        opts.on("-c", "--count COUNT", Integer, "Number of new instances to launch.") do |count|
          @options.count = count
        end

        opts.on("--skip-setup", "Skip running the setup scripts. Still runs pre/post commands.") do
          @options.skip_setup = true
        end

        opts.separator ""
        opts.separator "Termination options:"

        opts.on("--[no-]snapshot-removal", "Remove EBS snapshots. Defaults to TRUE.") do |removal|
          @options.snapshot_removal = removal
        end

        opts.separator ""
        opts.separator "Overrides:"

        opts.on("-d", "--directory DIRECTORY", String, "Location of configuration directory. Defaults to current directory.") do |directory|
          @options.directory = directory
        end

        opts.on("-h", "--hostname NAME", String, "The name for the new server.") do |hostname|
          @options.hostname = hostname
        end

        opts.on("-u", "--chef-validation-url", String, "URL for the Chef validation pem file.") do |chef_validation_url|
          @options.chef_validation_url = chef_validation_url
        end

        opts.on("--ami AMI_ID", "AMI id") do |ami_id|
          @options.ami_id = ami_id
        end

        opts.on("-z", "--availability-zone ZONE", EC2Launcher::AVAILABILITY_ZONES, "AWS availability zone (#{EC2Launcher::AVAILABILITY_ZONES.join(', ')}).") do |zone|
          @options.zone = zone
        end

        opts.on("-i", "--instance-type TYPE", EC2Launcher::INSTANCE_TYPES, "EC2 instance type (#{EC2Launcher::INSTANCE_TYPES.join(', ')}).") do |instance_type|
          @options.instance_type = instance_type
        end

        opts.on("--volume-size SIZE", Integer, "EBS volume size in GB. Defaults to #{EC2Launcher::DEFAULT_VOLUME_SIZE} GB") do |volume_size|
          @options.volume_size = volume_size
        end

        opts.separator ""
        opts.separator "AWS Security Options:"

        opts.on("--access-key KEY", String, "Amazon access key. Overrides AWS_ACCESS_KEY environment variable.") do |access_key|
          @options.access_key = access_key
        end

        opts.on("--secret SECRET", String, "Amazon secret access key. Overrides AWS_SECRET_ACCESS_KEY environment variable.") do |secret|
          @options.secret = secret
        end

        opts.separator ""
        opts.separator "Common options:"

        opts.on_tail("-q", "--quiet", "Display as little information as possible.") do
          @options.verbosity = :quiet
        end

        opts.on_tail("-v", "--verbose", "Display as much information as possible.") do
          @options.verbosity = :verbose
        end

        # No argument, shows at tail.  This will print an options summary.
        # Try it and see!
        opts.on_tail("-?", "--help", "Show this message") do
          puts opts
          exit
        end    
      end
    end

    def parse(args)
      @command = args.shift
      unless SUB_COMMANDS.include?(@command)
        puts "Missing command! " if @command.nil?
        puts "Invalid command: #{@command}" unless @command.nil? || @command == "-?" || @command == "--help"
        puts @opts
        exit 1
      end

      @options = OpenStruct.new
      @options.list = false
      @options.show_defaults = false
      @options.show_user_data = false

      @options.environ = nil
      @options.application = nil
      @options.commands = []
      @options.clone_host = nil
      @options.count = 1
      @options.skip_setup = false

      @options.ami_id = nil
      @options.hostname = nil
      @options.zone = nil
      @options.instance_type = nil
      @options.volume_size = nil

      @options.snapshot_removal = true

      @options.verbosity = :normal

      @options.directory = "./"

      if @command == "init"
        unless args.length >= 1
          puts "Missing location!"
          puts
          help
          exit 1
        end
        @location = args[0]
      elsif @command =~ /^term/
        @opts.parse!(args)

        if @options.environ.nil?
          puts "Missing a required parameter: --environment"
          puts
          help
          exit 1
        end

        unless args.length >= 1
          puts "Missing name of server!"
          puts
          help
          exit 1
        end
        @hostname = args[0]
      else
        @opts.parse!(args)

        if (@options.environ.nil? || @options.application.nil?) && ! @options.list
          puts "Missing a required parameter: #{@options.environ.nil? ? '--environment' : '--application'}"
          puts
          help
          exit 1
        end

        if ! @options.hostname.nil? && @options.count > 1
          puts "Cannot specify both a hostname ['#{@options.hostname}'] and multiple instances [#{@options.count}]."
          puts
          exit 1
        end
      end

      @options
    end

    def help
      puts @opts
    end
  end
end