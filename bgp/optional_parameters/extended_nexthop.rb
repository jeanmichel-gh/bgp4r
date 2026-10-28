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

  # Extended Next Hop Encoding capability, RFC 8950 section 4.
  #
  # Capability code 5. The value is a list of triples, each 6 octets:
  #
  #   +-----------------------------------------------------+
  #   | NLRI AFI - 1 (2 octets)                             |
  #   +-----------------------------------------------------+
  #   | NLRI SAFI - 1 (2 octets)                            |
  #   +-----------------------------------------------------+
  #   | Nexthop AFI - 1 (2 octets)                          |
  #   +-----------------------------------------------------+
  #   | ....                                                |
  #
  # The NLRI SAFI takes 2 octets here, unlike in the MP capability.
  # RFC 8950 defines NLRI AFI 1 with SAFI 1, 2, 4, 128 or 129, and
  # Nexthop AFI 2.
  #
  # Three ways to build it:
  #
  #   Extended_nexthop.new(1, 1, 2)                     # one triple
  #   Extended_nexthop.new([1, 1, 2], [:ipv4, 128, :ipv6])
  #   Extended_nexthop.new(:families => [{:afi=>1, :safi=>1, :nexthop_afi=>2}])
  #   Extended_nexthop.new(wire_bytes)
  #
  class Extended_nexthop < BGP::OPT_PARM::Capability

    attr_reader :families

    def initialize(*args)
      @families = []
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size==1 and args[0].is_a?(Hash)
        super(OPT_PARM::CAP_EXTENDED_NEXTHOP)
        h = args[0][:capability] || args[0]
        [h[:families]].flatten.compact.each { |f| add(f[:afi], f[:safi], f[:nexthop_afi]) }
      elsif args.all? { |a| a.is_a?(Array) }
        super(OPT_PARM::CAP_EXTENDED_NEXTHOP)
        args.each { |t| add(*t) }
      elsif args.size==3
        super(OPT_PARM::CAP_EXTENDED_NEXTHOP)
        add(*args)
      else
        raise ArgumentError, "invalid argument: #{args.inspect}, expected (afi, safi, nexthop_afi), " \
                             "arrays of those, a Hash or wire bytes"
      end
    end

    def add(afi, safi, nexthop_afi=2)
      t = [IANA.afi(afi), IANA.safi(safi), IANA.afi(nexthop_afi)]
      unless t.all? { |v| v.is_a?(Integer) && (0..0xffff) === v }
        raise ArgumentError, "invalid family #{[afi, safi, nexthop_afi].inspect}, " \
                             "each value must fit in 2 octets (RFC 8950 section 4)"
      end
      @families << t unless @families.include?(t)
      self
    end

    # True when IPv4 NLRI of this AFI/SAFI may carry a next hop of
    # nexthop_afi.
    def has?(afi, safi, nexthop_afi=2)
      @families.include?([IANA.afi(afi), IANA.safi(safi), IANA.afi(nexthop_afi)])
    end

    def encode(extended: false)
      super(@families.collect { |t| t.pack('nnn') }.join, :extended => extended)
    end

    def parse(s)
      value = super(s)
      if value.size % 6 != 0
        raise ArgumentError, "Extended Next Hop capability value is #{value.size} octets, " \
                             "expected a multiple of 6 (RFC 8950 section 4)"
      end
      while value.size>0
        @families << value.slice!(0,6).unpack('nnn')
      end
    end

    def to_s
      super + "\n    Extended Next Hop Encoding (#{CAP_EXTENDED_NEXTHOP}), length: #{@families.size*6}" +
      @families.collect { |afi, safi, nh|
        "\n      AFI #{IANA.afi_s(afi)}, SAFI #{IANA.safi_s(safi)}, Nexthop AFI #{IANA.afi_s(nh)}"
      }.join
    end

    def to_hash
      super({:families => @families.collect { |afi, safi, nh| {:afi=>afi, :safi=>safi, :nexthop_afi=>nh} }})
    end

    # Which NLRI families may take a next hop of which family. That is
    # the whole content of the capability, so the brief form keeps it.
    def to_s_brief
      families = @families.collect { |afi, safi, nh|
        "#{IANA.afi_name(afi)}, #{IANA.safi_name(safi)} via #{IANA.afi_name(nh)}"
      }
      families.empty? ? 'Extended Next Hop' : "Extended Next Hop #{families.join('; ')}"
    end

  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
