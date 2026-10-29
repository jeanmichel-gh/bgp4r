#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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


require 'bgp/optional_parameters/optional_parameter'

module BGP::OPT_PARM

  class Capability < Optional_parameter
    include BGP

    # The second argument matters and its default is the trap. Module
    # #const_defined? searches the ancestors unless told not to, and
    # Capability is a subclass of Optional_parameter, so the day
    # Optional_parameter::Unknown was added this guard went true and
    # Capability::Unknown was never defined at all. Every reference to it
    # then resolved up the chain to the parameter level class, which has a
    # different hash and a different constructor. The guard is here to make
    # the file safe to require twice, so what it means to ask is whether
    # this class defines it, which is what false says.
    #
    # bgp/path_attributes/path_attribute.rb has the same guard for its own
    # Unknown. It is correct today because nothing above Path_attribute
    # defines one, which is luck rather than design.
    unless const_defined?(:Unknown, false)
      Unknown = Class.new(self) do
        def initialize(s)
          if s.is_a?(String) and s.is_packed?
            parse(s)
          else
            raise ArgumentError
          end
        end
        def encode(extended: false)
          super @value, :extended => extended
        end
        def parse(s)
          @value = super(s)
        end
      end
    end
    
    include BGP::OPT_PARM
    def initialize(code)
      super(OPT_PARM::CAPABILITY)
      @code=code
    end
    # The capability itself is a one octet code and a one octet length
    # (RFC 5492 section 4) whatever the optional parameter around it
    # looks like: RFC 9072 section 2 widens the Parameter Length and
    # nothing else, so extended goes to the parameter header and stops
    # there. A DYN_CAP capability has no parameter header at all, since
    # it travels in a CAPABILITY message and not in an OPEN.
    def encode(value='', extended: false)
      if self.class.to_s =~ /BGP::OPT_PARM::DYN_CAP/
        [@code,value.size, value].pack("Cna*")
      else
        super([@code,value.size, value].pack("CCa*"), :extended => extended)
      end
    end
    
    def parse(_s)
      s = _s
      if self.class.to_s =~ /BGP::OPT_PARM::DYN_CAP/
        @code, len = _s.slice!(0,3).unpack('Cn')
      else
        s = super(_s)
        @code, len = s.slice!(0,2).unpack('CC')
      end
      s.slice!(0,len).is_packed
    end
    def to_s
      "Option Capabilities Advertisement (#{@parm_type}): [#{to_shex}]"
    end
    def to_hash(h={})
      if h.empty?
        {:code=> @code}
      else
        {:code=> @code, :capability=> h}
      end
    end

    # One line naming the capability, for the revision table a
    # Capability message prints. The message carries one capability per
    # revision (draft-ietf-idr-dynamic-cap-19, 16 February 2026,
    # section 3), and to_s of a capability is several lines, with the
    # optional parameter header and a hex dump, so it does not fit a
    # table row.
    #
    # The default names the capability after its class and gives its
    # capability code, which every capability has (RFC 5492 section 4).
    # It lives here rather than on each capability so that a capability
    # added later prints without having to remember this method; before
    # this, only CAP::Mbgp and CAP::Unknown had it and every other
    # capability raised NoMethodError when a Capability message printed.
    #
    # A capability overrides it only when it has something shorter and
    # more useful to say than its name, the way CAP::Mbgp names its
    # address family. Display only: nothing here touches the wire.
    def to_s_brief
      "#{brief_name} (#{@code})"
    end

    private

    # The class name without its namespace, so CAP::Route_refresh and
    # the DYN_CAP class generated from it read the same. The header
    # shape differs between the two, the capability does not.
    def brief_name
      (self.class.name || self.class.to_s).split('::').last.tr('_', ' ')
    end

  end
end

module BGP
  module OPT_PARM
    module CAP

      # A capability whose code bgp4r does not implement. Parsing cannot
      # interpret the value, so the octets are kept as they arrived and
      # written back unchanged: encode returns byte for byte what came
      # in.
      #
      #   CAP::Unknown.new(100, 'value')
      #   CAP::Unknown.new(wire_bytes)
      #   CAP::Unknown.new(:code=>100, :value=>'76616c7565')
      #
      # The header shape follows the namespace, as it does for every
      # other capability: CAP::Unknown writes the one octet length of
      # RFC 5492 section 4, DYN_CAP::Unknown the two octet length of
      # draft-ietf-idr-dynamic-cap-19 section 3. DYN_CAP::Unknown is
      # built from this class by bgp/optional_parameters/capabilities.rb,
      # like every other DYN_CAP capability.
      #
      # The code and the value are never checked. Any code, any length,
      # any octets.
      class Unknown < BGP::OPT_PARM::Capability

        attr_reader :value

        def initialize(*args)
          if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
            super(nil)
            parse(args[0])
          elsif args.size == 1 and args[0].is_a?(Hash)
            h = args[0]
            super(h[:code].to_i)
            @value = [h[:value].to_s].pack('H*')
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            super(args[0])
            @value = args[1].to_s.b
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 "expected (code, value), wire bytes or a hash"
          end
        end

        def encode(extended: false)
          super(@value, :extended => extended)
        end

        def parse(s)
          @value = super(s)
        end

        def to_hash
          h = { :code => @code }
          h[:value] = @value.unpack('H*')[0] unless @value.empty?
          h
        end

        def to_s
          super + "\n    Unknown Capability (#{@code}), " \
                  "#{@value.size} value octets: [#{@value.unpack('H*')[0]}]"
        end

        def to_s_brief
          "Unknown Capability #{@code} [#{@value.unpack('H*')[0]}]"
        end

      end

    end
  end
end

module BGP::OPT_PARM
  def Capability.factory(s)
    code = s.slice(2,1).unpack('C')[0]
    case code
    when CAP_AS4
      CAP::As4.new(s)
    when CAP_MBGP
      CAP::Mbgp.new(s)
    when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
      # RFC 2918 section 3: code 2, and "Capability Length field of this
      # capability is zero"; 128 is the pre-standard Cisco code. It takes
      # the wire bytes rather than the code, so value octets no RFC allows
      # are kept and written back instead of silently dropped.
      CAP::Route_refresh.new(s)
    when CAP_ORF,CAP_ORF_CISCO
      CAP::Orf.new(s)
    when CAP_GR
      CAP::Graceful_restart.new(s)
    when CAP_ADD_PATH
      CAP::Add_path.new(s)
    when CAP_EXTENDED_NEXTHOP
      CAP::Extended_nexthop.new(s)
    when CAP_ROLE
      # RFC 9234 section 4.1: code 9, one octet, the speaker's BGP Role.
      CAP::Role.new(s)
    when CAP_DYNAMIC
      # RFC 5492 section 4 and draft-ietf-idr-dynamic-cap-19 section 9:
      # the Dynamic Capability capability is code 67 and carries no value.
      # Like CAP::Route_refresh above it takes the wire bytes, so value
      # octets that arrive anyway are kept rather than dropped.
      CAP::Dynamic.new(s)
    when CAP_ENHANCED_ROUTE_REFRESH
      # RFC 7313 section 3.1: code 70, "The Capability Length field of
      # this capability is zero." It takes the wire bytes rather than the
      # code, so value octets no RFC allows are kept and written back
      # instead of silently dropped.
      CAP::Enhanced_route_refresh.new(s)
    else
      Capability::Unknown.new(s)
    end
  end

  # The same dispatch for a hash rather than wire bytes, so Open can
  # rebuild from its own to_hash. Capability.factory reads the code out of
  # the octets; this reads it out of the hash, and hands the whole hash to
  # the class, which takes either the nested form to_hash writes or the
  # bare inner hash.
  #
  # **Two codes are refused rather than attempted**, because their own
  # to_hash does not carry what the capability holds: Add_path hashes as
  # {:code=>69} whatever its RFC 7911 section 4 tuples are, and
  # Graceful_restart as {:code=>64} whatever its restart time and
  # families. Building from those would silently produce a different
  # capability, which is worse than refusing, and that is the one kind of
  # refusal Conventions allows a constructor: an input it cannot
  # represent. Widening those two to_hash forms changes the shape every
  # caller sees, so it is recorded under "Known issues to work on" rather
  # than decided here.
  LOSSY_HASH = { CAP_ADD_PATH => 'Add_path', CAP_GR => 'Graceful_restart' }.freeze

  def Capability.from_hash(h)
    code = h[:code]
    raise ArgumentError, "no :code in #{h.inspect}" if code.nil?
    if (name = LOSSY_HASH[code])
      raise ArgumentError,
            "CAP::#{name} cannot be built from a hash: its to_hash carries " \
            "only #{{ :code => code }.inspect} and loses the rest. See " \
            '"Known issues to work on" in CLAUDE.md.'
    end
    case code
    when CAP_AS4                             then CAP::As4.new(h)
    when CAP_MBGP                            then CAP::Mbgp.new(h)
    when CAP_ROUTE_REFRESH                   then CAP::Route_refresh.new(h)
    when CAP_ROUTE_REFRESH_CISCO             then CAP::Route_refresh.new(h)
    when CAP_ORF, CAP_ORF_CISCO              then CAP::Orf.new(h)
    when CAP_EXTENDED_NEXTHOP                then CAP::Extended_nexthop.new(h)
    when CAP_ROLE                            then CAP::Role.new(h)
    when CAP_DYNAMIC                         then CAP::Dynamic.new(h)
    when CAP_ENHANCED_ROUTE_REFRESH          then CAP::Enhanced_route_refresh.new(h)
    else Capability::Unknown.new(h)
    end
  end
end

module BGP::OPT_PARM
    def Capability.dynamic_factory(s)
      code = s.slice(0,1).unpack('C')[0]
      case code
      when CAP_AS4
        DYN_CAP::As4.new(s)
      when CAP_MBGP
        DYN_CAP::Mbgp.new(s)
      when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
        DYN_CAP::Route_refresh.new(s)
      when CAP_ORF,CAP_ORF_CISCO
        DYN_CAP::Orf.new(s)
      when CAP_ADD_PATH
        DYN_CAP::Add_path.new(s)
      when CAP_ROLE
        DYN_CAP::Role.new(s)
      when CAP_GR
        DYN_CAP::Graceful_restart.new(s)
      when CAP_ENHANCED_ROUTE_REFRESH
        DYN_CAP::Enhanced_route_refresh.new(s)
      else
        # draft-ietf-idr-dynamic-cap-19 section 3: here the capability
        # has a one octet code and a two octet length, so the fallback
        # has to be a DYN_CAP class. Capability::Unknown read the two
        # octet optional parameter header instead, left @code nil and
        # raised, which lost octets bgp4r is meant to keep.
        DYN_CAP::Unknown.new(s)
      end
    end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
