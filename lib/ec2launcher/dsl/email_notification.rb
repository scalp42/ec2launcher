#
# Copyright (c) 2012 Sean Laurent
#
require 'ec2launcher/dsl/helper'

module EC2Launcher
  module DSL
    module EmailNotifications

      attr_reader :email_notifications

      def email_notification(&block)
        notifications = EC2Launcher::DSL::EmailNotification.new
        notifications.instance_exec(&block)
        @email_notifications = notifications
      end
    end

    class EmailNotification
      dsl_accessor :from
      dsl_accessor :to
      dsl_accessor :ses_access_key
      dsl_accessor :ses_secret_key

      def to_json(*a)
        {
          "from" => @from,
          "to" => @to,
          "ses_access_key" => @ses_access_key,
          "ses_secret_key" => @ses_secret_key
        }.to_json(*a)
      end
    end
  end
end