#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/email_notification'
require 'ec2launcher/security_group_handler'

module EC2Launcher
	class Environment
		include EC2Launcher::EmailNotifications
		include EC2Launcher::SecurityGroupHandler

		attr_reader :name
		attr_reader :precommands
		attr_reader :postcommands

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

		def aws_keyfile(*aws_keyfile)
			if aws_keyfile.empty?
				@aws_keyfile
			else
				@aws_keyfile = aws_keyfile[0]
				self
			end
		end

		def aliases(*aliases)
			if aliases.empty?
				@aliases
			else
				if aliases[0].kind_of? String
					@aliases = [ aliases[0] ]
				else
					@aliases = aliases[0]
				end
			end
		end

		def ami_name(*ami_name)
			if ami_name.empty?
				@ami_name
			else
				if ami_name[0].kind_of? String
					@ami_name = /#{ami_name[0]}/
				else
					@ami_name = ami_name[0]
				end
				self
			end
		end

		def availability_zone(*zone)
			if zone.empty?
				@availability_zone
			else
				@availability_zone = zone[0].to_s
				self
			end
		end

		def chef_server_url(*server_url)
			if server_url.empty?
				@chef_server_url
			else
				@chef_server_url = server_url[0]
				self
			end
		end

		def chef_validation_pem_url(*chef_validation_pem_url)
			if chef_validation_pem_url.empty?
				@chef_validation_pem_url
			else
				@chef_validation_pem_url = chef_validation_pem_url[0]
				self
			end
		end

		def domain_name(*domain_name)
			if domain_name.empty?
				@domain_name
			else
				@domain_name = domain_name[0]
				self
			end
		end

		def gems(*gems)
			if gems.empty?
				@gems
			else
				@gems = gems[0]
				self
			end
		end

		def inherit(*inherit_type)
			if inherit_type.empty?
				@inherit_type
			else
				@inherit_type = inherit_type[0]
			end
		end

		def key_name(*key)
			if key.empty?
				@key_name
			else
				@key_name = key[0]
				self
			end
		end

		def packages(*packages)
			if packages.empty?
				@packages
			else
				@packages = packages[0]
				self
			end
		end

		def precommand(*command)
			@precommands << command[0]
		end

		def postcommand(*command)
			@postcommands << command[0]
		end

		def roles(*roles)
			if roles.empty?
				@roles
			else
				@roles = [] if @roles.nil?
				if roles[0].kind_of? Array
					@roles += roles[0]
				else
					@roles = []
					@roles << roles[0]
				end
				self
			end
		end

		def short_name(*short_name)
			if short_name.empty?
				@short_name
			else
				@short_name = short_name[0]
				self
			end
		end

		def subnet(*subnet)
			if subnet.empty?
				@subnet
			else
				@subnet = subnet[0]
				self
			end
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
			@chef_server_url = other_env.chef_server_url unless other_env.chef_server_url.nil?
			@chef_validation_pem_url = other_env.chef_validation_pem_url unless other_env.chef_validation_pem_url.nil?
			@domain_name = other_env.domain_name unless other_env.domain_name.nil?
			@email_notifications = other_env.email_notifications unless other_env.email_notifications.nil?
			@key_name = other_env.key_name unless other_env.key_name.nil?
			@subnet = other_env.subnet unless other_env.subnet.nil?
			@short_name = other_env.short_name unless other_env.short_name.nil?
	end

		def load(dsl)
			self.instance_eval(dsl)
			self
		end

		def self.load(dsl)
			env = Environment.new.instance_eval(dsl)
			env
		end
	end
end