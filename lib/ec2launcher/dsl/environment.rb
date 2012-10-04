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

			# @since 1.1.2
			dsl_accessor :iam_profile
			dsl_accessor :inherit
			dsl_accessor :key_name
			dsl_accessor :knife_path
			dsl_accessor :ruby_path
			dsl_accessor :short_name
			dsl_accessor :subnet
			dsl_accessor :use_rvm

			# @since 1.3.0
			dsl_accessor :route53_zone_id

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
				@precommand = []
				@postcommand = []
				@roles = []
				@route53_zone_id = nil
				@security_groups = {}

				@use_rvm = true
			end

			def environment(name)
				@name = name
				yield self
				self
			end

			# Takes values from the other environment and merges them into this one
			def merge(other_env)
				@name =other_env.name

				@gems += other_env.gems if other_env.gems
				@packages += other_env.packages if other_env.packages
				@roles += other_env.roles if other_env.roles
				@precommand += other_env.precommand if other_env.precommand
				@postcommand += other_env.postcommand if other_env.postcommand
				if other_env.security_groups
					other_env.security_groups.keys.each do |key|
						@security_groups[key] = [] if @security_groups[key].nil?
						@security_groups[key] += other_env.security_groups[key]
					end
				end

				@aliases = other_env.aliases.nil? ? nil : other_env.aliases

				@ami_name = other_env.ami_name if other_env.ami_name
				@aws_keyfile = other_env.aws_keyfile if other_env.aws_keyfile
				@availability_zone = other_env.availability_zone if other_env.availability_zone
				@chef_path = other_env.chef_path if other_env.chef_path
				@chef_server_url = other_env.chef_server_url if other_env.chef_server_url
				@chef_validation_pem_url = other_env.chef_validation_pem_url if other_env.chef_validation_pem_url
				@domain_name = other_env.domain_name if other_env.domain_name
				@email_notifications = other_env.email_notifications if other_env.email_notifications
				@gem_path = other_env.gem_path if other_env.gem_path
				@iam_profile = other_env.iam_profile if other_env.iam_profile
				@key_name = other_env.key_name if other_env.key_name
				@knife_path = other_env.knife_path if other_env.knife_path
				@route53_zone_id = other_env.route53_zone_id if other_env.route53_zone_id
				@ruby_path = other_env.ruby_path if other_env.ruby_path
				@subnet = other_env.subnet if other_env.subnet
				@short_name = other_env.short_name if other_env.short_name
				@use_rvm = other_env.use_rvm if other_env.use_rvm
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