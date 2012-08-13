#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'

module EC2Launcher
	module DSL
		class BlockDevice
      include EC2Launcher::DSL::Helper

			attr_reader :mount_point
			attr_reader :name

			dsl_accessor :count
			dsl_accessor :group
			dsl_accessor :mount
			dsl_accessor :name
			dsl_accessor :owner
			dsl_accessor :raid_level
			dsl_accessor :size

			def initialize()
				@count = 1
				@group = "root"
				@user = "root"
			end

			def is_raid?()
				@raid_level.nil?
			end

			def to_json(*a)
				{
					"name" => @name,
					"count" => @count,
					"raid_level" => @raid_level,
					"mount_point" => @mount_point,
					"owner" => @owner,
					"group" => @group
				}.to_json(*a)
			end
		end
	end
end