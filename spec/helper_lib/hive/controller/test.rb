require 'hive/controller'

module Hive
  class Controller
    # Dummy test controller
    class Test < Controller
      attr_accessor :detect_success
      attr_accessor :maximum

      def initialize(config)
        @detect_success = true
        @maximum        = 5
        super
      end

      def detect
        raise Hive::Controller::DeviceDetectionFailed unless @detect_success
        (1..@maximum).collect do |i|
          Object.const_get(@device_class).new(@config.merge('id' => i))
        end
      end
    end
  end
end
