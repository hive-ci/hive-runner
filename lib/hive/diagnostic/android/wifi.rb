# frozen_string_literal: true

require 'hive/diagnostic'
module Hive
  class Diagnostic
    class Android
      class Wifi < Diagnostic
        def wifi
          wifi_details = device_api.wifi_status
          { status: wifi_details[:status].scan(/^[^\/]*/)[0], access_point: wifi_details[:access_point] }
        end

        def diagnose
          result = 'pass'
          wifi_status = wifi
          data = {}
          data[:access_point] = { value: (wifi_status[:"#{key}"]).to_s }

          if wifi_status[:access_point].capitalize == 'Xxxx'
            result = pass("Kindle returns wifi 'xxxx'", data)
            return result
          end

          config.each do |key, value|
            result = 'fail' if wifi_status[:"#{key}"].capitalize != value.capitalize
          end

          if result == 'pass'
            pass("#{key.capitalize} : #{wifi_status[:"#{key}"]}", data)
          else
            raise("#{key.capitalize} : #{wifi_status[:"#{key}"]}", data)
          end
        end

        def repair(_result)
          Hive.logger.info('Start wifi setting and select first access point')
          begin
            device_api.intent('start -a android.intent.action.MAIN -n com.android.settings/.wifi.WifiSettings')
            # Select first access point available in list
            system("adb -s #{@serial} shell input keyevent 20")
            system("adb -s #{@serial} shell input keyevent 23")
            # Press home button
            system("adb -s #{@serial} shell input keyevent 3")
          rescue StandardError
            Hive.logger.error('Unable to resolve wifi issue')
          end
          diagnose
        end
      end
    end
  end
end
