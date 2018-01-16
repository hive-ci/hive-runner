require 'hive/diagnostic'
require 'device_api/ios/idevice'

module Hive
  class Diagnostic
    class Ios
      class Uptime < Diagnostic
        def diagnose(data = {})
          pass('Not configured for reboot', data) unless config.key?(:reboot_timeout)
          raise('No recorded last boot. Rebooting.', data) unless @last_boot_time
          # DeviceAPI iOS doesn't currently supply uptime.
          uptime = (Time.now - @last_boot_time).to_i
          raise('Reboot required', data) unless uptime < config[:reboot_timeout]

          data[:next_reboot_in] = { value: (config[:reboot_timeout] - uptime).to_s, unit: 's' }
          pass("Time for next reboot: #{config[:reboot_timeout] - uptime}s", data)
        end

        def repair(_result)
          data = {}
          Hive.logger.debug('[iOS]') { "Rebooting #{device_api.serial}" }
          begin
            data[:last_rebooted] = { value: Time.now }
            device_api.reboot
            sleep 10
            returned = false
            60.times do |i|
              sleep 5
              Hive.logger.debug('[iOS]') { "Wait for #{device_api.serial} (#{i})" }
              break if (returned = DeviceAPI::IOS::IDevice.devices.keys.include? device_api.serial)
            end
            # If 'trusted?' is tested too quickly it may(?) break the trust
            # This can probably be reduced or removed completely
            sleep 60
            raise('Failed to reboot', data) unless returned
            trusted = false
            60.times do |i|
              sleep 5
              Hive.logger.debug('[iOS]') { "Wait for #{device_api.serial} to be trusted (#{i})" }
              break if (trusted = device_api.trusted?)
            end

            trusted ? pass('Rebooted', data) : raise('Failed to trust after reboot', data)
          end
          @last_boot_time = Time.now
          rescue => e
            Hive.logger.error('[iOS]') { "Caught exception #{e} while rebooting #{device_api.serial}" }
        end
        diagnose(data)
      end
    end
  end
end
