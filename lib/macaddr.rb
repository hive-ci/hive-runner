# Copied on 26 May 2016 directly from https://github.com/tsilen/macaddr, which
# is a fork of the official source of the Gem at
# https://github.com/ahoward/macaddr but with a fix to get a full list of all
# MAC addresses.
# License is given as "same as ruby's" (sic).

##
# Cross platform MAC address determination.
#
# To return the first MAC address on the system:
#
#   Mac.address
#
# To return an array of all MAC addresses:
#
#   Mac.addresses

begin
  require 'rubygems'
rescue LoadError
  nil
end

require 'socket'

module Mac
  VERSION = '1.7.1'.freeze

  def self.version
    ::Mac::VERSION
  end

  def self.dependencies
    {
    }
  end

  def self.description
    'cross platform mac address determination for ruby'
  end

  class << self
    ##
    # Accessor for the system's first MAC address, requires a call to #address
    # first

    attr_accessor 'mac_address'

    ##
    # Discovers and returns the system's MAC addresses.  Returns the first
    # MAC address, and includes an accessor #list for the remaining addresses:
    #
    #   Mac.addr # => first address
    #   Mac.addrs # => all addresses

    def address
      @mac_address ||= addresses.first
    end

    def addresses
      @mac_addresses ||= from_getifaddrs || []
    end

    link   = Socket::PF_LINK   if Socket.const_defined? :PF_LINK
    packet = Socket::PF_PACKET if Socket.const_defined? :PF_PACKET
    INTERFACE_PACKET_FAMILY = link || packet # :nodoc:

    ##
    # Shorter aliases for #address and #addresses

    alias addr address
    alias addrs addresses

    private

    def from_getifaddrs
      return unless Socket.respond_to? :getifaddrs

      interfaces = Socket.getifaddrs.select do |addr|
        addr.addr && addr.addr.pfamily == INTERFACE_PACKET_FAMILY
      end

      if Socket.const_defined? :PF_LINK
        interfaces.map do |addr|
          addr.addr.getnameinfo
        end.flatten.reject(&:empty?)
      elsif Socket.const_defined? :PF_PACKET
        interfaces.map do |addr|
          addr.addr.inspect_sockaddr[/hwaddr=([\h:]+)/, 1]
        end.reject do |mac_addr|
          mac_addr == '00:00:00:00:00:00'
        end
      end
    end
  end
end

MacAddr = Macaddr = Mac
