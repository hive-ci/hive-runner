require 'chamber'
require 'hive/log'
require 'hive/register'
require 'mind_meld/hive'
require 'macaddr'
require 'socket'
require 'sys/uname'
require 'sys/cpu'
require 'airbrake-ruby'
require 'etc'

# The Hive automated testing framework
module Hive
  Chamber.load(
    basepath: ENV['HIVE_CONFIG'] || './config/',
    namespaces: {
      environment: ENV['HIVE_ENVIRONMENT'] || 'test'
    }
  )
  DAEMON_NAME = Chamber.env.daemon_name? ? Chamber.env.daemon_name : 'HIVE'

  if Chamber.env.logging?
    if Chamber.env.logging.directory?
      LOG_DIRECTORY = File.expand_path Chamber.env.logging.directory
    else
      raise 'Missing log directory'
    end
    PIDS_DIRECTORY = if Chamber.env.logging.pids?
                       File.expand_path Chamber.env.logging.pids
                     else
                       LOG_DIRECTORY
                     end
  else
    raise 'Missing logging section in configuration file'
  end

  if Chamber.env.key?('errbit')
    Airbrake.configure do |config|
      config.host = Chamber.env.errbit.host
      config.project_id = Chamber.env.errbit.project_id
      config.project_key = Chamber.env.errbit.project_key
    end
  end

  def self.config
    Chamber.env
  end

  def self.logger
    unless @logger
      @logger = Hive::Log.new

      if Hive.config.logging.main_filename?
        @logger.add_logger("#{LOG_DIRECTORY}/#{Hive.config.logging.main_filename}", Chamber.env.logging.main_level? ? Chamber.env.logging.main_level : 'INFO')
      end
      if Hive.config.logging.console_level?
        @logger.add_logger(STDOUT, Hive.config.logging.console_level)
      end

      @logger.default_progname = 'Hive core'
    end

    @logger.hive_mind = @hive_mind unless @logger.hive_mind

    @logger
  end

  def self.hive_mind
    Hive.logger.debug "Sysname: #{Sys::Uname.sysname}"
    Hive.logger.debug "Release: #{Sys::Uname.release}"
    unless @hive_mind
      if (@hive_mind = MindMeld::Hive.new(
        url: Chamber.env.network.hive_mind? ? Chamber.env.network.hive_mind : nil,
        pem: Chamber.env.network.cert ? Chamber.env.network.cert : nil,
        ca_file: Chamber.env.network.cafile ? Chamber.env.network.cafile : nil,
        verify_mode: Chamber.env.network.verify_mode ? Chamber.env.network.verify_mode : nil,
        device: {
          hostname: Hive.hostname,
          version: Gem::Specification.find_by_name('hive-runner').version.to_s,
          runner_plugins: Hash[Gem::Specification.all.select { |g| g.name =~ /hive-runner-/ }.map { |p| [p.name, p.version.to_s] }],
          macs: Mac.addrs,
          ips: [Hive.ip_address],
          brand: Hive.config.brand? ? Hive.config.brand : DAEMON_NAME,
          model: Hive.config.model? ? Hive.config.model : 'Hive',
          operating_system_name: Sys::Uname.sysname,
          operating_system_version: Sys::Uname.release,
          device_type: 'Hive'
        }
      )) && Etc.respond_to?(:nprocessors) # Require Ruby >= 2.2
        @hive_mind.add_statistics(
          label: 'Processor count',
          value: Etc.nprocessors,
          format: 'integer'
        )

        if Chamber.env.diagnostics? && Chamber.env.diagnostics.hive? && Chamber.env.diagnostics.hive.load_warning? && Chamber.env.diagnostics.hive.load_error?
          @hive_mind.add_statistics(
            [
              {
                label: 'Load average warning threshold',
                value: Chamber.env.diagnostics.hive.load_warning,
                format: 'float'
              },
              {
                label: 'Load average error threshold',
                value: Chamber.env.diagnostics.hive.load_error,
                format: 'float'
              }
            ]
          )
        end
        @hive_mind.flush_statistics
        @logger.hive_mind = @hive_mind if @logger
      end
    end

    @hive_mind
  end

  def self.register
    @register ||= Hive::Register.new
  end

  # Poll the device database
  def self.poll
    Hive.logger.debug 'Polling hive'
    rtn = Hive.hive_mind.poll
    Hive.logger.debug "Return data: #{rtn}"
    if rtn.key? 'error'
      Hive.logger.warn "Hive polling failed: #{rtn['error']}"
    else
      Hive.logger.info 'Successfully polled hive'
    end
  end

  # Gather and send statistics
  def self.send_statistics
    Hive.hive_mind.add_statistics(
      label: 'Load average',
      value: Sys::CPU.load_avg[0],
      format: 'float'
    )
    Hive.hive_mind.flush_statistics
  end

  # Get the IP address of the Hive
  def self.ip_address
    ip = Socket.ip_address_list.detect(&:ipv4_private?)
    ip.ip_address
  end

  # Get the hostname of the Hive
  def self.hostname
    Socket.gethostname.split('.').first
  end
end
