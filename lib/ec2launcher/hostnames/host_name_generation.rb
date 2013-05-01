#
# Copyright (c) 2012-2013 Sean Laurent
#
module EC2Launcher
  module HostNames
    module HostNameGeneration
      # Given a short host name and domain name, generate a Fully Qualified Domain Name.
      #
      # @param [String] short_hostname  Shortened host name.
      # @param [String] domain_name     Optional domain name ie 'example.com'
      def generate_fqdn(short_hostname, domain_name = nil)
        hostname = short_hostname
        unless domain_name.nil?
          hostname += ".#{domain_name}"
        end

        hostname
      end

      # Given a FQDN and a domain name, produce a shortened version of the host name
      # without the domain.
      #
      # @param [String] long_name   FQDN ie 'foo1.prod.example.com'
      # @param [String] domain_name Optional domain name ie 'example.com'
      def generate_short_name(long_name, domain_name = nil)
        short_hostname = long_name
        unless domain_name.nil?
          short_hostname = long_name.gsub(/.#{domain_name}/, '')
        end
        short_hostname
      end
    end
  end
end
