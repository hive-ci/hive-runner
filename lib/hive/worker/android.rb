# frozen_string_literal: true

require 'hive/worker'
require 'hive/messages/android_job'

module Hive
  class PortReserver
    attr_accessor :ports
    def initialize
      self.ports = {}
    end

    def reserve(queue_name)
      ports[queue_name] = yield
      ports[queue_name]
    end
  end

  class Worker
    class Android < Worker
      attr_accessor :device

      def initialize(device)
        @serial         = device['serial']
        @qualifier    ||= device['serial']
        @queue_prefix   = device['queue_prefix'].to_s == '' ? '' : "#{device['queue_prefix']}-"
        @model          = device['model'].downcase.gsub(/\s/, '_')
        @brand          = device['brand'].downcase.gsub(/\s/, '_')
        @os_version     = device['os_version']
        @worker_ports   = PortReserver.new

        @hive_name                = ENV['HIVE_NAME'].to_s
        @device_location          = ENV['HIVE_LOCATION'].to_s
        @device_building_location = ENV['HIVE_BUILDING_LOCATION'].to_s

        begin
          device.merge!('device_api' => DeviceAPI::Android.device(@qualifier))
        rescue DeviceAPI::DeviceNotFound
          Hive.logger.info("Device '#{@qualifier}' disconnected during initialization")
        rescue DeviceAPI::UnauthorizedDevice
          Hive.logger.info("Device '#{@qualifier}' is unauthorized")
        rescue DeviceAPI::Android::ADBCommandError
          Hive.logger.info('Device disconnected during worker initialization')
        rescue StandardError => e
          Hive.logger.warn("Error with connected device: #{e.message}")
        end
        set_device_status('happy')
        self.device = device
        super(device)
      end

      def adb_port
        # Assign adb port for this worker
        return @adb_port unless @adb_port.nil?
        @adb_port = @port_allocator.allocate_port
      end

      def pre_script(job, file_system, script)
        set_device_status('busy')
        script.set_env 'TEST_SERVER_PORT',    adb_port

        # TODO: Allow the scheduler to specify the ports to use
        script.set_env 'CHARLES_PROXY_PORT',  @worker_ports.reserve(queue_name: 'Charles') { @port_allocator.allocate_port }
        script.set_env 'APPIUM_PORT',         @worker_ports.reserve(queue_name: 'Appium') { @port_allocator.allocate_port }
        script.set_env 'BOOTSTRAP_PORT',      @worker_ports.reserve(queue_name: 'Bootstrap') { @port_allocator.allocate_port }
        script.set_env 'CHROMEDRIVER_PORT',   @worker_ports.reserve(queue_name: 'Chromedriver') { @port_allocator.allocate_port }

        script.set_env 'ADB_DEVICE_ARG', @qualifier

        FileUtils.mkdir(file_system.home_path + '/build')
        apk_path = file_system.home_path + '/build/' + 'build.apk'

        script.set_env 'APK_PATH', apk_path
        if job.build
          @log.debug('Fetching build')
          file_system.fetch_build(job.build, apk_path)
          @log.debug("Re-signing APK: #{job.resign}")
          if job.resign
            DeviceAPI::Android::Signing.sign_apk(apk: apk_path, resign: true)
            @log.debug('Signing done')
          end
        end

        DeviceAPI::Android.device(@qualifier).unlock

        "#{@qualifier} #{@worker_ports.ports['Appium']} #{apk_path} #{file_system.results_path}"
      end

      def job_message_klass
        Hive::Messages::AndroidJob
      end

      def post_script(_job, _file_system, _script)
        @log.info('Post script')
        @worker_ports.ports.each do |_name, port|
          @port_allocator.release_port(port)
        end
        set_device_status('happy')
      end

      # def device_status
      #  # TODO Get from Hive Mind
      # end

      # def set_device_status(status)
      #  # TODO Report to Hive Mind
      # end

      def autogenerated_queues
        @log.info('Autogenerating queues')
        [
          @device_location,
          @device_building_location,
          @queue_prefix,
          @model,
          @brand,
          'android',
          "android-#{@os_version}",
          "android-#{@os_version}-#{@model}"
        ].map! { |element| element.to_s.downcase.tr(' ', '_').delete('"') }.reject(&:empty?)
      end

      def hive_mind_device_identifiers
        {
          serial: @serial,
          device_type: 'Mobile'
        }
      end
    end
  end
end
