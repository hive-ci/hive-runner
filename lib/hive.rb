# frozen_string_literal: true

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
  # Supress Hashie error
  Hashie.logger = Logger.new(nil)

  Chamber.load(
    basepath: ENV['HIVE_CONFIG'] || './config/',
    namespaces: {
      environment: ENV['HIVE_ENVIRONMENT'] || 'test'
    }
  )

  raise 'Missing logging section in configuration file' unless Chamber.env.logging?

  raise 'Missing log directory' unless Chamber.env.logging.directory?

  DAEMON_NAME ||= Chamber.env.daemon_name? ? Chamber.env.daemon_name : 'HIVE'

  LOG_DIRECTORY ||= File.expand_path(Chamber.env.logging.directory)

  PIDS_DIRECTORY ||= Chamber.env.logging.pids? ? File.expand_path(Chamber.env.logging.pids) : LOG_DIRECTORY

  if Chamber.env.key?('errbit')
    Airbrake.configure do |config|
      config.host        = Chamber.env.errbit.host
      config.project_id  = Chamber.env.errbit.project_id
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
      @logger.add_logger(STDOUT, Hive.config.logging.console_level) if Hive.config.logging.console_level?

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
          hostname: Hive.config.name? ? Hive.config.name : Hive.hostname,
          serial: serial_identifier,
          version: hive_runner_version,
          runner_plugins: runner_plugins,
          macs: Mac.addrs,
          ips: [Hive.ip_address],
          brand: Hive.config.brand? ? Hive.config.brand : 'Hive',
          model: Hive.config.model? ? Hive.config.model : 'Hive',
          location: Hive.config.location? ? Hive.config.location : nil,
          building: Hive.config.building? ? Hive.config.building : nil,
          operating_system_name: system_name,
          operating_system_version: system_version,
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

  private

  def self.hive_runner_version
    Gem::Specification.find_by_name('hive-runner').version.to_s
  end

  def self.runner_plugins
    Hash[Gem::Specification.find_all_by_name('hive-runner').map { |p| [p.name, p.version.to_s] }]
  end

  def self.serial_identifier
    Sys::Uname.sysname.casecmp('darwin').zero? ? mac_serial : linux_serial
  end

  def self.system_name
    Sys::Uname.sysname.casecmp('darwin').zero? ? operating_system_info(`sw_vers`, :ProductName) : Sys::Uname.sysname
  end

  def self.system_version
    Sys::Uname.sysname.casecmp('darwin').zero? ? operating_system_info(`sw_vers`, :ProductVersion) : Sys::Uname.release
  end

  def self.operating_system_info(command, type)
    result    = command
    props     = {}
    prop_list = result.split("\n")

    prop_list.each do |line|
      line.scan(/(.*):\t(.*)/).map do |(key, value)|
        props[key.strip.delete(' ').to_sym] = value
      end
    end
    props[type]
  end

  def self.mac_serial
    `system_profiler SPHardwareDataType | awk '/Serial/ {print $4}'`.to_s.strip
  end

  def self.linux_serial
    command = `udevadm info --query=all --name=/dev/sda | grep -Eo ID_SERIAL_SHORT=(.*)`
    command.split('=').last.to_s.strip
  end
end
