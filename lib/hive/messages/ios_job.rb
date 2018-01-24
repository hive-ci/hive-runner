# frozen_string_literal: true

require 'hive/messages'

module Hive
  module Messages
    class IOSJob < Hive::Messages::Job
      def build
        target.symbolize_keys[:build]
      end

      def resign
        target.symbolize_keys[:resign].to_i != 0
      end
    end
  end
end
