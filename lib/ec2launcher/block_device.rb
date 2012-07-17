#
# Copyright (c) 2012 Sean Laurent
#
class BlockDevice
	attr_reader :mount_point
	attr_reader :name

	def initialize()
		@count = 1
		@group = "root"
		@user = "root"
	end

	def is_raid?()
		@raid_level.nil?
	end

	def count(*block_count)
		if block_count.empty?
			@count
		else
			@count = block_count[0]
			self
		end
	end

	def group(*group)
		if group.empty?
			@group
		else
			@group = group[0]
			self
		end
	end

	def mount(*mount)
		if mount.empty?
			@mount
		else
			@mount_point = mount[0]
			self
		end
	end

	def name(*name)
		if name.empty?
			@name
		else
			@name = name[0]
			self
		end
	end

	def owner(*owner)
		if owner.empty?
			@owner
		else
			@owner = owner[0]
			self
		end
	end

	def raid_level(*raid_level)
		if raid_level.empty?
			@raid_level
		else
			@raid_level = raid_level[0]
			self
		end
	end

	def size(*volume_size)
		if volume_size.empty?
			@size
		else
			@size = volume_size[0].to_i
			self
		end
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