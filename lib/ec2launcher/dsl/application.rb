#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'
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

			dsl_accessor :availability_zone
			dsl_accessor :basename
			dsl_accessor :inherit
			dsl_accessor :instance_type
			dsl_accessor :name_suffix
			dsl_accessor :subnet
			dsl_accessor :use_rvm

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

			def initialize(name)
				@name = name
				
				@email_notifications = nil
				@iam_profile = Hash.new
				@use_rvm = true
			end

			def application(name)
				@name = name
				yield self
				self
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

			def has_provisioned_iops?()
				return false unless @block_devices

				provisioned_iops = false
				@block_devices.each do |bd|
	        if bd.provisioned_iops?
	          provisioned_iops = true
	          break
	        end
				end
				provisioned_iops
			end

			# IAM profile role name to use for new instances.
			#
			# Expects one param in the form of either:
			#   * A string containing the name of the IAM profile
			#   * A Hash mapping environment names (as strings) to IAM profile names (as strings)
			def iam_profile(*data)
				if data.empty?
					@iam_profile
				else
					if data[0].kind_of? Hash
						@iam_profile = data[0]
					else
						@iam_profile["default"] = data[0]
					end
				end
			end

			# Retrieves the IAM profile for a given environment. Or
			# returns the default profile name.
			def iam_profile_for_environment(environment)
				iam_profile = @iam_profile[environment]
				iam_profile ||= @iam_profile["default"]
				iam_profile
			end

			# Takes values from the other server type and merges them into this one
			def merge(other_server)
				@name = other_server.name
				@ami_name = other_server.ami_name if other_server.ami_name
				@availability_zone = other_server.availability_zone if other_server.availability_zone
				@basename = other_server.basename if other_server.basename
				
				unless other_server.block_devices.nil?
					@block_devices = [] if @block_devices.nil?
					other_server.block_devices.each {|bd| @block_devices << bd }
				end
				
				unless other_server.elb.nil?
					@elb = {} if @elb.nil?
					other_server.elb.keys.each {|env_name| @elb[env_name] = other_server.elb[env_name] } 
				end
				
				@iam_profile = other_server.iam_profile if other_server.iam_profile
				@instance_type = other_server.instance_type if other_server.instance_type
				@name_suffix = other_server.name_suffix if other_server.name_suffix
				
				unless other_server.roles.nil?
					@roles = [] if @roles.nil?
					other_server.roles.each {|role| @roles << role } 
				end

				unless other_server.security_groups.nil?
					@security_groups = {} if @security_groups.nil?
					other_server.security_groups.keys.each do |env_name|
						unless @security_groups.has_key? env_name
							@security_groups[env_name] = []
						end
						other_server.security_groups[env_name].each {|sg| @security_groups[env_name] << sg }
					end
				end

				@use_rvm = other_server.use_rvm if other_server.use_rvm
			end

			def roles_for_environment(environment)
				roles = []
				roles += @roles unless @roles.nil?

				if @environment_roles && @environment_roles[environment]
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