# frozen_string_literal: true

require 'timeout'

module Hive
  class ExecutionScript
    def initialize(config)
      @job          = config[:job]
      @file_system  = config[:file_system]
      @log          = config[:log]
      @keep_running = config[:keep_running]

      @path         = @file_system.executed_script_path
      @log_path     = @file_system.logs_path

      @log.debug "Creating execution script with path=#{@path}"
      @env = {
        'HIVE_SCHEDULER' => Hive.config.network.scheduler,
        'HIVE_WORKING_DIRECTORY' => @file_system.testbed_path
      }
      @env_unset = %w[
        BUNDLE_GEMFILE
        BUNDLE_BIN_PATH
        GEM_PATH
        RUBYOPT
        rvm_
      ]
      # Environment variables that should not be made visible in the execution
      # script uploaded with the results
      @env_secure = {
        'HIVE_CERT' => Hive.config.network.cert
      }
      @script_lines = []
    end

    def prepend_bash_cmd(shell_command)
      @log.debug "bash.rb - Prepending bash command to #{@path} script: " + shell_command
      @script_lines = ([] << shell_command << @script_lines).flatten
    end

    def append_bash_cmd(shell_command)
      @log.debug "bash.rb - Appending bash command to #{@path} script: " + shell_command
      @script_lines << shell_command
    end

    def set_env(var, value)
      @env[var] = value

      # TODO: What if the element appears multiple times?
      if (i = @env_unset.index(var))
        @env_unset.delete(i)
      end

      ## In Ruby 2, replace the above 'if' block with ...
      # @env_unset.remove(var)
    end

    def unset_env(var)
      @env.delete(var)
      @env_unset << var
    end

    def get_env(var)
      @env[var]
    end

    def helper_path
      scripts_dir = File.expand_path(File.dirname(__FILE__) + '../../../scripts/')
      File.join(scripts_dir, 'hive-script-helper.sh')
    end

    def run
      @log.info 'bash.rb - Writing script out to file'
      File.open(@path, 'w') do |f|
        f.write("#!/bin/bash --login\n")
        f.write(". #{helper_path}\n")
        f.write("# Set environment\n")
        @env.each do |key, value|
          # An escaped ' in a single quoted string in bash looks like '"'"'
          if value.is_a?(Array)
            f.write("export #{key}=(" + value.collect { |v| "'#{v.to_s.gsub("'", '\'"\'"\'')}'" }.join(' ') + ")\n")
          else
            f.write("export #{key}='#{value.to_s.gsub("'", '\'"\'"\'')}'\n")
          end
        end
        @env_unset.each do |var|
          f.write("unset #{var}\n")
        end
        f.write('cd $HIVE_WORKING_DIRECTORY')
        f.write("\n# Test execution\n")
        f.write(@script_lines.join("\n"))
      end
      File.chmod(0o700, @path)

      pid = Process.spawn @env_secure, @path.to_s, pgroup: true, in: '/dev/null', out: "#{@log_path}/stdout.log", err: "#{@log_path}/stderr.log"
      @pgid = Process.getpgid(pid)

      exit_value = nil
      running = true
      while running
        begin
          Timeout.timeout(30) do
            Process.wait pid
            exit_value = $?.exitstatus
            running = false
          end
        rescue Timeout::Error
          @log.debug('Sub-process keep_running check & upload logs')
          unless @keep_running.nil? || @keep_running.call
            Process.kill(-9, @pgid)
            raise 'Script terminated. Check worker logs for more details'
          end
          # TODO: Upload in-progress script logs
        end
      end

      # Kill off anything that is still running
      terminate

      # Return exit value of the script
      exit_value
    end

    def terminate
      return unless @pgid

      begin
        @log.debug "Ensuring process #{@pgid} is terminated"
        Process.kill(-9, @pgid)
      rescue Errno::ESRCH
        @log.debug "Process #{@pgid} already dead"
      rescue StandardError => e
        @log.warn "Unexpected error while terminating process #{@pgid}: #{e}"
      end
      @pgid = nil
    end
  end
end
