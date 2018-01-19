# frozen_string_literal: true

require 'hive/diagnostic'
module Hive
  class Diagnostic
    class Android
      class Battery < Diagnostic
        def battery
          device_api.battery_info
        end

        def units
          {
            temperature: 'ºC',
            voltage: 'mV'
          }
        end

        def diagnose
          data = {}
          battery_info = battery
          result = 'pass'
          config.each_key do |c|
            raise InvalidParameterError, "Battery Parameter should be any of #{battery_info.keys}" unless battery_info.key? c
            begin
              battery_info[c] = battery_info[c].to_i / 10 if c == 'temperature'
              data[:"#{c}"] = { value: battery_info[c], unit: units[:"#{c}"] }
              result = 'fail' if battery_info[c].to_i > config[c].to_i
            rescue StandardError => e
              Hive.logger.error "Incorrect battery parameter => #{e}"
              return raise("Incorrect parameter #{c} specified. Battery Parameter can be any of #{battery_info.keys}", 'Battery')
            end
          end

          result != 'fail' ? pass('Battery', data) : raise('Battery', data)
        end

        def repair(_result)
          raise('Unplug device from hive')
        end
      end
    end
  end
end
