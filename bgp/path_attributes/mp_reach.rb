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
      @afi = h[:afi] || self.class.afi_from_nlris(h[:nlris])
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
          blen = value.slice(0,1).unpack('C')[0]
          nlri = Nlri.factory(value.slice!(0,(blen+7)/8+1), @afi, @safi, path_id)
          # nlri = Nsap.new_ntoh(value.slice!(0,(blen+7)/8+1))
          @nlris << nlri
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
          blen = value.slice(0,1).unpack('C')[0]
          @nlris << self.class.nlri_ntop(value.slice!(0,(blen+7)/8+1), @afi, @safi, path_id)
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
        when 1,2,4
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
        else
          raise ArgumentError, "no next hop class for AFI #{afi.inspect} SAFI #{safi.inspect}"
        end
      end
    end
    
  end

  Attr.register(ATTR::MP_REACH, Mp_reach, :mp_reach, session: :path_id)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
