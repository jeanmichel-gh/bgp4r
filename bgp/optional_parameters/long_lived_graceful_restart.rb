#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
#
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP

  # The Long-Lived Graceful Restart Capability, RFC 9494 section 3.1.
  # Capability code 71, and a value of zero or more tuples, each seven
  # octets:
  #
  #   AFI                        16 bits
  #   SAFI                        8 bits
  #   Flags for Address Family    8 bits, only the F bit defined
  #   Long-Lived Stale Time      24 bits, in seconds
  #
  # The F bit is the most significant bit of the Flags. Set, it says the
  # state for that AFI/SAFI was preserved across the previous restart.
  # The other seven bits are reserved and "MUST be set to zero by the
  # sender and ignored by the receiver", so a tuple keeps the whole octet
  # and writes it back: a reserved bit that arrived set replays.
  #
  #   CAP::Long_lived_graceful_restart.new
  #   CAP::Long_lived_graceful_restart.new(1, 1, 0x80, 3600)
  #   CAP::Long_lived_graceful_restart.new(:ipv4, :unicast, :preserved, 3600)
  #   CAP::Long_lived_graceful_restart.new(wire_bytes)
  #   CAP::Long_lived_graceful_restart.new(cap.to_hash)
  #
  # and add(afi, safi, flags, llst) for each further family.
  #
  # **Nothing is validated.** Section 4.1 says the capability MUST be
  # disregarded unless the Graceful Restart Capability is advertised too.
  # That is a rule about a session, so it is not this class's: a test can
  # send LLGR alone and watch what a router does with it.
  #
  # Octets after the last whole tuple are kept as a tail and written
  # back, as communities.rb does, so a capture with a short last tuple
  # replays byte for byte.
  class Long_lived_graceful_restart < BGP::OPT_PARM::Capability

    # Section 3.1, "Preservation of state" in the IANA registry.
    F_BIT = 0x80

    # The widest value the 24-bit field holds.
    MAX_LLST = 0xffffff

    attr_reader :tuples, :tail

    def initialize(*args)
      @tuples = []
      @tail = String.new
      if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
        super(nil)
        parse(args[0])
      elsif args.size == 1 and args[0].is_a?(Hash)
        h = args[0]
        super(h[:code] || BGP::OPT_PARM::CAP_LLGR)
        c = h.key?(:capability) ? h[:capability] : h
        [c[:families]].flatten.compact.each do |f|
          add(f[:afi], f[:safi], f[:flags].to_i, f[:llst].to_i)
        end
        @tail = [c[:tail].to_s].pack('H*') if c[:tail]
      else
        super(BGP::OPT_PARM::CAP_LLGR)
        add(*args) unless args.empty?
      end
    end

    # One tuple. flags may be :preserved or :not_preserved for the F bit
    # alone, or any octet. A value that does not fit its field is refused,
    # since the alternative is silently sending a different one.
    def add(afi, safi, flags=0, llst=0)
      flags = case flags
              when :preserved     then F_BIT
              when :not_preserved then 0
              else flags.to_i
              end
      raise ArgumentError, "flags #{flags} do not fit one octet" unless (0..0xff).cover?(flags)
      llst = llst.to_i
      raise ArgumentError, "stale time #{llst} does not fit 24 bits" unless (0..MAX_LLST).cover?(llst)
      @tuples << [IANA.afi(afi), IANA.safi(safi), flags, llst]
      self
    end

    # Section 4.2: "If the LLST is zero, or the AFI/SAFI is not listed
    # in the received LLGR Capability" the routes are not retained, so a
    # family not in the capability answers 0.
    def stale_time(afi, safi)
      afi, safi = IANA.afi(afi), IANA.safi(safi)
      t = @tuples.find { |a, s, _, _| a == afi and s == safi }
      t ? t[3] : 0
    end

    def preserved?(afi, safi)
      afi, safi = IANA.afi(afi), IANA.safi(safi)
      t = @tuples.find { |a, s, _, _| a == afi and s == safi }
      !!(t and t[2] & F_BIT == F_BIT)
    end

    def parse(s)
      value = super(s)
      @tuples = []
      while value.size >= 7
        afi, safi, flags, hi, lo = value.slice!(0, 7).unpack('nCCCn')
        @tuples << [afi, safi, flags, (hi << 16) | lo]
      end
      @tail = value.b
    end

    def encode(extended: false)
      value = @tuples.collect { |afi, safi, flags, llst|
        [afi, safi, flags, llst >> 16, llst & 0xffff].pack('nCCCn')
      }.join + @tail
      super(value, :extended => extended)
    end

    def to_hash
      c = { :families => @tuples.collect { |afi, safi, flags, llst|
              { :afi => afi, :safi => safi, :flags => flags, :llst => llst } } }
      c[:tail] = @tail.unpack1('H*') unless @tail.empty?
      super(c)
    end

    def to_s
      s = ["\n    Long-Lived Graceful Restart (#{@code}), length: #{2 + 7 * @tuples.size + @tail.size}"]
      @tuples.each { |t| s << "        #{family_s(*t)}" }
      s << "        tail: #{@tail.unpack1('H*')}" unless @tail.empty?
      super + s.join("\n")
    end

    def to_s_brief
      "Long-Lived Graceful Restart (#{@code})"
    end

    private

    def family_s(afi, safi, flags, llst)
      state = flags & F_BIT == F_BIT ? 'state preserved' : 'state not preserved'
      reserved = flags & ~F_BIT & 0xff
      state += ", reserved bits 0x#{reserved.to_s(16)}" if reserved > 0
      "AFI #{IANA.afi_s(afi)}, SAFI #{IANA.safi_s(safi)}, #{state} (0x#{flags.to_s(16)}), stale time #{llst}s"
    end

  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
