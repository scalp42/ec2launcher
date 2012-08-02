#
# Copyright (c) 2012 Sean Laurent
#
module EC2Launcher
  # Holds data about paths to various executables on instances.
  class InstancePathsConfig
    attr_reader :gem_path, :ruby_path, :chef_path, :knife_path

    def initialize(environment)
      @gem_path = build_path(environment.gem_path, "gem", "/usr/bin/gem")
      @ruby_path = build_path(environment.ruby_path, "ruby", "/usr/bin/ruby")
      @chef_path = build_path(environment.chef_path, "chef-client", "/usr/bin/chef-client")
      @knife_path = build_path(environment.knife_path, "knife", "/usr/bin/knife")
    end

    private

    # Builds the path to an executable.
    def build_path(instance_path, executable, default_path)
      app_path = default_path
      unless instance_path.nil?
        if instance_path =~ /#{executable}$/
          app_path = instance_path
        else
          app_path = File.join(instance_path, executable)
        end
      end
      app_path
    end
  end
end