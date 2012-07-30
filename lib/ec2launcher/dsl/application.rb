#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/block_device'
require 'ec2launcher/dsl/email_notification'
require 'ec2launcher/security_group_handler'

module EC2Launcher
	module DSL
		# Wrapper class to handle loading Application blocks.
		class ApplicationDSL
			attr_accessor :applications

			def initialize
				self.applications = []
			end

			def application(name, &block)
				application = EC2Launcher::DSL::Application.new(name)
				applications << application
				application.instance_eval &block
				application
			end

			def self.execute(dsl)
				new.tap do |context|
					context.instance_eval(dsl)
				end
			end
		end

		# Represents a single application stack.
		class Application
			include EC2Launcher::DSL::EmailNotifications
			include EC2Launcher::SecurityGroupHandler

			attr_reader :name

			def initialize(name)
				@name = name
				@email_notifications = nil
			end

			def application(name)
				@name = name
				yield self
				self
			end

			# Name of the AMI to use for new instances. Optional.
			# Can be either a string or a regular expression.
			#
			# @param [Array, nil] Either an array of parameters or nil to return the AMI name.
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

			# Name of the availability zone to use for new instances. Optional.
			# Must be one of EC2Launcher::AVAILABILITY_ZONES.
			def availability_zone(*zone)
				if zone.empty?
					@availability_zone
				else
					@availability_zone = zone[0].to_s
					self
				end
			end

			# Defines a shorter name when building a host name for new instances. Optional.
			# By default, new instances are named using the full application name. If you 
			# specify basename, it will be used instead. Typically, this is used if you 
			# want a shorter version of the full application name.
			def basename(*name)
				if name.empty?
					@basename
				else
					@basename = name[0]
					self
				end
			end

			def block_devices(*block_device_data)
				if block_device_data.empty?
					@block_devices
				else
					self
				end
			end

			def block_device(&block)
				@block_devices = [] if @block_devices.nil?
				device = EC2Launcher::DSL::BlockDevice.new
				device.instance_exec(&block)
				@block_devices << device
			end

			# Indicates the Amazon Elastic Load Balancer to which new instances should be
			# attached after launch. Optional.
			#
			# The value can be either a String, indicating the name of the ELB, or a Hash
			# that maps environment names to ELB names.
			def elb(*elb)
				if elb.empty?
					@elb
				else
					@elb = Hash.new if @elb.nil?
					if elb[0].kind_of? Hash
						elb[0].keys.each {|key| @elb[key] = elb[0][key]}
					else
						@elb["default"] = elb[0].to_s
					end
					self
				end
			end

			# Retrieves the ELB name for a given environment.
			def elb_for_environment(environment)
				elb_name = @elb[environment]
				elb_name ||= @elb["default"]
				elb_name
			end

			# Defines an Array of Chef roles that should be applied to new
			# instances for a specific environment. Can be specified multiple times.
			#
			# Expects two parameters:
			#   * Name of an environment
			#   * Either the name of a single Chef role or an Array of Chef roles
			def environment_roles(*data)
				if data.empty?
					@environment_roles
				else
					@environment_roles = Hash.new if @environment_roles.nil?
					env_name = data[0]
					env_roles = data[1]

					environment_data = @environment_roles[env_name]
					environment_data ||= []

					if env_roles.kind_of? Array
						environment_data += env_roles
					else
						environment_data << env_roles
					end
					@environment_roles[env_name] = environment_data

					self
				end
			end

			# Gems to install. Optional.
			#
			# Expects either a single String naming a gem to install or
			# an Array of gems.
			#
			# Can be specified multiple times.
			def gems(*gems)
				if gems.empty?
					@gems
				else
					@gems = [] if @gems.nil?
					if gems[0].kind_of? Array
						@gems += gems[0]
					else
						@gems << gems[0]
					end
					self
				end
			end

			# Indicates that this application should inherit all of its settings from another named application.
			# Optional.
			def inherit(*inherit_type)
				if inherit_type.empty?
					@inherit_type
				else
					@inherit_type = inherit_type[0]
				end
			end

			# The Amazon EC2 instance type that should be used for new instances.
			# Must be one of EC2Launcher::INSTANCE_TYPES.
			def instance_type(*type_name)
				if type_name.empty?
					@instance_type
				else
					@instance_type = type_name[0]
					self
				end
			end

			# Takes values from the other server type and merges them into this one
			def merge(other_server)
				@name = other_server.name
				@ami_name = other_server.ami_name unless other_server.ami_name.nil?
				@availability_zone = other_server.availability_zone unless other_server.availability_zone.nil?
				@basename = other_server.basename unless other_server.basename.nil?
				other_server.block_devices.each {|bd| @block_devices << bd } unless other_server.block_devices.nil?
				other_server.elb.keys.each {|env_name| @elb[env_name] = other_server.elb[env_name] } unless other_server.elb.nil?
				@instance_type = other_server.instance_type unless other_server.instance_type.nil?
				@name_suffix = other_server.name_suffix unless other_server.name_suffix.nil?
				other_server.roles.each {|role| @roles << role } unless other_server.roles.nil?
				unless other_server.security_groups.nil?
					other_server.security_groups.keys.each do |env_name|
						unless @security_groups.has_key? env_name
							@security_groups[env_name] = []
						end
						other_server.security_groups[env_name].each {|sg| @security_groups[env_name] << sg }
					end
				end
			end

			def name_suffix(*suffix)
				if suffix.empty?
					@name_suffix
				else
					@name_suffix = suffix[0]
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

			def roles_for_environment(environment)
				roles = []
				roles += @roles unless @roles.nil?

				unless @environment_roles.nil? || @environment_roles[environment].nil?
					roles += @environment_roles[environment]
				end
				roles
			end

			# Retrieves the list of Security Group names for the specified environment.
			#
			# @return [Array] Returns the list of security groups for the environment. Returns
			#                 the security groups for the "defaukt" environment if the requested
			#                 environment is undefined. Returns an empty Array if both the
			#                 requested environment and "default" environment are undefined.
			def security_groups_for_environment(environment)
				groups = @security_groups[environment]
				groups ||= @security_groups[:default]
				groups ||= []
				groups
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
				env = Application.new.instance_eval(dsl)
				env
			end
		end
	end
end