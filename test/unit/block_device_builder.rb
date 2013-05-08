require_relative "../test_helper"
require 'minitest/mock'
require 'ec2launcher/block_device_builder'
require 'ec2launcher/dsl/block_device'

class BlockDeviceBuilderTest < MiniTest::Unit::TestCase

  def test_building_ephemeral_drives()
    ec2 = MiniTest::Mock.new
    logger = MiniTest::Mock.new

    bdb = BlockDeviceBuilder.new(ec2, nil, logger)

    bd_mapping = {}
    bdb.build_ephemeral_drives(bd_mapping, "m1.large")

    refute_nil bd_mapping

    assert_true bd_mapping["/dev/sdb"]
    assert_true bd_mapping["/dev/sdc"]
    assert_equal "ephemeral0", bd_mapping["/dev/sdb"]
    assert_equal "ephemeral1", bd_mapping["/dev/sdc"]

    bd_mapping = {}
    bdb.build_ephemeral_drives(bd_mapping, "m1.small")

    refute_nil bd_mapping

    assert_true bd_mapping["/dev/sdb"]
    assert_equal "ephemeral0", bd_mapping["/dev/sdb"]

    bd_mapping = {}
    bdb.build_ephemeral_drives(bd_mapping, "t1.micro")

    refute_nil bd_mapping

    assert_equal 0, bd_mapping.keys.size
  end

  def test_basic_ebs_volume_setup()
    ec2 = MiniTest::Mock.new
    logger = MiniTest::Mock.new

    bdb = BlockDeviceBuilder.new(ec2, nil, logger)

    bd_mapping = {}
    block_devices = [ EC2Launcher::DSL::BlockDevice.new({:name => "database"}) ]
    bdb.build_ebs_volumes(bd_mapping, block_devices)

    refute_nil    bd_mapping
    assert_true   bd_mapping["/dev/sdf"]
    assert_equal  60, bd_mapping["/dev/sdf"][:volume_size]
    assert_equal  true, bd_mapping["/dev/sdf"][:delete_on_termination]
    assert_nil    bd_mapping["/dev/sdf"][:iops]

    bd_mapping = {}
    block_devices = [ EC2Launcher::DSL::BlockDevice.new({:name => "database", :size => 120}) ]
    bdb.build_ebs_volumes(bd_mapping, block_devices)

    refute_nil    bd_mapping
    assert_true   bd_mapping["/dev/sdf"]
    assert_equal  120, bd_mapping["/dev/sdf"][:volume_size]
    assert_nil    bd_mapping["/dev/sdf"][:iops]
  end

  def test_ebs_volume_setup_with_multiple_drives()
    ec2 = MiniTest::Mock.new
    logger = MiniTest::Mock.new

    bdb = BlockDeviceBuilder.new(ec2, nil, logger)

    bd_mapping = {}
    block_devices = [ EC2Launcher::DSL::BlockDevice.new({:name => "database", :count => 3}) ]
    bdb.build_ebs_volumes(bd_mapping, block_devices)

    refute_nil    bd_mapping
    assert_true   bd_mapping["/dev/sdf"]
    assert_true   bd_mapping["/dev/sdg"]
    assert_true   bd_mapping["/dev/sdh"]

    assert_nil    bd_mapping["/dev/sdf"][:iops]
    assert_nil    bd_mapping["/dev/sdg"][:iops]
    assert_nil    bd_mapping["/dev/sdh"][:iops]
  end

  def test_ebs_volume_setup_with_piops()
    ec2 = MiniTest::Mock.new
    logger = MiniTest::Mock.new

    bdb = BlockDeviceBuilder.new(ec2, nil, logger)

    bd_mapping = {}
    block_devices = [ EC2Launcher::DSL::BlockDevice.new({:name => "database", :iops => 200}) ]
    bdb.build_ebs_volumes(bd_mapping, block_devices)

    refute_nil    bd_mapping
    assert_true   bd_mapping["/dev/sdf"]

    refute_nil    bd_mapping["/dev/sdf"][:iops]
    assert_equal  200, bd_mapping["/dev/sdf"][:iops]
  end
end