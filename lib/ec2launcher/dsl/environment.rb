#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'
require 'ec2launcher/dsl/email_notification'
require 'ec2launcher/security_group_handler'

module EC2Launcher
	module DSL
		class Environment
			include EC2Launcher::DSL::EmailNotifications
			include EC2Launcher::SecurityGroupHandler

			attr_reader :name
			attr_reader :precommands
			attr_reader :postcommands

			dsl_accessor :availability_zone
			dsl_accessor :aws_keyfile
			dsl_accessor :chef_path
			dsl_accessor :chef_server_url
			dsl_accessor :chef_validation_pem_url
			dsl_accessor :domain_name
			dsl_accessor :gem_path
			dsl_accessor :inherit
			dsl_accessor :key_name
			dsl_accessor :knife_path
			dsl_accessor :ruby_path
			dsl_accessor :short_name
			dsl_accessor :subnet

			dsl_array_accessor :aliases
			dsl_array_accessor :gems
			dsl_array_accessor :packages
			dsl_array_accessor :precommand
			dsl_array_accessor :postcommand
			dsl_array_accessor :roles

			# Name of the AMI to use for new instances. Optional.
			# Can be either a string or a regular expression.
			#
			# @param [Array, nil] Either an array of parameters or nil to return the AMI name.
			dsl_regex_accessor :ami_name

			def initialize()
				@aliases = []
				@email_notifications = nil
				@gems = []
				@packages = []
				@precommands = []
				@postcommands = []
				@roles = []
				@security_groups = {}
			end

			def environment(name)
				@name = name
				yield self
				self
			end

			# Takes values from the other environment and merges them into this one
			def merge(other_env)
				@name =other_env.name

				@gems += other_env.gems unless other_env.gems.nil?
				@packages += other_env.packages unless other_env.packages.nil?
				@roles += other_env.roles unless other_env.roles.nil?
				@precommands += other_env.precommands unless other_env.precommands.nil?
				@postcommands += other_env.postcommands unless other_env.postcommands.nil?
				unless other_env.security_groups.nil?
					other_env.security_groups.keys.each do |key|
						@security_groups[key] = [] if @security_groups[key].nil?
						@security_groups[key] += other_env.security_groups[key]
					end
				end

				@aliases = other_env.aliases.nil? ? nil : other_env.aliases

				@ami_name = other_env.ami_name unless other_env.ami_name.nil?
				@aws_keyfile = other_env.aws_keyfile unless other_env.aws_keyfile.nil?
				@availability_zone = other_env.availability_zone unless other_env.availability_zone.nil?
				@chef_path = other_env.chef_path unless other_env.chef_path.nil?
				@chef_server_url = other_env.chef_server_url unless other_env.chef_server_url.nil?
				@chef_validation_pem_url = other_env.chef_validation_pem_url unless other_env.chef_validation_pem_url.nil?
				@domain_name = other_env.domain_name unless other_env.domain_name.nil?
				@email_notifications = other_env.email_notifications unless other_env.email_notifications.nil?
				@gem_path = other_env.gem_path unless other_env.gem_path.nil?
				@key_name = other_env.key_name unless other_env.key_name.nil?
				@knife_path = other_env.knife_path unless other_env.knife_path.nil?
				@ruby_path = other_env.ruby_path unless other_env.ruby_path.nil?
				@subnet = other_env.subnet unless other_env.subnet.nil?
				@short_name = other_env.short_name unless other_env.short_name.nil?
		end

			def load(dsl)
				self.instance_eval(dsl)
				self
			end

			def self.load(dsl)
				env = EC2Launcher::DSL::Environment.new.instance_eval(dsl)
				env
			end
		end
	end
end