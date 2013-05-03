require "minitest/autorun"
require 'ec2launcher/hostnames/host_name_generation'

class HostNameGenerationSpecTest
  include EC2Launcher::HostNames::HostNameGeneration
end

describe "HostNameGeneration" do
  let (:generator) { HostNameGenerationSpecTest.new }

  it "gives a valid short name given a long name and domain" do
    generator.generate_short_name("host.example.com", "example.com").must_equal "host"
  end

  it "gives a valid short name given a long name and no domain" do
    generator.generate_short_name("host.example.com", nil).must_equal "host.example.com"
  end

  it "gives a valid short name given a long name and a domain that starts with a period" do
    generator.generate_short_name("host.example.com", ".example.com").must_equal "host"
  end

  it "gives a valid FQDN given a short name and a domain" do
    generator.generate_fqdn("host", "example.com").must_equal "host.example.com"
  end

  it "gives a valid FQDN given a short name and a domain that starts with a period" do
    generator.generate_fqdn("host", ".example.com").must_equal "host.example.com"
  end

  it "gives a valid FQDN with a short name and no domain" do
    generator.generate_fqdn("host", nil).must_equal "host"
  end

  it "throws an exception when generating a FQDN without a short name" do
    assert_raises(ArgumentError) { generator.generate_fqdn(nil, nil) }
  end

  it "throws an exception when generating a short name without a long name" do
    assert_raises(ArgumentError) { generator.generate_short_name(nil, nil) }
  end
end