require 'hive'
require 'hive/port_allocator'

module Hive
  # The generic device class
  class Device
    attr_reader :type
    attr_accessor :status
    attr_accessor :port_allocator

    # Initialise the device
    def initialize(options)
      @worker_pid = nil
      @options = options
      (@port_allocator = options['port_allocator']) || Hive::PortAllocator.new(ports: [])
      @status = @options.key?('status') ? @options['status'] : 'none'
      @worker_class = self.class.to_s.sub('Device', 'Worker')
      require @worker_class.downcase.gsub(/::/, '/')
      raise ArgumentError, "Identity not set for #{self.class} device" unless @identity
    end

    # Start the worker process
    def start
      parent_pid = Process.pid
      @worker_pid = Process.fork do
        object = Object
        @worker_class.split('::').each { |sub| object = object.const_get(sub) }
        object.new(@options.merge('parent_pid' => parent_pid, 'device_identity' => identity, 'port_allocator' => port_allocator, 'hive_id' => Hive.hive_mind.device_details['id']))
      end
      Process.detach @worker_pid

      Hive.logger.info("Worker started with pid #{@worker_pid}")
    end

    # Terminate the worker process
    def stop
      protect_file = File.expand_path("#{@worker_pid}.protect", PIDS_DIRECTORY)
      Hive.logger.debug("Checking for protected file: #{protect_file}")
      if File.exist? File.expand_path("#{@worker_pid}.protect", PIDS_DIRECTORY)
        Hive.logger.debug("PID #{@worker_pid} is protected")
        false
      else
        @stop_count = @stop_count.nil? ? 0 : @stop_count + 1

        if running?
          if @stop_count < 30
            Hive.logger.info("Attempting to terminate process #{@worker_pid} [#{@stop_count}]")
            Process.kill 'TERM', @worker_pid
          else
            Hive.logger.info("Killing process #{@worker_pid}")
            Process.kill 'KILL', @worker_pid if running?
          end
        end

        if running?
          false
        else
          @worker_pid = nil
          @stop_count = nil
          true
        end
      end
    end

    # Test the state of the worker process
    def running?
      if @worker_pid
        begin
          Process.kill 0, @worker_pid
          true
        rescue Errno::ESRCH
          false
        end
      else
        false
      end
    end

    # Return the worker pid, checking to see if it is running first
    def worker_pid
      @worker_pid = nil unless running?
      @worker_pid
    end

    # Return true if the device is claimed
    # If the device has no status set it is assumed not to be claimed
    def claimed?
      @status == 'claimed'
    end

    # Test equality with another device
    def ==(other)
      identity == other.identity
    end

    # Return the unique identity of the device
    def identity
      "#{self.class.to_s.split('::').last}-#{@identity}"
    end
  end
end
