#
# Copyright (c) 2012 Sean Laurent
#
require 'rubygems'
require 'aws-sdk'
require 'log4r'

include Log4r

module EC2Launcher
  class Route53Record
    attr_reader :name, :type, :ttl, :value
    def initialize(name, type, ttl, value)
      @name = name
      @type = type
      @ttl = ttl
      @value = value
    end
  end

  class Route53
    # @param [AWS::Route53] route53 Initialized Route53 object
    # @param [String] hosted_zone_id Zone ID
    # @param [Log4r::Logger]
    def initialize(route53, hosted_zone_id, logger = nil)
      @log = logger

      @route53 = route53
      @hosted_zone_id = hosted_zone_id
    end

    # Creates a new DNS record in Route53. Deletes any existing record with the
    # same name and record type.
    #
    # @param [String] name  Name of the record
    # @param [String] value Value for the DNS record
    # @param [String] type  Type of DNS record: A, CNAME, etc. Defaults to 'A'.
    # @param [Integer] ttl  TTL in seconds. Defaults to 300.
    def create_record(name, value, type = "A", ttl = 300)
      # Delete existing record because you can't update records
      delete_record_by_name(name, type, false)

      # Create new record
      begin
        @route53.client.change_resource_record_sets({
          :hosted_zone_id => @hosted_zone_id, 
          :change_batch => {
            :changes => [ 
              {
                :action => "CREATE", 
                :resource_record_set => { 
                  :name => name, 
                  :type => type,
                  :ttl => ttl, 
                  :resource_records => [ { :value => value } ]
                }
              }
            ]
          }
        })
      rescue StandardError => bang
        @log.error "Error creating A record from Route53: #{bang}"
      end
    end

    # Deletes a record by hostname, if it exists.
    #
    # @param [String] hostname Name of the record
    # @param [String] record_type Type of DNS record: A, CNAME, etc.
    # @param [Boolean] log_errors Log errors or not. False quietly ignores errors.
    #
    def delete_record_by_name(hostname, record_type = "A", log_errors = true)
      # Search for the record
      delete_result = true
      record = find_record(hostname, record_type)
      if record
        delete_record(record.name, record.type, record.ttl, record.value, log_errors)
      else
        delete_result = false
        @log.warn "Route53 '#{record_type}' record for '#{hostname}' not found!" if log_errors
      end
      delete_result
    end

    # Deletes a DNS record from Route53.
    #
    # @param [String] name  Name of the record
    # @param [String] type  Type of DNS record: A, CNAME, etc.
    # @param [Integer] ttl  TTL in seconds
    # @param [String] value Value for the DNS record
    # @param [Boolean] log_errors Log errors or not. False quietly ignores errors.
    #
    def delete_record(name, type, ttl, value, log_errors = true)
      delete_result = true
      begin
        @route53.client.change_resource_record_sets({
          :hosted_zone_id => @hosted_zone_id, 
          :change_batch => {
            :changes => [ 
              {
                :action => "DELETE", 
                :resource_record_set => { 
                  :name => name, 
                  :type => type,
                  :ttl => ttl, 
                  :resource_records => [ { :value => value } ]
                }
              }
            ]
          }
        })
      rescue StandardError => bang
        @log.error "Error deleting A record from Route53: #{bang}" if log_errors
        delete_result = false
      end
      delete_result
    end

    # Searches for a record with the specified name and type.
    #
    # @param [String] name  Name of the record
    # @param [String] type  Type of DNS record: A, CNAME, etc.
    #
    # @return [EC2Launcher::Route53Record] Wrapper containing all the
    # required information about a Route53 entry or nil if not found.
    def find_record(name, type = 'A')
      # Find the record
      response = @route53.client.list_resource_record_sets({
        :hosted_zone_id => @hosted_zone_id,
        :start_record_name => name,
        :start_record_type => type,
        :max_items => 1
      })

      record = nil
      if response && response.data
        if response.data[:resource_record_sets] && response.data[:resource_record_sets].size > 0
          response_record = response.data[:resource_record_sets][0]
          if (response_record[:name] == name || response_record[:name] == "#{name}.") && response_record[:type] == type
            record = Route53Record.new(response_record[:name], response_record[:type], response_record[:ttl], response_record[:resource_records][0][:value])
          end
        end
      end

      record
    end
  end
end