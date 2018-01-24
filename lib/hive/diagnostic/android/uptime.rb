# frozen_string_literal: true

require 'hive/diagnostic'
module Hive
  class Diagnostic
    class Android
      class Uptime < Diagnostic
        def diagnose(data = {})
          if config.key?(:reboot_timeout)
            uptime = device_api.uptime
            if uptime < config[:reboot_timeout]
              data[:next_reboot_in] = { value: (config[:reboot_timeout] - uptime).to_s, unit: 's' }
              pass("Time for next reboot: #{config[:reboot_timeout] - uptime}s", data)
            else
              raise('Reboot required', data)
            end
          else
            data[:reboot] = { value: "Not configured for reboot. Set in config {:reboot_timeout => '2400'}" }
            pass('Not configured for reboot', data)
          end
        end

        def repair(_result)
          data = {}
          Hive.logger.info('Rebooting the device')
          begin
            data[:last_rebooted] = { value: Time.now }
            pass('Reboot', data)
            device_api.reboot
          rescue StandardError
            Hive.logger.error('Device not found')
          end
          diagnose(data)
        end
      end
    end
  end
end
