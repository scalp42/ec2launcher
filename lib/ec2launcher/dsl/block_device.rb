#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'
require 'json'

module EC2Launcher
	module DSL
		class BlockDevice
			attr_reader :mount_point
			attr_reader :name

			dsl_accessor :count
			dsl_accessor :group
			dsl_accessor :mount
			dsl_accessor :name
			dsl_accessor :owner
			dsl_accessor :raid_level
			dsl_accessor :size
			dsl_accessor :iops

			def initialize()
				@count = 1
				@group = "root"
				@user = "root"
			end

			def is_raid?()
				@raid_level.nil?
			end

			def provisioned_iops?()
				! @iops.nil? || @iops == 0
			end

			def as_json(*)
				{
					JSON.create_id => self.class.name,
					"data" => {
						"name" => @name,
						"count" => @count,
						"size" => @size,
						"iops" => @iops,
						"raid_level" => @raid_level,
						"mount_point" => @mount,
						"owner" => @owner,
						"group" => @group
					}
				}
			end

			def to_json(*a)
				as_json.to_json(*a)
			end

			def self.json_create(o)
				new(o['data'])
			end
		end
	end
end