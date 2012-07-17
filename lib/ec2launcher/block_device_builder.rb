#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/defaults'

module EC2Launcher
  # Helper class to build EC2 block device definitions.
  #
  class BlockDeviceBuilder
    attr_reader :block_device_setup
    attr_reader :block_device_mappings
    attr_reader :block_device_tags

    # @param [AWS::EC2] ec2 interface to ec2
    # @param [Integer, nil] volume_size size of new EBS volumes. If set to nil, uses EC2Launcher::Defaults::DEFAULT_VOLUME_SIZE.
    #
    def initialize(ec2, volume_size = nil)
      @ec2 = ec2
      @block_size = volume_size
      @volume_size ||= EC2Launcher::DEFAULT_VOLUME_SIZE
    
      @block_device_setup = {}
      @block_device_mappings = {}
      @block_device_tags = {}
    end
  
    # Iterates over a number of block_devices, executing the specified Ruby block.
    #
    # @param [Integer] count number of block devices
    # @param [String, "sdf"] device the starting device name. Defaults to "sdf". 
    #        Incremented for each iteration.
    # @param [Block] block block to execute. Passes in the current device name and zero-based index.
    #
    def build_block_devices(count, device = "sdf", &block)
      device_name = device
      0.upto(count - 1).each do |index|
        yield device_name, index
        device_name.next!
      end
    end

    # Creates the mappings for the appropriate EBS volumes.
    #
    # @param [String] hostname FQDN for new host
    # @param [String] short_hostname short name for host host, without domain name.
    # @param [String] environment_name name of the environment
    # @param [Array<EC2Launcher::BlockDevice>] block_devices list of block devices to create.
    #
    def build_ebs_volumes(hostname, short_hostname, environment_name, block_devices)
      base_device_name = "sdf"
      block_devices.each do |block_device|
        build_block_devices(block_device.count, base_device_name) do |device_name, index|
          volume_size = block_device.size
          volume_size ||= @volume_size

          block_device_mappings["/dev/#{device_name}"] = {
            :volume_size => volume_size,
            :delete_on_termination => true
          }

          block_device_tags["/dev/#{device_name}"] = {
            "purpose" => block_device.name,
            "host" => hostname,
            "environment" => environment_name
          }
          
          if block_device.raid_level.nil?
            block_device_tags["/dev/#{device_name}"]["Name"] = "#{short_hostname} #{block_device.name}"
          else
            block_device_tags["/dev/#{device_name}"]["Name"] = "#{short_hostname} #{block_device.name} raid (#{(index + 1).to_s})"
            block_device_tags["/dev/#{device_name}"]["raid_number"] = (index + 1).to_s
          end
        end
      end
    end

    # Creates the mappings for the appropriate ephemeral drives.
    #
    # @param [String] instance_type type of instance. See EC2Launcher::Defaults::INSTANCE_TYPES.
    #
    def build_ephemeral_drives(instance_type)
      ephemeral_drive_count = case instance_type
        when "m1.small" then 1
        when "m1.medium" then 1
        when "m2.xlarge" then 1
        when "m2.2xlarge" then 1
        when "c1.medium" then 1
        when "m1.large" then 2
        when "m2.4xlarge" then 2
        when "cc1.4xlarge" then 2
        when "cg1.4xlarge" then 2
        when "m1.xlarge" then 4
        when "c1.xlarge" then 4
        when "cc2.8xlarge" then 4
        else 0
      end
      build_block_devices(ephemeral_drive_count, "sdb") do |device_name, index|
        @block_device_mappings["/dev/#{device_name}"] = "ephemeral#{index}"
      end
    end

    # Finds the EBS snapshots to clone for all appropriate block devices and
    # updates the block device mapping hash.
    #
    # @param [EC2Launcher::Environment] environment current environment
    # @param [EC2Launcher::Application] application current application
    # @param [String] clone_host name of host to clone
    #
    def clone_volumes(environment, application, clone_host)
      return if clone_host.nil?

      puts "Retrieving snapshots..."
      AWS.start_memoizing
      base_device_name = "sdf"
      application.block_devices.each do |block_device|
        if block_device.raid_level.nil?
          @block_device_mappings["/dev/#{base_device_name}"][:snapshot_id] = get_latest_snapshot(clone_short_hostname, clone_host, block_device.name).id
          base_device_name.next!
        else
          snapshots = get_latest_raid_snapshot_mapping(clone_host, block_device.name, block_device.count)
          build_block_devices(block_device.count, base_device_name) do |device_name, index|
            @block_device_mappings["/dev/#{device_name}"][:snapshot_id] = snapshots[(index + 1).to_s].id
          end
        end
      end
      AWS.stop_memoizing
    end

    # Generates the mappings for ephemeral and ebs volumes.
    #
    # @param [String] hostname FQDN for new host
    # @param [String] short_hostname short name for host host, without domain name.
    # @param [String] instance_type type of instance. See EC2Launcher::Defaults::INSTANCE_TYPES.
    # @param [EC2Launcher::Environment] environment current environment
    # @param [EC2Launcher::Application] application current application
    # @param [String, nil] clone_host FQDN of host to clone or nill to skip cloning.
    #
    def generate_block_devices(hostname, short_hostname, instance_type, environment, application, clone_host = nil)
      build_ephemeral_drives(instance_type)
      build_ebs_volumes(hostname, short_hostname, environment.name, application.block_devices)
      clone_volumes(environment, application, clone_host)
    end

    # Retrieves the latest set of completed snapshots for a RAID array of EBS volumes.
    #
    # Volumes must have the following tags:
    #   * host
    #   * volumeName
    #   * time
    #
    # @param [String] hostname FQDN for new host
    # @param [String] purpose purpose of RAID array, which is stored in the `purpose` tag for snapshots/volumes
    #        and is part of the snapshot name.
    # @param [Integer] count number of EBS snapshots to look for
    #
    # @return [Hash<Integer, AWS::EC2::Snapshot>] mapping of RAID device numbers (zero based) to AWS Snapshots.
    #
    def get_latest_raid_snapshot_mapping(hostname, purpose, count)
      puts "Retrieving list of snapshots ..."
      result = @ec2.snapshots.tagged("host").tagged_values(hostname).tagged("volumeName").tagged_values("*raid*").tagged("time")

      puts "Building list of snapshots to clone (#{purpose}) for '#{hostname}'..."
      snapshot_name_regex = /#{purpose} raid.*/
      host_snapshots = []
      result.each do |s|
        next if snapshot_name_regex.match(s.tags["volumeName"]).nil?
        host_snapshots << s if s.status == :completed
      end

      # Bucket the snapshots based on volume number e.g. "raid (1)" vs "raid (2)"
      snapshot_buckets = { }
      volume_number_regex = /raid \((\d)\)$/
      host_snapshots.each do |snapshot|
        next if snapshot.tags["time"].nil?

        volume_name = snapshot.tags["volumeName"]

        match_info = volume_number_regex.match(volume_name)
        next if match_info.nil?

        matches = match_info.captures
        next if matches.length != 1

        raid_number = matches[0]

        snapshot_buckets[raid_number] = [] if snapshot_buckets[raid_number].nil?
        snapshot_buckets[raid_number] << snapshot
      end

      # Sort the snapshots in each bucket by time
      snapshot_buckets.keys.each do |key|
        snapshot_buckets[key].sort! do |a, b|
          b.tags["time"] <=> a.tags["time"]
        end
      end

      # We need to find the most recent backup time that all snapshots have in common.
      #
      # For example, we may have the following snapshots for "raid (1)":
      #   volumeName => db1.dev db raid (1), time => 11-06-15 10:00
      #   volumeName => db1.dev db raid (1), time => 11-06-15 09:00
      #   volumeName => db1.dev db raid (1), time => 11-06-14 09:00
      # And the following snapshots for "raid (2)":
      #   volumeName => db1.dev db raid (1), time => 11-06-15 09:00
      #   volumeName => db1.dev db raid (1), time => 11-06-14 09:00
      #
      # In this example, the latest snapshot from "raid (1)" is dated "11-06-15 10:00", but "raid (2)" does not have
      # a matching snapshot (because it hasn't completed yet). Instead, we should use the "11-06-15 09:00" snapshots.
      #
      # We find the most recent date from each bucket and then take the earliest one.
      most_recent_dates = []
      snapshot_buckets.keys().each do |key|
        snapshot = snapshot_buckets[key][0]
        most_recent_dates << snapshot.tags["time"].to_s
      end
      most_recent_dates.sort!

      puts "Most recent snapshot: #{most_recent_dates[0]}"

      snapshot_mapping = { }
      AWS.memoize do
        snapshot_buckets.keys.each do |index|
          found = false
          snapshot_buckets[index].each do |snapshot|
            if snapshot.tags["time"] == most_recent_dates[0]
              snapshot_mapping[index] = snapshot
              found = true
              break
            end
          end

          abort("***** ERROR: Unable to find snapshot for #{purpose} (#{index.to_s})") unless found
        end
      end
      snapshot_mapping
    end

    # Retrieves the most recent snapshot with a specific name AND one or more other filters
    #
    # @param [String] server_name name of server with the volume to clone.
    # @param [String, nil] extra additional AWS compatible filters for searching.
    #
    # @return [AWS::EC2::Snapshot, nil] matching snapshot or nil if no matching snapshot
    #
    def get_latest_snapshot(server_name, extra = nil)
      puts "  Retrieving snapshot for #{server_name} #{extra}"

      filter = server_name
      filter += " (#{server_name} #{extra})" unless extra.nil? || extra.empty?
      get_latest_snapshot_by_name(filter)
    end

    # Retrieves the most recent snapshot for a volume with a specific name
    #
    # @param [String] name_filter AWS compatible filter for the Name tag on a snapshot
    #
    # @return [AWS::EC2::Snapshot, nil] matching snapshot or nil if no matching snapshot
    #
    def get_latest_snapshot_by_name(name_filter)
      puts "  Retrieving snapshot with filter tag:Name='#{name_filter}'"

      snapshot = nil
      @ec2.snapshots.filter("tag:Name", name_filter).each do |s|
        next unless s.status == :completed
        snapshot = s if snapshot.nil? || snapshot.start_time < s.start_time
      end
      snapshot
    end
  end
end