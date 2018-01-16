require 'hive/messages'

module Hive
  module Messages
    class IosJob < Hive::Messages::Job
      def build
        target.symbolize_keys[:build]
      end

      def resign
        target.symbolize_keys[:resign].to_i != 0
      end
    end
  end
end
