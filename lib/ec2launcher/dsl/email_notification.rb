#
# Copyright (c) 2012 Sean Laurent
#

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
      def initialize()
      end

      def from(*from)
        if from.empty?
          @from
        else
          @from = from[0]
          self
        end
      end

      def to(*to)
        if to.empty?
          @to
        else
          @to = to[0]
          self
        end
      end

      def ses_access_key(*ses_access_key)
        if ses_access_key.empty?
          @ses_access_key
        else
          @ses_access_key = ses_access_key[0]
          self
        end
      end

      def ses_secret_key(*ses_secret_key)
        if ses_secret_key.empty?
          @ses_secret_key
        else
          @ses_secret_key = ses_secret_key[0]
          self
        end
      end

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