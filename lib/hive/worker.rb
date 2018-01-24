# frozen_string_literal: true

require 'yaml'

require 'hive'
require 'hive/file_system'
require 'hive/execution_script'
require 'hive/diagnostic_runner'
require 'hive/messages'
require 'hive/port_allocator'
require 'code_cache'
require 'res'
require 'fileutils'

module Hive
  # The generic worker class
  class Worker
    class InvalidJobReservationError < StandardError
    end

    class DeviceNotReady < StandardError
    end

    class NoPortsAvailable < StandardError
    end

    # Device API Object for device associated with this worker
    attr_accessor :device_api, :queues

    # The main worker process loop
    def initialize(options)
      @options                = options
      @parent_pid             = @options['parent_pid']
      @device_id              = @options['id']
      @hive_id                = @options['hive_id']
      @default_component    ||= self.class.to_s
      @current_job_start_time = nil

      @hive_mind ||= mind_meld_klass.new(
        url: Chamber.env.network.hive_mind? ? Chamber.env.network.hive_mind : nil,
        pem: Chamber.env.network.cert ? Chamber.env.network.cert : nil,
        ca_file: Chamber.env.network.cafile ? Chamber.env.network.cafile : nil,
        verify_mode: Chamber.env.network.verify_mode ? Chamber.env.network.verify_mode : nil,
        device: hive_mind_device_identifiers
      )

      @device_identity = @options['device_identity'] || 'unknown-device'
      pid = Process.pid
      $PROGRAM_NAME = "#{@options['name_stub'] || 'WORKER'}.#{pid}"
      @log = Hive::Log.new
      @log.add_logger(
        "#{LOG_DIRECTORY}/#{pid}.#{@device_identity}.log",
        Hive.config.logging.worker_level || 'INFO'
      )
      @log.hive_mind        = @hive_mind
      @log.default_progname = @default_component

      update_queues

      @port_allocator = (@options.key?('port_allocator') ? @options['port_allocator'] : Hive::PortAllocator.new(ports: []))

      platform = self.class.to_s.scan(/[^:][^:]*/)[2].downcase
      @diagnostic_runner = Hive::DiagnosticRunner.new(@options, Hive.config.diagnostics, platform, @hive_mind) if Hive.config.diagnostics? && Hive.config.diagnostics[platform]

      Hive::Messages.configure do |config|
        config.base_path       = Hive.config.network.scheduler
        config.pem_file        = Hive.config.network.cert
        config.ssl_verify_mode = OpenSSL::SSL::VERIFY_NONE
      end

      Signal.trap('TERM') do
        @log.info('Worker terminated')
        exit
      end

      @log.info('Starting worker')
      while keep_worker_running?
        begin
          @log.clear(component: @default_component,
                     level: Hive.config.logging.hm_logs_to_delete)
          update_queues
          poll_queue if diagnostics
        rescue DeviceNotReady => e
          @log.warn("#{e.message}\n")
        rescue StandardError => e
          @log.warn("Worker loop aborted: #{e.message}\n  : #{e.backtrace.join("\n  : ")}")
        end
        sleep Hive.config.timings.worker_loop_interval
      end
      @log.info('Exiting worker')
    end

    # Check the queues for work
    def poll_queue
      @job = reserve_job
      if @job.nil?
        @log.info('No job found')
      else
        @log.info('Job starting')
        begin
          @current_job_start_time = Time.now
          execute_job
        rescue StandardError => e
          @log.info("Error running test: #{e.message}\n : #{e.backtrace.join("\n :")}")
        end
        cleanup
      end
    end

    # Try to find and reserve a job
    def reserve_job
      @log.info "Trying to reserve job for queues: #{@queues.join(', ')}"
      job = job_message_klass.reserve(@queues, reservation_details)
      @log.debug "Job: #{job.inspect}"
      raise InvalidJobReservationError, 'Invalid Job Reserved' unless job.nil? || job.valid?
      job
    end

    # Get the correct job class
    # This should usually be replaced in the child class
    def job_message_klass
      @log.info 'Generic job class'
      Hive::Messages::Job
    end

    def mind_meld_klass
      MindMeld::Device
    end

    def reservation_details
      @log.debug "Reservations details: hive_id=#{@hive_id}, worker_pid=#{Process.pid}, device_id=#{@hive_mind.id}"
      { hive_id: @hive_id, worker_pid: Process.pid, device_id: @hive_mind.id }
    end

    # Execute a job
    def execute_job
      # Ensure that a killed worker cleans up correctly
      Signal.trap('TERM') do |_s|
        Signal.trap('TERM') {} # Prevent retry signals
        @log.info 'Caught TERM signal'
        @log.info 'Terminating script, if running'
        @script&.terminate
        @log.info 'Post-execution cleanup'
        signal_safe_post_script(@job, @file_system, @script)

        # Upload results
        @file_system.finalise_results_directory
        upload_files(@job, @file_system.results_path, @file_system.logs_path)
        set_job_state_to :completed
        @job.error('Worker killed')
        @log.info 'Worker terminated'
        exit
      end

      @log.info('Job starting')
      @job.prepare(@hive_mind.id)
      exception = nil
      begin
        @log.info 'Setting job paths'
        @file_system = Hive::FileSystem.new(@job.job_id, Hive.config.logging.home, @log)
        set_job_state_to :preparing

        unless @job.repository.to_s.empty?
          @log.debug "  #{@file_system.testbed_path}"

          env_variables = @job.execution_variables.to_h
          branch = env_variables.key?('git_branch') ? env_variables['git_branch'].to_s : @job.branch

          checkout_code(@job.repository, @file_system.testbed_path, branch)
        end

        @log.info 'Initialising execution script'
        @script = Hive::ExecutionScript.new(
          job: @job,
          file_system: @file_system,
          log: @log,
          keep_running: -> { keep_script_running? }
        )
        @script.append_bash_cmd "mkdir -p #{@file_system.testbed_path}/#{@job.execution_directory}"
        @script.append_bash_cmd "cd #{@file_system.testbed_path}/#{@job.execution_directory}"

        @log.info 'Setting the execution variables in the environment'
        @script.set_env 'HIVE_RESULTS', @file_system.results_path
        @script.set_env 'HIVE_SCRIPT_ERRORS', @file_system.script_errors_file

        env_variables.each_pair do |var, val|
          @script.set_env "HIVE_#{var}".upcase, val unless val.is_a?(Array)
        end

        @script.set_env 'RETRY_URNS', @job.execution_variables.retry_urns if @job.execution_variables.retry_urns && !@job.execution_variables.retry_urns.empty?
        @script.set_env 'TEST_NAMES', @job.execution_variables.tests if @job.execution_variables.tests && @job.execution_variables.tests != ['']

        @log.info 'Appending test script to execution script'
        @script.append_bash_cmd @job.command

        set_job_state_to :running

        @log.info 'Pre-execution setup'
        pre_script(@job, @file_system, @script)

        @job.start
        @log.info 'Running execution script'
        exit_value = @script.run
        @job.end(exit_value)
      rescue StandardError => e
        exception = e
        @log.error("Error starting job: #{e.backtrace.join("\n  : ")}")
      end

      begin
        @log.info 'Post-execution cleanup'
        set_job_state_to :uploading
        post_script(@job, @file_system, @script)

        # Upload results
        @file_system.finalise_results_directory
        upload_results(@job, "#{@file_system.testbed_path}/#{@job.execution_directory}", @file_system.results_path)
      rescue StandardError => e
        @log.error('Post execution failed: ' + e.message)
        @log.error("  : #{e.backtrace.join("\n  : ")}")
      end

      if exception || File.zero?(@file_system.script_errors_file)
        set_job_state_to :completed
        begin
          after_error(@job, @file_system, @script)
          upload_files(@job, @file_system.results_path, @file_system.logs_path)
        rescue StandardError => e
          @log.error("Exception while uploading files: #{e.backtrace.join("\n  : ")}")
        end
        if exception
          @job.error(exception.message)
          raise exception
        else
          @job.error('Errors raised by execution script')
          raise 'See errors file for errors reported in test.'
        end
      else
        @job.complete
        begin
          upload_files(@job, @file_system.results_path, @file_system.logs_path)
        rescue StandardError => e
          @log.error("Exception while uploading files: #{e.backtrace.join("\n  : ")}")
        end
      end

      Signal.trap('TERM') do
        @log.info('Worker terminated')
        exit
      end

      set_job_state_to :completed
      exit_value.zero?
    end

    # Diagnostics function to be extended in child class, as required
    def diagnostics
      retn = true
      protect
      retn = @diagnostic_runner.run unless @diagnostic_runner.nil?
      unprotect
      @log.info('Diagnostics failed') unless retn
      status = device_status
      status = set_device_status('happy') if status == 'busy'
      raise DeviceNotReady, "Current device status: '#{status}'" if status != 'happy'
      retn
    end

    # Current state of the device
    # This method should be replaced in child classes, as appropriate
    def device_status
      @device_status ||= 'happy'
    end

    # Set the status of a device
    # This method should be replaced in child classes, as appropriate
    def set_device_status(status)
      @device_status = status
    end

    # List of autogenerated queues for the worker
    def autogenerated_queues
      []
    end

    def update_queues
      # Get Queues from Hive Mind
      @log.debug('Getting queues from Hive Mind')
      @queues = (autogenerated_queues + @hive_mind.hive_queues(true)).uniq
      @log.debug("hive queues: #{@hive_mind.hive_queues}")
      @log.debug("Full list of queues: #{@queues}")
      update_queue_log
    end

    def update_queue_log
      File.open("#{LOG_DIRECTORY}/#{Process.pid}.queues.yml", 'w') { |f| f.write @queues.to_yaml }
    end

    # Upload any files from the test
    def upload_files(job, *paths)
      @log.info('Uploading assets')
      paths.each do |path|
        @log.info("Uploading files from #{path}")
        Dir.foreach(path) do |item|
          @log.info("File: #{item}")
          next if item == '.' || item == '..'
          begin
            artifact = job.report_artifact("#{path}/#{item}")
            @log.info("Artifact uploaded: #{artifact.attributes}")
          rescue StandardError => e
            @log.error("Error uploading artifact #{item}: #{e.message}")
            @log.error("  : #{e.backtrace.join("\n  : ")}")
          end
        end
      end
    end

    # Update results
    def upload_results(job, checkout, results_dir)
      res_file = detect_res_file(results_dir) || process_xunit_results(results_dir)

      @log.debug('Res file not found') unless res_file

      @log.info('Res file found')

      test_mine_config_file = testmine_config(checkout)
      lion_config_file      = lion_config(checkout)

      begin
        Res.submit_results(
          reporter: :hive,
          ir: res_file,
          job_id: job.job_id
        )
      rescue StandardError => e
        @log.warn("Res Hive upload failed #{e.message}")
      end

      begin
        if test_mine_config_file
          @log.debug("Res options: \n Job ID: #{job.job_id} \n Queue Name: #{job.execution_variables.queue_name}")
          Res.submit_results(
            reporter: :testmine,
            ir: res_file,
            config_file: test_mine_config_file,
            hive_job_id: job.job_id,
            version: job.execution_variables.version,
            target: job.execution_variables.queue_name,
            cert: Chamber.env.network.cert,
            cacert: Chamber.env.network.cafile,
            ssl_verify_mode: Chamber.env.network.verify_mode
          )
        end
      rescue StandardError => e
        @log.warn("Res Testmine upload failed #{e.message}")
      end

      begin
        if lion_config_file
          Res.submit_results(
            reporter: :lion,
            ir: res_file,
            config_file: line_config_file,
            hive_job_id: job.job_id,
            version: job.execution_variables.version,
            target: job.execution_variables.queue_name,
            cert: Chamber.env.network.cert,
            cacert: Chamber.env.network.cafile,
            ssl_verify_mode: Chamber.env.network.verify_mode
          )
        end
      rescue StandardError => e
        @log.warn("Res Lion upload failed #{e.message}")
      end

      # TODO: Add in Testrail upload
    end

    def detect_res_file(results_dir)
      Dir.glob("#{results_dir}/*.res").first
    end

    def process_xunit_results(results_dir)
      return if Dir.glob("#{results_dir}/*.xml").empty?

      xunit_output = Res.parse_results(parser: :junit, file: Dir.glob("#{results_dir}/*.xml").first)
      res_output   = File.open(xunit_output.io, 'rb')
      contents     = res_output.read

      res_output.close
      res = File.open("#{results_dir}/xunit.res", 'w+')
      res.puts contents
      res.close
      res
    end

    def testmine_config(checkout)
      Dir.glob("#{checkout}/.testmine.yml").first
    end

    def lion_config(checkout)
      Dir.glob("#{checkout}/.lion.yml").first
    end

    # Get a checkout of the repository
    def checkout_code(repository, checkout_directory, branch)
      @log.info 'Checking out the repository'
      repo = CodeCache.repo(repository)
      begin
        @log.debug "  #{repository} \n #{branch}"
        repo.checkout(:head, checkout_directory, branch)
      rescue StandardError => e
        message = "Unable to checkout repository #{repository} using #{branch}"

        @log.warn("#{message}: #{e.backtrace.join("\n  : ")}")
        raise("#{message}: #{e.message}")
      end
    end

    # Keep the worker process running
    def keep_worker_running?
      @log.debug('Keep Worker Running check ')
      if parent_process_dead?
        @log.info('Think parent process is dead')
        false
      else
        true
      end
    end

    # Keep the execution script running
    def keep_script_running?
      @log.debug('Keep Running check ')
      if exceeded_time_limit? || parent_process_dead? || File.size(@file_system.script_errors_file).positive?
        return false
      else
        return true
      end
    end

    def exceeded_time_limit?
      if @job && !@job.nil?
        if max_time = begin
                        @job.execution_variables.job_timeout
                      rescue StandardError
                        nil
                      end
          elapsed = (Time.now - @current_job_start_time).to_i
          @log.debug("Elapsed = #{elapsed} seconds, Max = #{max_time} minutes")
          if elapsed > max_time.to_i * 60
            @log.warn("Job has exceeded max time of #{max_time} minutes")
            return true
          end
        end
      end
      false
    end

    def parent_process_dead?
      Process.getpgid(@parent_pid)
      false
    rescue StandardError
      @log.warn('Parent process appears to have terminated')
      true
    end

    # Any setup required before the execution script
    def pre_script(job, file_system, script); end

    # Any tasks to do after a script has terminated with an error
    def after_error(job, file_system, script); end

    # Any device specific steps immediately after the execution script
    def post_script(job, file_system, script)
      signal_safe_post_script(job, file_system, script)
    end

    # Any device specific steps immediately after the execution script
    # that can be safely run in the a Signal.trap
    # This should be called by post_script
    def signal_safe_post_script(job, file_system, script); end

    # Do whatever device cleanup is required
    def cleanup; end

    # Allocate a port
    def allocate_port
      @log.warn("Using deprecated 'Hive::Worker.allocate_port' method")
      @log.warn('Use @port_allocator.allocate_port instead')
      @port_allocator.allocate_port
    end

    # Release a port
    def release_port(p)
      @log.warn("Using deprecated 'Hive::Worker.release_port' method")
      @log.warn('Use @port_allocator.release_port instead')
      @port_allocator.release_port(p)
    end

    # Release all ports
    def release_all_ports
      @log.warn("Using deprecated 'Hive::Worker.release_all_ports' method")
      @log.warn('Use @port_allocator.release_all_ports instead')
      @port_allocator.release_all_ports
    end

    # Set job info file
    def set_job_state_to(state)
      File.open("#{@file_system.home_path}/job_info", 'w') do |f|
        f.puts "#{Process.pid} #{state}"
      end
    end

    # Parameters for uniquely identifying the device
    def hive_mind_device_identifiers
      { id: @device_id }
    end

    private

    def protect
      @protect_file = File.expand_path("#{Process.pid}.protect", PIDS_DIRECTORY)
      @log.debug("Protecting worker with #{@protect_file}")
      FileUtils.touch @protect_file
    end

    def unprotect
      @log.debug("Unprotecting worker with #{@protect_file}")
      File.unlink @protect_file if @protect_file
      @protect_file = nil
    end
  end
end
