 #--
# Copyright 2008-2009, 2011, 2026 Jean-Michel Esnault.
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

require 'bgp/path_attributes/attribute'
require 'bgp/nlris/nlris'

module BGP

  module MpReachCommon

    def self.included(obj)
      obj.extend ClassMethods
    end

    def set(h)
      @safi = h[:safi]
      @path_id = h[:path_id]
      @afi = h[:afi]
      # Every prefix family carries an address in its NLRI, so the
      # family can be read off one. Three families do not. A flow spec
      # rule carries components instead, and which family it is shows in
      # their keys. An EVPN NLRI carries a route type whose fields are
      # an RD, an ESI and the rest, and its family is not a question at
      # all: RFC 7432 section 7 fixes it at AFI 25. An RT-constrain
      # prefix holds an origin AS and a route target, and RFC 4684
      # section 4 fixes its family at AFI 1. All three arms below answer
      # for themselves, so afi_from_nlris is not asked a question it
      # would answer by handing nil to IPAddr.
      @afi ||= self.class.afi_from_nlris(h[:nlris]) unless
        [IANA::SAFI::FLOW_SPEC_RULES_1, IANA::SAFI::FLOW_SPEC_RULES_2,
         IANA::SAFI::EVPN,
         IANA::SAFI::ROUTE_TARGET_CONSTRAINTS].include?(safi)
      case safi
      when 1,2
        pfx_klass = prefix_klass(afi, safi)
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          case n
          when String
            path_id ? pfx_klass.new(path_id, n) : pfx_klass.new(n)
          when Hash
            # A path ID in the NLRI hash wins over the top level :path_id.
            pid = n[:path_id] || @path_id
            pfx = n[:prefix]
            pid ? pfx_klass.new(pid, pfx) : pfx_klass.new(pfx)
          else
            raise ArgumentError, "Invalid: #{n.inspect}"
          end
        end
      when 4
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          path_id = n[:path_id] || @path_id
          prefix = n[:prefix].is_a?(String) ? Prefix.new(n[:prefix]) : n[:prefix]
          Labeled.new_with_path_id(path_id, prefix, *labels_from(n))
        end
      when 128,129
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          path_id = n[:path_id] || @path_id
          prefix = n[:prefix].is_a?(Prefix) ? n[:prefix] :  Prefix.new(n[:prefix])
          rd = n[:rd].is_a?(Rd) ?  n[:rd] : Rd.new(*n[:rd])
          Labeled.new_with_path_id(path_id, Vpn.new(prefix,rd), *labels_from(n))
        end
      when IANA::SAFI::FLOW_SPEC_RULES_1, IANA::SAFI::FLOW_SPEC_RULES_2
        # RFC 8955 section 4. A rule is given either as a Flow_spec,
        # which is used as it stands, or as the hash Flow_spec reads,
        # one key per component. The component keys say which family a
        # rule is, so nothing here passes the AFI down.
        #
        # **No next hop is written for this family and none has to be
        # taken out.** Section 4: "When advertising Flow Specifications,
        # the Length of the Next-Hop Network Address MUST be set to 0."
        # Mp_reach#encode writes @nexthops.size, which is 0 when the
        # caller passes no :nexthop, so the rule holds by itself.
        # Passing one anyway still puts it on the wire, because building
        # never validates and that is a negative test.
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          next n if n.is_a?(Flow_spec)
          fs = Flow_spec.new(n)
          fs.path_id ||= @path_id
          fs
        end
        @afi ||= @nlris.empty? ? IANA::AFI::IPv4 : @nlris.first.afi
      when IANA::SAFI::EVPN
        # RFC 7432 section 7. A route is given either as an Evpn, which
        # is used as it stands, or as the hash Evpn reads, one key for
        # the route type. Unlike flow spec there is no family to infer:
        # section 7 fixes AFI 25, so the arm sets it rather than asking
        # the NLRIs.
        #
        # **A next hop is written here, where flow spec writes none.**
        # Section 14: "The Next Hop field of the MP_REACH_NLRI attribute
        # of the route MUST be set to the IPv4 or IPv6 address of the
        # advertising PE." So the caller passes :nexthop as for SAFI 1
        # and 2, and the line below this case builds it.
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          next n if n.is_a?(Evpn)
          # Evpn.new takes a Route, a hash or wire bytes, so one call
          # covers every form a caller can pass.
          e = Evpn.new(n)
          e.path_id ||= @path_id
          e
        end
        @afi ||= IANA::AFI::L2VPN
      when IANA::SAFI::ROUTE_TARGET_CONSTRAINTS
        # RFC 4684 section 4. A membership prefix is given either as an
        # Rt_constrain, used as it stands, or as the hash Rt_constrain
        # reads. Like EVPN there is no family to infer: section 4 says
        # the pair is "(AFI=1, SAFI=132)", so the arm sets it rather
        # than asking the NLRIs, which hold an origin AS and a route
        # target rather than an address.
        #
        # **A next hop is written here, as for EVPN.** Section 4: "The
        # Next Hop field of MP_REACH_NLRI attribute shall be
        # interpreted as an IPv4 address whenever the length of NextHop
        # address is 4 octets, and as a IPv6 address whenever the length
        # of the NextHop address is 16 octets." So the caller passes
        # :nexthop and the line below this case builds it.
        #
        # **An Array of field values cannot be passed here, and that is
        # the flatten below rather than a decision.** `[h[:nlris]]
        # .flatten` is a deep flatten, so `[[65000, [65000, 100]]]`
        # arrives as `[65000, 65000, 100]` and builds three 32-bit
        # prefixes where the caller asked for one of 96 bits. Measured on
        # 2026-10-31, by probing it. A Hash survives flatten untouched,
        # which is why every family here takes one, so this arm takes an
        # Rt_constrain or the hash Rt_constrain reads and nothing else.
        # Rt_constrain.new(65000, [65000, 100]) is still how a caller
        # builds one from field values; it just cannot travel inside
        # :nlris as a bare Array.
        @nlris = [h[:nlris]].flatten.compact.collect do |n|
          next n if n.is_a?(Rt_constrain)
          rtc = Rt_constrain.new(n)
          rtc.path_id ||= @path_id
          rtc
        end
        @afi ||= IANA::AFI::IPv4
      else
        raise "SAFI #{safi} not implemented!"
      end
      @nexthops = [h[:nexthop]].flatten.collect { |nh| nexthop_klass(afi,safi,nh).new(nh) } if h[:nexthop]
      self
    end

    # What goes where a labeled NLRI's labels go, from its hash.
    #
    # A withdrawal hashes a :compatibility key instead of :label, because
    # RFC 8277 section 2.4 puts its Compatibility field where the label
    # would be and its value is not a label. Passing *n[:label] for one of
    # those splats nil, which built an empty Label_stack and then raised
    # NoMethodError in encode: the hash of a parsed withdrawal could not
    # be built back, which is the round trip Conventions asks every class
    # to keep.
    def labels_from(n)
      return [{ :compatibility => n[:compatibility] }] if n[:compatibility]
      [n[:label]].flatten.compact
    end
    
    def to_hash
      h_afi_safi = {:safi=> @safi, :afi=>@afi}
      h_nlris = @nlris.size>1 ? @nlris.collect { |n| nlri_to_hash(n) } : nlri_to_hash(@nlris[0])
      h = if @nexthops.empty?
        h_afi_safi.merge(:nlris=>h_nlris)
      else
        h_afi_safi.merge(:nlris=>h_nlris).merge({:nexthop=>@nexthops.collect { |n| n.nexthop.to_s }} )
      end      
      h
    end
    
    def nlri_to_hash(nlri)
      if nlri.is_a?(Prefix) and ! nlri.extended?
        nlri.to_s
      else
        nlri.to_hash
      end  
    end
    private :nlri_to_hash
    
    module ClassMethods

      # How many octets the next NLRI occupies, including whatever
      # length field it carries. The Path Identifier of RFC 7911 section
      # 3 is already off the octets by the time this is asked.
      #
      # **This is a per family question and not arithmetic one loop can
      # do for every family**, which is why it is a method rather than
      # the expression it replaced. The prefix families give a length in
      # **bits**, in one octet, RFC 4271 section 4.3, so the NLRI is
      # 1+(length+7)/8 octets and both parse loops worked that out
      # themselves. Flow spec gives a length in **octets**, in one or
      # two, RFC 8955 section 4.1, so neither half of that arithmetic
      # holds and the family answers instead.
      #
      # nil when the octets cannot hold a length field at all, so a
      # caller stops rather than looping. The loops then leave the
      # octets, and Mp_reach#parse and Mp_unreach#parse raise on the
      # leftover, which is how an attribute bgp4r cannot read becomes an
      # Attr::Raw with an Attr::Gap and keeps its bytes. See #116.
      def nlri_size(s, afi, safi)
        return nil if s.nil? || s.empty?
        case safi
        when IANA::SAFI::FLOW_SPEC_RULES_1, IANA::SAFI::FLOW_SPEC_RULES_2
          Flow_spec.nlri_size(s)
        when IANA::SAFI::EVPN
          # RFC 7432 section 7: Route Type (1 octet), Length (1 octet),
          # Route Type specific. The Length counts the body alone, so an
          # NLRI is 2 + Length octets, and the family owns that
          # arithmetic the way Flow_spec owns section 4.1's.
          Evpn.nlri_size(s)
        else
          (s.getbyte(0) + 7) / 8 + 1
        end
      end

      # One NLRI of an MP_REACH or MP_UNREACH attribute. RFC 4760 sections 3
      # and 4: for SAFI 1 and 2 each NLRI is a single <length, prefix>, with
      # the Path Identifier already read when add-path is on (RFC 7911
      # section 3). Nlri.factory treats AFI 1 SAFI 1 as a whole plain NLRI
      # field and would read the Path Identifier a second time.
      # withdrawn is true only from Mp_unreach#parse: RFC 8277 section 2.4
      # replaces a withdrawn route's label with a Compatibility field, and
      # nothing in the octets says which it is. See Labeled.new_ntop.
      def nlri_ntop(s, afi, safi, path_id=nil, withdrawn=false)
        if (afi == 1 || afi == 2) && (safi == 1 || safi == 2)
          Prefix.new_ntop(s.is_packed, afi, path_id)
        else
          Nlri.factory(s, afi, safi, path_id, withdrawn)
        end
      end

      def afi_from_nlris(arg)
        case arg
        when String
          _arg = arg
        when Hash,Array
          case [arg].flatten[0]
          when Hash
            _arg = [arg].flatten[0][:prefix]
          when String
            _arg = [arg].flatten[0]
          else
            raise ArgumentError, "invalid NLRI: #{[arg].flatten[0].inspect}, expected a String or a Hash"
          end
        when Hash
          _arg = arg[:prefix]
        else
          raise ArgumentError, "invalid argument: #{arg.inspect}"
        end

        if _arg.respond_to?(:afi)
          _arg.afi
        elsif _arg =~ /^49\./
          3
        else
          IPAddr.new(_arg).ipv4? ? 1 : 2
        end
      end
    end
    
    private 
    
    def prefix_klass(afi, safi)
      case afi
      when 1,2
        _afi='Inet'
      when 3
        return ::BGP.const_get('Prefix')
      else
        raise ArgumentError, "AFI #{afi.inspect} is not supported, expected 1 (IPv4), 2 (IPv6) or 3 (NSAP)"
      end
      _safi = case safi
      when 1 ; 'unicast'
      when 2 ; 'multicast'
      else
        raise ArgumentError, "SAFI #{safi.inspect} has no prefix class, expected 1 (unicast) or 2 (multicast)"
      end
      ::BGP.const_get([_afi,_safi].join('_'))
    end
    
  end


  class Mp_reach < Attr
    
    include MpReachCommon

    attr_reader :safi, :nlris, :path_id, :afi

    def initialize(*args)
      @safi, @nexthops, @nlris, @path_id= 1, [], [], nil # default is ipv4/unicast
      @flags, @type = OPTIONAL, MP_REACH
      if args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      elsif args[0].is_a?(self.class)
        s = args.shift.encode
        parse(s, *args)
      elsif args[0].is_a?(Hash) and args.size==1
        set(*args)
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end
    end

    def nexthops
      @nexthops.collect { |nh| nh.nexthop }.join(", ")
    end

    def mp_reach
      "\n    AFI #{IANA.afi_s(afi)}, SAFI #{IANA.safi_s(safi)}" +
      "\n    nexthop: " + nexthops +
      (['']+ @nlris.collect { |nlri| nlri.to_s }).join("\n      ")
    end

    def to_s(method=:default)
      super(mp_reach, method)
    end
    def to_hash
      {:mp_reach=>super}
    end

    def parse(s,arg=false)

      @flags, @type, _, value = super(s)
      @afi, @safi, nh_len = value.slice!(0,4).unpack('nCC')

      case @afi
      when 3

        parse_iso_mapped_next_hops value.slice!(0,nh_len).is_packed
        value.slice!(0,1)

        if arg.respond_to?(:path_id?)
          path_id_flag = arg.path_id? :recv, @afi, @safi
        else
          path_id_flag = arg
        end

        while value.size>0
          path_id = value.slice!(0,4).unpack('N')[0]  if path_id_flag
          # The same question as the loop below, through the same
          # method. Flow spec never reaches this branch, since it is
          # AFI 1 and 2 and this is AFI 3, so nlri_size answers the
          # prefix arithmetic here exactly as the inline expression did.
          n = self.class.nlri_size(value, @afi, @safi)
          break if n.nil? || n <= 0
          @nlris << Nlri.factory(value.slice!(0,n), @afi, @safi, path_id)
        end

      else

        parse_next_hops value.slice!(0,nh_len).is_packed
        value.slice!(0,1)

        if arg.respond_to?(:path_id?)
          path_id_flag = arg.path_id? :recv, @afi, @safi
        else
          path_id_flag = arg
        end

        while value.size>0
          path_id = path_id_flag ? value.slice!(0,4).unpack('N')[0] : nil
          # The family says how long its NLRI is; see nlri_size. nil is
          # octets too short to hold a length field, so stop and let the
          # leftover below raise rather than loop.
          n = self.class.nlri_size(value, @afi, @safi)
          break if n.nil? || n <= 0
          @nlris << self.class.nlri_ntop(value.slice!(0,n), @afi, @safi, path_id)
        end
      end
      raise RuntimeError, "leftover afer parsing: #{value.unpack('H*')}" if value.size>0
    end
    
    def parse_iso_mapped_next_hops(s)
      raise ArgumentError, "ISO mapped next hops need AFI 3, not AFI #{@afi.inspect}" unless @afi == 3
      while s.size>0
        s.slice!(0,8) if (128..129)===@safi
        case s.slice(0,1).unpack('C')[0]
        when 0x47
          s.slice!(0,4)
          @nexthops << Iso_ip_mapped.new(Prefix.new_ntop([32,s.slice!(0,4)].pack('Ca*'),1).to_s)
        when 0x35
          s.slice!(0,3)
          @nexthops << Iso_ip_mapped.new(Prefix.new_ntop([128,s.slice!(0,16)].pack('Ca*'),2).to_s)
        else
          # RFC 4760 section 3 leaves the next hop format to the AFI. For
          # AFI 3 it is an IP address in an NSAP: IDP 0x47 (ICP 0006) for
          # IPv4 and IDP 0x35 for IPv6.
          raise ArgumentError, "unknown ISO mapped next hop, IDP 0x#{s.slice(0,1).unpack('H2')[0]}, expected 0x47 (IPv4) or 0x35 (IPv6)"
        end
        # skip magic
        s.slice!(0,1)
      end
    end
    
    def parse_next_hops(s)
      # RFC 8950 section 3: for AFI 1 the Length of Next Hop Address tells
      # the next hop type. 16 or 32 octets (SAFI 1, 2, 4), or 24 or 48
      # octets (SAFI 128, 129), is an IPv6 next hop: a global address,
      # then an optional link-local one.
      ipv6_nh = @afi == 1 && ipv6_nexthop_length?(s.size)
      while s.size>0
        case @safi
        # SAFI 133 and 134 are here because RFC 8955 section 4 says "the
        # Length of the Next-Hop Network Address MUST be set to 0. The
        # Network Address of the Next-Hop field MUST be ignored." A sender
        # that writes 0 never reaches this loop, so the only way in is a
        # sender breaking that MUST, and ignoring the field must not mean
        # refusing the attribute: before this bgp4r raised here, so a
        # flowspec UPDATE with any next hop at all came back as an
        # Attr::Raw with a Gap and its components were never read.
        # Reading it as an address rather than discarding it is what keeps
        # encode byte for byte and keeps the hash able to rebuild it, the
        # same reason a reserved field is kept and echoed elsewhere.
        # Nothing here claims RFC 8950 applies to flowspec, so
        # ipv6_nexthop_length? is left alone and a length no address fits
        # behaves as it does for every other SAFI.
        when 1,2,4,133,134
          case @afi
          when 1
            if ipv6_nh
              @nexthops << Prefix.new_ntop([128,s.slice!(0,16)].pack('Ca*'),2)
            else
              @nexthops << Prefix.new_ntop([32,s.slice!(0,4)].pack('Ca*'),1)
            end
          when 2
            @nexthops << Prefix.new_ntop([128,s.slice!(0,16)].pack('Ca*'),2)
          when 3
            raise "TBD"
          else 
            raise "SHOULD NOT BE HERE ...."
          end
        when 128,129
          if ipv6_nh
            # RD of 8 zero octets, then the IPv6 address (RFC 8950 section 3).
            @nexthops << Vpn.new([64+128,s.slice!(0,24)].pack('Ca*'), 2)
          else
            @nexthops << Vpn.new([64+32,s.slice!(0,12)].pack('Ca*'))
          end
        when IANA::SAFI::EVPN, IANA::SAFI::ROUTE_TARGET_CONSTRAINTS
          # Two families whose next hop is read by its length alone, and
          # they arrive at that from opposite directions, so both
          # sentences are here rather than one standing in for the other.
          #
          # RFC 7432 section 14: "The Next Hop field of the MP_REACH_NLRI
          # attribute of the route MUST be set to the IPv4 or IPv6
          # address of the advertising PE." **For EVPN the length says
          # which because the AFI cannot.** For SAFI 1 and 2 the AFI is 1
          # or 2 and the case above reads it off that; EVPN's AFI is 25
          # for both families, so the only thing telling an IPv4 next hop
          # from an IPv6 one is a field of 4 octets or 16.
          #
          # RFC 4684 section 4: the field "shall be interpreted as an
          # IPv4 address whenever the length of NextHop address is 4
          # octets, and as a IPv6 address whenever the length of the
          # NextHop address is 16 octets." **For RT-constrain the AFI
          # could have said, and the RFC says to use the length anyway.**
          # Its AFI is 1, so the case above would have read every next
          # hop as IPv4 and a 16-octet field as four of them. Do not read
          # the 16-octet half as RFC 8950 arriving at the same answer:
          # ipv6_nexthop_length? answers false for SAFI 132, nothing
          # claims RFC 8950 applies here, and section 4 is first hand.
          #
          # So ipv6_nexthop_length? is left alone for both. A field too
          # short for either reads as IPv4 and Prefix pads it out, which
          # is exactly what SAFI 1 already does with a short next hop.
          # Consistent with the library rather than a new rule, and it
          # ends the loop either way.
          if s.size >= 16
            @nexthops << Prefix.new_ntop([128,s.slice!(0,16)].pack('Ca*'),2)
          else
            @nexthops << Prefix.new_ntop([32,s.slice!(0,4)].pack('Ca*'),1)
          end
        else
          raise RuntimeError, "cannot parse nexthop for safi #{@safi}"
        end
      end
    end

    def ipv6_nexthop_length?(len)
      case @safi
      when 1,2,4     ; len == 16 || len == 32
      when 128,129   ; len == 24 || len == 48
      else
        false
      end
    end
    
    def encode(what=:mp_reach)
      case what
      when :mp_reach
        nexthops = @nexthops.collect { |nh| nh.encode_next_hop(safi) }.join
        nlris =  @nlris.collect { |n| n.encode }.join
        super([afi, @safi, nexthops.size, nexthops, 0, nlris ].pack('nCCa*Ca*'))
      when :mp_unreach
        super([afi, @safi, @nlris.collect { |n| n.encode }.join].pack('nCa*'))
      end
    end
    
    def new_unreach
      s = encode(:mp_unreach)
      s[1]= [MP_UNREACH].pack('C')
      Mp_unreach.new(s)
    end
    
    private
    
    def nexthop_klass(afi, safi, nh)
      case afi
      when 3
        ::BGP::const_get('Iso_ip_mapped')
      else
        case safi
        when 1,2,4
          if afi==2 &&  IPAddr.new(nh).ipv4?
            ::BGP::const_get('Ipv4_mapped')
          else
            ::BGP::const_get('Prefix')
          end
        when 128,129
          ::BGP::const_get('Vpn')
        when IANA::SAFI::EVPN, IANA::SAFI::ROUTE_TARGET_CONSTRAINTS
          # RFC 7432 section 14 wants the advertising PE's own IPv4 or
          # IPv6 address and RFC 4684 section 4 takes either too, so
          # this is an ordinary Prefix and the address the caller gave
          # decides the family. No Ipv4_mapped branch as SAFI 1 and 2
          # have: that one exists because an IPv4 next hop under AFI 2
          # is written as an IPv4-mapped IPv6 address, and neither of
          # these families writes one. EVPN's AFI is 25 either way, and
          # RT-constrain's is 1 while still taking an IPv6 next hop,
          # which is section 4's own sentence and not AFI 2.
          ::BGP::const_get('Prefix')
        when 133,134
          # RFC 8955 section 4 wants the length set to 0, so a flowspec
          # MP_REACH is normally built with no :nexthop at all and encode
          # writes 0 on its own. One given anyway is honoured rather than
          # refused: Conventions says building never validates, because
          # putting a field on the wire that the RFC forbids is the
          # negative test the library exists for.
          ::BGP::const_get('Prefix')
        else
          raise ArgumentError, "no next hop class for AFI #{afi.inspect} SAFI #{safi.inspect}"
        end
      end
    end
    
  end

  Attr.register(ATTR::MP_REACH, Mp_reach, :mp_reach, session: :path_id)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
