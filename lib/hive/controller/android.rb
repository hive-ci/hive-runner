# frozen_string_literal: true

require 'hive/controller'
require 'hive/worker/android'
require 'device_api/android'

module Hive
  class Controller
    class Android < Controller
      def initialize(options)
        @remote = false if @remote.nil?
        super(options)
      end

      # Register and poll connected devices
      def detect
        if Hive.hive_mind.device_details.key? :error
          detect_without_hivemind
        else
          detect_with_hivemind
        end
      end

      def detect_with_hivemind
        connected_devices = get_connected_devices
        Hive.logger.debug('No devices attached') if connected_devices.empty?

        # Selecting only android mobiles
        hivemind_devices = get_hivemind_devices

        to_poll = []
        attached_devices = []
        hivemind_devices.each do |device|
          Hive.logger.debug("Device details: #{device.inspect}")
          begin
            registered_device = connected_devices.select { |a| a.serial == device['serial'] }
          rescue StandardError => e
            registered_device = []
          end
          if registered_device.empty?
            # A previously registered device isn't attached
            Hive.logger.debug("A previously registered device has disappeared: #{device}")
          else
            # A previously registered device is attached, poll it

            Hive.logger.debug("Setting #{device['name']} to be polled")
            Hive.logger.debug("Device: #{registered_device.inspect}")
            begin
              Hive.logger.debug("#{device['name']} OS version: #{registered_device[0].version}")
              # Check OS version and update if necessary
              if device['operating_system_version'] != registered_device[0].version
                Hive.logger.info("Updating OS version of #{device['name']} from #{device['operating_system_version']} to #{registered_device[0].version}")
                Hive.hive_mind.register(
                  id: device['id'],
                  operating_system_name: 'android',
                  operating_system_version: registered_device[0].version
                )
              end

              attached_devices << create_device(device.merge('os_version' => registered_device[0].version))
              to_poll << device['id']
            rescue DeviceAPI::DeviceNotFound => e
              Hive.logger.warn("Device disconnected before registration (serial: #{device['serial']})")
            rescue StandardError => e
              Hive.logger.warn("Error with connected device: #{e.message}")
            end

            connected_devices -= registered_device
          end
        end

        # Poll already registered devices
        Hive.logger.debug("Polling: #{to_poll}")
        Hive.hive_mind.poll(*to_poll)

        # Register new devices
        unless connected_devices.empty?
          begin
            get_devices(connected_devices).each do |device|
              begin
                dev = Hive.hive_mind.register(
                  hostname: device.model,
                  serial: device.serial,
                  macs: [device.wifi_mac_address],
                  ips: [device.ip_address],
                  brand: device.manufacturer.capitalize,
                  model: device.model,
                  device_type: device.type.to_s.capitalize,
                  plugin_type: 'Mobile',
                  imei: device.imei,
                  operating_system_name: 'android',
                  operating_system_version: device.version
                )
                Hive.hive_mind.connect(dev['id'])
                Hive.logger.info("Device registered: #{dev}")
              rescue DeviceAPI::DeviceNotFound => e
                Hive.logger.warn("Device disconnected before registration #{e.message}")
              rescue StandardError => e
                Hive.logger.warn("Error with connected device: #{e.message}")
              end
            end
          rescue StandardError => e
            Hive.logger.debug("Connected Devices: #{connected_devices}")
            Hive.logger.warn(e)
          end
        end
        Hive.logger.info(attached_devices)
        attached_devices
      end

      def detect_without_hivemind
        connected_devices = get_connected_devices
        attached_devices = []
        Hive.logger.debug('No devices attached') if connected_devices.empty?

        Hive.logger.info('No Hive Mind connection')
        Hive.logger.debug("Error: #{Hive.hive_mind.device_details[:error]}")
        # Hive Mind isn't available, use DeviceAPI instead
        begin
          device_info = connected_devices.map do |device|
            {
              'id'         => device.serial,
              'serial'     => device.serial,
              'qualifier'  => device.qualifier,
              'status'     => 'idle',
              'model'      => device.model,
              'brand'      => device.manufacturer,
              'os_version' => device.version
            }
          end

          attached_devices = device_info.collect do |physical_device|
            create_device(physical_device)
          end
        rescue DeviceAPI::DeviceNotFound => e
          Hive.logger.warn("Device disconnected while fetching device_info #{e.message}")
        rescue StandardError => e
          Hive.logger.warn(e)
        end

        Hive.logger.info(attached_devices)
        attached_devices
      end

      def get_connected_devices
        states = %i[unauthorized no_permissions unknown offline]

        DeviceAPI::Android.devices
                          .reject { |device| states.include?(device.status) }
                          .select { |e| e.is_remote? == @remote }
      rescue DeviceAPI::DeviceNotFound => e
        Hive.logger.info("Device disconnected while getting list of devices \n #{e}")
      rescue StandardError => e
        Hive.logger.warn("Device has got some issue. Exception => #{e}. Debug and connect device manually")
      end

      def get_hivemind_devices
        Hive.hive_mind.device_details['connected_devices'].select do |device|
          device['operating_system_name'].casecmp('android').zero?
        end
      rescue NoMethodError
        # Failed to find connected devices
        raise Hive::Controller::DeviceDetectionFailed
      end

      def get_devices(connected_devices)
        states = %i[unauthorized no_permissions unknown offline]

        connected_devices.reject do |device|
          states.include?(device.status)
        end
      end

      def display_devices(hive_details)
        rows = []
        if hive_details.key?('devices')
          unless hive_details['devices'].empty?
            rows = hive_details['devices'].map do |device|
              [
                "#{device['device_brand']} #{device['device_model']}",
                device['serial'],
                (device['device_queues'].map { |queue| queue['name'] }).join("\n"),
                device['status']
              ]
            end
          end
        end
        table = Terminal::Table.new headings: ['Device', 'Serial', 'Queue Name', 'Status'], rows: rows

        Hive.logger.info(table)
      end
    end
  end
end
