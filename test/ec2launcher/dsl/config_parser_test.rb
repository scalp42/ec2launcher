require_relative "../../test_helper"

class ConfigParserTest < MiniTest::Unit::TestCase
  def test_full_config_parses_correctly
    sample_config_erb = %q{
config do
  environments "environments"
  applications "applications"

  package_manager "yum"
  config_manager "chef"
end
}.gsub(/^ /, '')
  
    config_dsl = EC2Launcher::DSL::ConfigDSL.execute(sample_config_erb)
    refute config_dsl.nil?
    refute config_dsl.config.nil?

    config = config_dsl.config
    assert_equal "yum", config.package_manager
    assert_equal "chef", config.config_manager

    assert_kind_of Array, config.applications
    assert_kind_of Array, config.environments

    assert_equal "applications", config.applications[0]
    assert_equal "environments", config.environments[0]
  end

  def test_empty_config_parses_correctly
    sample_config_erb = %q{
config do
end
}.gsub(/^ /, '')
    config_dsl = EC2Launcher::DSL::ConfigDSL.execute(sample_config_erb)
    refute config_dsl.nil?
    refute config_dsl.config.nil?
  end
end