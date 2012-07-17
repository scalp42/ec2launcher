#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/email_notification'

module EC2Launcher
	class Environment
		include EmailNotifications

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

		def security_groups(*security_groups)
			if security_groups.empty?
				@security_groups
			else
				@security_groups = [] if @security_groups.nil?
				if security_groups[0].kind_of? Array
					@security_groups += security_groups[0]
				else
					@security_groups << security_groups[0]
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