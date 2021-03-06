#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/defaults'
require 'ec2launcher/backoff_runner'
require 'log4r'

module EC2Launcher
  # Helper class to build EC2 block device definitions.
  #
  class BlockDeviceBuilder
    include BackoffRunner

    attr_reader :block_device_mappings
    attr_reader :block_device_tags

    # @param [AWS::EC2] ec2               Interface to ec2
    # @param [Integer, nil] volume_size   Size of new EBS volumes. If set to nil, uses EC2Launcher::Defaults::DEFAULT_VOLUME_SIZE.
    # @param [Log4r, nil] logger          Optional logger.
    #
    def initialize(ec2, volume_size = nil, logger = nil)
      @ec2 = ec2
      @block_size = volume_size
      @volume_size ||= EC2Launcher::DEFAULT_VOLUME_SIZE

      @block_device_mappings = {}
      @block_device_tags = {}

      begin
        @log = logger
        @log ||= Log4r::Logger['ec2launcher']
      rescue
      end

      @log ||= Log4r::Logger.new 'ec2launcher'
    end

    # Generates the mappings for ephemeral and ebs volumes.
    #
    # @param [String] instance_type type of instance. See EC2Launcher::Defaults::INSTANCE_TYPES.
    # @param [EC2Launcher::Environment] environment current environment
    # @param [EC2Launcher::Application] application current application
    # @param [String, nil] clone_host FQDN of host to clone or nil to skip cloning.
    #
    # @return [Hash<String, Hash] returns a mapping of device names to device details
    #
    def generate_block_devices(instance_type, environment, application, clone_host = nil)
      block_device_mappings = {}

      build_ephemeral_drives(block_device_mappings, instance_type)
      build_ebs_volumes(block_device_mappings, application.block_devices)
      clone_volumes(block_device_mappings, application, clone_host)

      block_device_mappings
    end

    # Generates a mapping of block device names to tags.
    #
    # @param [String] hostname FQDN for new host
    # @param [String] short_hostname short name for host host, without domain name.
    # @param [String] environment_name Name of current environment
    # @param [EC2Launcher::DSL::BlockDevice] block devices for this application
    #
    # @return [Hash<String, Hash<String, String>] returns a mapping of device names to maps tag names and values.
    def generate_device_tags(hostname, short_hostname, environment_name, block_devices)
      block_device_tags = {}
      unless block_devices.nil?
        base_device_name = "sdf"
        block_devices.each do |block_device|
          build_block_devices(block_device.count, base_device_name) do |device_name, index|
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
      block_device_tags
    end

    # Iterates over a number of block_devices, executing the specified Ruby block.
    #
    # @param [Integer] count number of block devices
    # @param [String, "sdf"] device the starting device name. Defaults to "sdf". 
    #        Incremented for each iteration.
    # @param [Block] block block to execute. Passes in the current device name and zero-based index.
    #
    private
    def build_block_devices(count, device = "sdf", &block)
      device_name = device
      0.upto(count - 1).each do |index|
        yield device_name, index
        device_name.next!
      end
    end

    # Creates the mappings for the appropriate EBS volumes.
    #
    # @param [Hash<String, Hash>] block_device_mappings Mapping of device names to EBS block device details.
    # @param [Array<EC2Launcher::BlockDevice>] block_devices list of block devices to create.
    #
    private
    def build_ebs_volumes(block_device_mappings, block_devices)
      return if block_devices.nil?
      base_device_name = "sdf"
      block_devices.each do |block_device|
        build_block_devices(block_device.count, base_device_name) do |device_name, index|
          volume_size = block_device.size
          volume_size ||= @volume_size

          block_device_mappings["/dev/#{device_name}"] = {
            :volume_size => volume_size,
            :delete_on_termination => block_device.iops.nil?
          }

          block_device_mappings["/dev/#{device_name}"][:iops] = block_device.iops if block_device.iops
        end
      end
    end

    # Creates the mappings for the appropriate ephemeral drives.
    #
    # @param [Hash<String, Hash>] block_devices Map of device names to EC2 block device details.
    # @param [String] instance_type type of instance. See EC2Launcher::Defaults::INSTANCE_TYPES.
    #
    private
    def build_ephemeral_drives(block_device_mappings, instance_type)
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
        block_device_mappings["/dev/#{device_name}"] = "ephemeral#{index}"
      end
    end

    # Finds the EBS snapshots to clone for all appropriate block devices and
    # updates the block device mapping hash.
    #
    # @param [Hash<String, Hash>] block_devices Map of device names to EC2 block device details.
    # @param [EC2Launcher::Application] application current application
    # @param [String] clone_host name of host to clone
    #
    private
    def clone_volumes(block_device_mappings, application, clone_host = nil)
      return if clone_host.nil?

      @log.info "Retrieving snapshots..."
      AWS.start_memoizing
      base_device_name = "sdf"
      application.block_devices.each do |block_device|
        if block_device.raid_level.nil?
          latest_snapshot = get_latest_snapshot_by_purpose(clone_host, block_device.name)
          abort("Unable to find snapshot for #{clone_host} [#{block_device.name}]") if latest_snapshot.nil?
          block_device_mappings["/dev/#{base_device_name}"][:snapshot_id] = latest_snapshot.id
          base_device_name.next!
        else
          snapshots = get_latest_raid_snapshot_mapping(clone_host, block_device.name, block_device.count)
          abort("Unable to find snapshot for #{clone_host} [#{block_device.name}]") if snapshots.nil? 
          abort("Incorrect snapshot count for #{clone_host} [#{block_device.name}]. Expected: #{block_device.count}, Found: #{snapshots.length}") if snapshots.length != block_device.count
          build_block_devices(block_device.count, base_device_name) do |device_name, index|
            block_device_mappings["/dev/#{device_name}"][:snapshot_id] = snapshots[(index + 1).to_s].id
          end
        end
      end
      AWS.stop_memoizing
    end

    # @param [String] purpose purpose of RAID array, which is stored in the `purpose` tag for snapshots/volumes
    #        and is part of the snapshot name.
    # @param [AWS::EC2::SnapshotCollection] snapshots collection of snapshots to examine
    #
    # @return [Array<AWS::EC2::Snapshot>] list of matching snapshots
    private
    def build_snapshot_clone_list(purpose, snapshots)
      snapshot_name_regex = /#{purpose} raid.*/
      host_snapshots = []
      snapshots.each do |s|
        name_no_match = false
        run_with_backoff(60, 1, "searching for snapshots") do
          name_no_match = snapshot_name_regex.match(s.tags["volumeName"]).nil?
        end
        next if name_no_match

        run_with_backoff(60, 1, "searching for snapshots") do
          host_snapshots << s if s.status == :completed
        end
      end
      host_snapshots
    end

    # Creates a mapping of volume numbers to snapshots.
    #
    # @param [Array<AWS::EC2::Snapshot>] snapshots list of matching snapshots
    # @result [Hash<String, AWS::EC2::Snapshot>] map of volume numbers as strings  ("1", "2", etc.) to snapshots
    private
    def bucket_snapshots_by_volume_number(snapshots)
      snapshot_buckets = { }
      volume_number_regex = /raid \((\d)\)$/
      snapshots.each do |snapshot|
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
      snapshot_buckets
    end

    # Find the most recent backup time that all snapshots have in common.
    #
    # @param [Hash<String, AWS::EC2::Snapshot>] snapshot_buckets map of volume numbers as strings  ("1", "2", etc.) to snapshots
    public
    def get_most_recent_common_snapshot_time(snapshot_buckets)
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
      most_recent_dates[0]
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
    public
    def get_latest_raid_snapshot_mapping(hostname, purpose, count)
      @log.info "Retrieving list of snapshots ..."
      result = @ec2.snapshots.tagged("host").tagged_values(hostname).tagged("volumeName").tagged_values("*raid*").tagged("time")

      @log.info "Building list of snapshots to clone (#{purpose}) for '#{hostname}'..."
      host_snapshots = build_snapshot_clone_list(purpose, result)

      # Bucket the snapshots based on volume number e.g. "raid (1)" vs "raid (2)"
      snapshot_buckets = bucket_snapshots_by_volume_number(host_snapshots)

      # Sort the snapshots in each bucket by time
      snapshot_buckets.keys.each do |key|
        snapshot_buckets[key].sort! do |a, b|
          b.tags["time"] <=> a.tags["time"]
        end
      end

      # We need to find the most recent backup time that all snapshots have in common.
      most_recent_date = get_most_recent_common_snapshot_time(snapshot_buckets)

      @log.info "Most recent snapshot: #{most_recent_date}"

      # Find snapshots for the specified date
      snapshot_mapping = { }
      AWS.memoize do
        snapshot_buckets.keys.each do |index|
          found = false
          snapshot_buckets[index].each do |snapshot|
            if snapshot.tags["time"] == most_recent_date
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

    # Retrieves the most recent snapshot from a specific host that also has
    # tag called "purpose" with the specified value.
    #
    # @param [String] clone_host FQDN name of server with the volume to clone.
    # @param [String] purpose Value of the purpose tag.
    #
    # @return [AWS::EC2::Snapshot, nil] matching snapshot or nil if no matching snapshot
    #
    public
    def get_latest_snapshot_by_purpose(clone_host, purpose)
      @log.info "Retrieving snapshtos for #{clone_host} [#{purpose}]"
      results = @ec2.snapshots.tagged("host").tagged_values(clone_host).tagged("purpose").tagged_values(purpose)
      
      snapshot = nil
      results.each do |s|
        next unless s.status == :completed
        snapshot = s if snapshot.nil? || snapshot.start_time < s.start_time
      end
      snapshot
    end
  end
end