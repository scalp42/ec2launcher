require_relative "../test_helper"
require 'minitest/mock'
require 'ec2launcher/route53'

require 'ostruct'

class Route53Test < MiniTest::Unit::TestCase

  def setup()
    @default_hosted_zone_id = "ABCDEFGH"
    @default_record_name = "server1.example.com"
    @default_record_type = "A"
    @default_record_ttl = 3600
    @default_record_value = "10.0.0.1"
  end    

  def create_route53_with_mock_client(client)
    route53 = OpenStruct.new
    route53.client = client
    route53
  end

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

  def generate_route53_change_request(action, zone_id, name, type, ttl, value)
    {
      :hosted_zone_id => zone_id, 
      :change_batch => {
        :changes => [ 
          {
            :action => action, 
            :resource_record_set => { 
              :name => name, 
              :type => type,
              :ttl => ttl, 
              :resource_records => [ { :value => value } ]
            }
          }
        ]
      }
    }
  end

  def generate_route53_query(zone_id = nil, name = nil, type = nil)
    zone_id ||= @default_hosted_zone_id
    name ||= @default_record_name
    type ||= @default_record_type

    {
      :hosted_zone_id => zone_id,
      :start_record_name => name,
      :start_record_type => type,
      :max_items => 1
    }
  end

  def test_find_record()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    route53_query = generate_route53_query()
    route53_result = generate_route53_record_set(@default_record_name, @default_record_type, @default_record_ttl, @default_record_value)

    # mock expects:
    #                   method                      return       arguments
    #-------------------------------------------------------------
    mock_client.expect(:list_resource_record_sets, route53_result, [route53_query])

    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)
    record = route53.find_record(@default_record_name, @default_record_type)
    
    assert mock_client.verify

    refute_nil record

    assert_equal @default_record_name, record.name
    assert_equal @default_record_ttl, record.ttl
    assert_equal @default_record_value, record.value
    assert_equal @default_record_type, record.type
  end

  def test_delete_record()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    change_request = generate_route53_change_request("DELETE", @default_hosted_zone_id, @default_record_name, @default_record_type, @default_record_ttl, @default_record_value)

    mock_client.expect(:change_resource_record_sets, nil, [change_request])
  
    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)

    delete_result = route53.delete_record(@default_record_name, @default_record_type, @default_record_ttl, @default_record_value, false)

    assert mock_client.verify

    assert delete_result
  end

  def test_delete_record_by_name()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    route53_query = generate_route53_query()
    route53_result = generate_route53_record_set(@default_record_name, @default_record_type, @default_record_ttl, @default_record_value)
    change_request = generate_route53_change_request("DELETE", @default_hosted_zone_id, @default_record_name, @default_record_type, @default_record_ttl, @default_record_value)

    mock_client.expect(:list_resource_record_sets, route53_result, [route53_query])
    mock_client.expect(:change_resource_record_sets, nil, [change_request])

    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)
    delete_result = route53.delete_record_by_name(@default_record_name, @default_record_type, false)

    assert mock_client.verify

    assert delete_result
  end

  def test_delete_record_by_name_does_not_exist()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    route53_query = generate_route53_query()

    mock_client.expect(:list_resource_record_sets, nil, [route53_query])

    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)
    delete_result = route53.delete_record_by_name(@default_record_name, @default_record_type, false)

    assert mock_client.verify
    assert_equal false, delete_result
  end

  def test_creating_new_record()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    route53_query = generate_route53_query()
    update_request = generate_route53_change_request("CREATE", @default_hosted_zone_id, @default_record_name, @default_record_type, @default_record_ttl, @default_record_value)

    mock_client.expect(:list_resource_record_sets, nil, [route53_query])
    mock_client.expect(:change_resource_record_sets, nil, [update_request])

    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)
    route53.create_record(@default_record_name, @default_record_value, @default_record_type, @default_record_ttl)

    assert mock_client.verify
  end

  def test_updating_existing_record()
    mock_client = MiniTest::Mock.new
    mock_route53 = create_route53_with_mock_client(mock_client)

    route53_query = generate_route53_query()
    find_result = generate_route53_record_set(@default_record_name, @default_record_type, @default_record_ttl, @default_record_value)
    delete_request = generate_route53_change_request("DELETE", @default_hosted_zone_id, @default_record_name, @default_record_type, @default_record_ttl, @default_record_value)
    update_request = generate_route53_change_request("CREATE", @default_hosted_zone_id, @default_record_name, @default_record_type, @default_record_ttl, "10.0.1.1")

    mock_client.expect(:list_resource_record_sets, find_result, [route53_query])
    mock_client.expect(:change_resource_record_sets, nil, [delete_request])
    mock_client.expect(:change_resource_record_sets, nil, [update_request])

    route53 = EC2Launcher::Route53.new(mock_route53, @default_hosted_zone_id)
    route53.create_record(@default_record_name, "10.0.1.1", @default_record_type, @default_record_ttl)

    assert mock_client.verify
  end
end