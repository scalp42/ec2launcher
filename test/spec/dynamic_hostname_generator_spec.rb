require_relative "../test_helper"
require 'ec2launcher/dynamic_hostname_generator'

describe "DynamicHostnameGenerator", "Dynamic host name generation" do
  it "creates valid hostname without prefix or suffix" do
    generator = EC2Launcher::DynamicHostnameGenerator.new
    generator.generate_dynamic_hostname("i-abcdefgh").must_equal "abcdefgh"
  end

  it "creates valid hostname with a simple suffix and no prefix" do
    generator = EC2Launcher::DynamicHostnameGenerator.new(nil, "example.com")
    generator.generate_dynamic_hostname("i-abcdefgh").must_equal "abcdefgh.example.com"
  end

  it "creates valid hostname with a simple prefix with no suffix" do
    generator = EC2Launcher::DynamicHostnameGenerator.new("prefix-")
    generator.generate_dynamic_hostname("i-abcdefgh").must_equal "prefix-abcdefgh"
  end

  it "creates valid hostname with both a prefix and suffix" do
    generator = EC2Launcher::DynamicHostnameGenerator.new("prefix-", "example.com")
    generator.generate_dynamic_hostname("i-abcdefgh").must_equal "prefix-abcdefgh.example.com"
  end

  it "creates valid hostname when the suffix starts with a period" do
    generator = EC2Launcher::DynamicHostnameGenerator.new(nil, ".example.com")
    generator.generate_dynamic_hostname("i-abcdefgh").must_equal "abcdefgh.example.com"
  end
end