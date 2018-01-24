# frozen_string_literal: true

require 'hive'
require 'hive/port_allocator'

module Hive
  # Central register of devices and workers in the hive
  class Register
    attr_reader :controllers

    def initialize
      @controllers    = []
      @devices        = {}
      @max_devices    = 5 # TODO: Add to configuration file
      @port_allocator = if Hive.config.ports?
                          Hive::PortAllocator.new(
                            minimum: Hive.config.ports.minimum,
                            maximum: Hive.config.ports.maximum
                          )
                        else
                          Hive::PortAllocator.new(ports: [])
                        end
    end

    def devices
      list = []
      @devices.each_value { |device_list| list.concat(device_list) }
      list
    end

    def worker_pids
      devices.collect(&:worker_pid).compact
    end

    def instantiate_controllers(controller_details = Hive.config.controllers)
      controller_details&.each do |type, opts|
        Hive.logger.info("Adding controller for '#{type}'")
        require "hive/controller/#{type}"
        controller = Object.const_get('Hive').const_get('Controller').const_get(type.capitalize).new(opts.to_hash)
        @controllers << controller
      end
      check_controllers
      @controllers
    end

    def run
      @next_stat_update = Time.now
      loop do
        Hive.poll
        housekeeping
        check_controllers
        sleep Hive.config.timings.controller_loop_interval

        # For the moment, clear Hive Mind logs each time
        # TODO Something better so that warnings and errors are not hidden
        Hive.logger.clear(component: Hive.logger.default_progname, level: Hive.config.logging.hm_logs_to_delete)
        Hive.logger.debug('Hive Mind log cleared')
      end
    end

    def check_controllers
      Hive.logger.debug("Devices before update: #{@devices.inspect}")
      new_device_list = {}
      @controllers.each do |c|
        begin
          new_device_list[c.class] = []
          @devices[c.class] = [] unless @devices.key?(c.class)
          Hive.logger.info("Checking controller #{c.class}")
          c.detect.each do |device|
            Hive.logger.debug("Found #{device.inspect}")
            i = @devices[c.class].find_index(device)
            if i
              @devices[c.class][i].status = device.status
              new_device_list[c.class] << @devices[c.class][i]
            else
              device.port_allocator = @port_allocator.allocate_port_range(c.port_range_size)
              new_device_list[c.class] << device
            end
          end
          Hive.logger.debug("new_device_list: #{new_device_list.inspect}")

          # Remove any devices that have not been rediscovered
          (@devices[c.class] - new_device_list[c.class]).each do |d|
            if d.stop
              @port_allocator.release_port_range(d.port_allocator)
              @devices[c.class].delete(d)
            end
          end

          # Add any new devices
          (new_device_list[c.class] - @devices[c.class]).each do |d|
            @devices[c.class] << d
          end
          # Check that all known devices have running workers
          @devices[c.class].each do |d|
            if d.claimed?
              d.stop if d.running?
            else
              d.start unless d.running?
            end
          end
        rescue Hive::Controller::DeviceDetectionFailed
          Hive.logger.warn("Failed to detect devices for #{c.class}")
        end
      end
      Hive.logger.debug("Devices after update: #{@devices.inspect}")
    end

    def housekeeping
      clear_workspaces

      return unless Hive.config.timings.stats_update_interval? && @next_stat_update < Time.now
      Hive.send_statistics
      @next_stat_update += Hive.config.timings.stats_update_interval
    end

    def clear_workspaces
      candidates = Dir.glob("#{Hive.config.logging.home}/*")
                      .select do |f|
                     File.directory?(f) \
                     && File.exist?("#{f}/job_info") \
                     && File.read("#{f}/job_info").chomp.to_s =~ /completed/
                   end.sort_by do |f|
        File.mtime(f)
      end.reverse

      return unless candidates && candidates.length > Hive.config.logging.homes_to_keep
      candidates[Hive.config.logging.homes_to_keep..-1].each do |dir|
        Hive.logger.info("Found (and deleting) #{dir}")
        FileUtils.rm_rf(dir)
      end
    end
  end
end
