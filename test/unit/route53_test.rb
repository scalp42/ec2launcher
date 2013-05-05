require_relative "../test_helper"
require 'minitest/mock'
require 'ec2launcher/route53'

require 'ostruct'

class Route53Test < MiniTest::Unit::TestCase
  def generate_route53_record_set(name, type, ttl, value)
    route53_result = OpenStruct.new
    route53_result.data = {
      :resource_record_sets => [
        {
          :name => name,
          :type => type,
          :ttl => ttl,
          :resource_records => [
            {
              :value => value
            }
          ]
        }
      ]
    }
    route53_result
  end

  def test_find_record()
    mock_route53 = MiniTest::Mock.new
    mock_client = MiniTest::Mock.new

    route53_query = {
      :hosted_zone_id => 'ABCDEFGH',
      :start_record_name => 'server1.example.com',
      :start_record_type => 'A',
      :max_items => 1
    }

    route53_result = generate_route53_record_set('server1.example.com', 'A', 3600, '10.0.0.1')

    # mock expects:
    #                   method        return       arguments
    #-------------------------------------------------------------
    mock_route53.expect(:client,      mock_client,    [])
    mock_client.expect(:list_resource_record_sets, route53_result, [route53_query])

    route53 = EC2Launcher::Route53.new(mock_route53, 'ABCDEFGH')
    record = route53.find_record('server1.example.com', 'A')
    
    refute_nil record

    assert_equal "server1.example.com", record.name
    assert_equal 3600, record.ttl
    assert_equal "10.0.0.1", record.value
    assert_equal "A", record.type
  end
end