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

module BGP

class UnknownBgpCapability < RuntimeError
end

module OPT_PARM

  unless const_defined? :CAPABILITY
    CAPABILITY = 2

    CAP_MBGP = 1
    CAP_ROUTE_REFRESH = 2
    CAP_ORF = 3
    CAP_EXTENDED_NEXTHOP = 5 # RFC 8950 section 4
    CAP_ROLE = 9 # RFC 9234 section 4.1
    CAP_GR  = 64
    CAP_AS4 = 65
    CAP_DYNAMIC = 67
    CAP_ADD_PATH = 69
    CAP_ENHANCED_ROUTE_REFRESH = 70 # RFC 7313 section 3.1
    CAP_ROUTE_REFRESH_CISCO = 128
    CAP_ORF_CISCO = 130

    ORF_NLRI = 1
    ORF_COMMUNITIES = 2
    ORF_EXTENDED_COMMUNITIES = 3
    ORF_PREFIX_LIST = 129
  end

  class Optional_parameter

    def initialize(parm_type)
      @parm_type=parm_type
    end

    # A one octet Parameter Type and a one octet Parameter Length
    # (RFC 4271 section 4.2), or the same type octet and a two octet
    # length when the enclosing OPEN uses the extended form of RFC 9072
    # section 2, Figure 2 "Extended Parameters Format": "The rules for
    # encoding Optional Parameters are unchanged with respect to those
    # given in [RFC4271], except that the Parameter Length field is
    # extended to be a two-octet unsigned integer."
    #
    # Which form is in use is a property of the enclosing OPEN and not
    # of the parameter, so Open#encode decides and passes it down. A
    # parameter encoded on its own is in the RFC 4271 form, as it has
    # always been.
    def encode(value, extended: false)
      if extended
        [@parm_type, value.size, value].pack('Cna*')
      else
        [@parm_type, value.size, value].pack('CCa*')
      end
    end

    def parse(s)
      @parm_type, len = s.slice!(0,2).unpack('CC')
      s.slice!(0,len).is_packed
    end

    # The size of the parameter header: two octets, or three in the
    # RFC 9072 section 2 extended form, where the Parameter Length is
    # two octets.
    def self.header_size(extended)
      extended ? 3 : 2
    end

    # The capabilities in the next optional parameter, as an Array. One
    # parameter can hold more than one capability, so this returns a
    # list rather than a single object.
    #
    # extended is true when the enclosing OPEN carries the RFC 9072
    # section 2 Extended Optional Parameters Length, in which case this
    # parameter's Length field is two octets wide, not one.
    def self.factory(s, extended: false)
      hdr = header_size(extended)
      parm_type, len = extended ? s.unpack('Cn') : s.unpack('CC')
      # RFC 4271 section 4.2 gives an optional parameter a 1 octet
      # Parameter Type and a 1 octet Parameter Length, and RFC 9072
      # section 2 widens the length to two, so fewer octets than that are
      # not a parameter: there is no Length to read and len is nil. nil
      # says so and leaves the octets where they are, for Open to keep as
      # its tail. len+hdr used to raise NoMethodError here and take the
      # parse of the whole OPEN with it.
      return nil if len.nil?
      # Two kinds of parameter cannot be read as a capability list, and
      # both are kept rather than dropped, the way an ORF type bgp4r does
      # not implement has been kept since #101.
      #
      # A Parameter Type other than CAPABILITY, which is every type the
      # IANA "BGP OPEN Optional Parameter Types" registry has: 0
      # Reserved, 1 Authentication (Deprecated, referencing RFC 4271 and
      # RFC 5492), 3 to 254 Unassigned, and 255 reserved for the extended
      # length of RFC 9072. A peer may well send 1, and a negative test
      # wants to send any of them. This used to raise and take the parse
      # of the whole OPEN with it, including the parameters that had
      # already been read.
      #
      # And a Parameter Length longer than the octets behind it, whatever
      # the type says, because there is no value to read. That used to
      # slice what was there, find no whole capability in it and leave
      # nothing, so encode wrote an Optional Parameters Length of 0 and
      # the octets that arrived were gone.
      if parm_type != CAPABILITY or len > s.size - hdr
        return [Unknown.new(s.slice!(0, [len + hdr, s.size].min).is_packed, extended)]
      end
      opt_parm = s.slice!(0,len+hdr).is_packed
      capabilities(opt_parm, :extended => extended)
    end

    # RFC 5492 section 4: a Capabilities optional parameter carries one
    # or more capabilities, each a one octet code, a one octet length,
    # and that many value octets. GoBGP packs several into one
    # parameter; bgp4r sends one each. Both have to be read, and reading
    # only the first used to drop the rest in silence: against a peer
    # that packed 4-octet AS after another capability, bgp4r missed it,
    # kept the 2-octet default and sent an AS_PATH the peer could not
    # parse.
    #
    # Each capability is handed to Capability.factory wrapped in a
    # parameter header of its own, which is the shape that method takes.
    # That wrapper is always the RFC 4271 two octet header, whatever the
    # enclosing OPEN used, because it never reaches the wire: the
    # capability objects read it back through Optional_parameter#parse,
    # and Open#encode applies the form the message needs again when it
    # writes them out. Only the real parameter header this method skips
    # grows to three octets in the extended form.
    def self.capabilities(opt_parm, extended: false)
      hdr = header_size(extended)
      value = opt_parm.byteslice(hdr, opt_parm.size - hdr).to_s
      caps, i = [], 0
      while i + 2 <= value.size
        len = value.getbyte(i + 1)
        break if i + 2 + len > value.size
        tlv = value.byteslice(i, 2 + len)
        caps << Capability.factory(([CAPABILITY, tlv.size].pack('CC') + tlv).is_packed)
        i += 2 + len
      end
      caps
    end

    # One entry of an OPEN's :capabilities list, back into an object.
    #
    # That list is not only capabilities since #154: an
    # Optional_parameter::Unknown hashes into it too, and the two are told
    # apart by their key. A capability hashes :code, from the RFC 5492
    # section 4 Capability Code; an unreadable parameter hashes :type,
    # from the RFC 4271 section 4.2 Parameter Type. Nothing else shares
    # the list, so this is the whole dispatch.
    def self.from_hash(h)
      raise ArgumentError, "not a Hash: #{h.inspect}" unless h.is_a?(Hash)
      return Unknown.new(h) if h.key?(:type)
      return Capability.from_hash(h) if h.key?(:code)
      raise ArgumentError, "neither :type nor :code in #{h.inspect}"
    end

    # An optional parameter bgp4r cannot read, kept whole so that encode
    # gives back what arrived. Shaped on Capability::Unknown, which does
    # the same one level down, and on Orf::Unknown, which keeps the
    # Length that arrived as well.
    #
    # Builds three ways, like everything else here: from field values
    # (type, value), from a hash, and from its wire bytes. Those wire
    # bytes are the RFC 4271 section 4.2 form by default and the RFC 9072
    # section 2 form when a second argument says so, because the width of
    # the Parameter Length field belongs to the enclosing OPEN rather
    # than to the parameter.
    class Unknown < Optional_parameter

      attr_reader :value, :declared_len

      # The wire build path takes the header form as a second argument,
      # true for the three octet one of RFC 9072 section 2. A keyword
      # would read better, but a keyword parameter on initialize makes
      # Ruby 3 take a bare hash as keywords, and every other class here
      # builds from a bare hash.
      def initialize(*args)
        @value = String.new
        if (1..2).include?(args.size) and args[0].is_a?(String) and args[0].is_packed?
          super(nil)
          parse(args[0], args[1] ? true : false)
        elsif args.size == 1 and args[0].is_a?(Unknown)
          super(nil)
          parse(args[0].encode.is_packed, false)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          super(h[:type].to_i)
          @value = [h[:value].to_s].pack('H*')
          @declared_len = h[:length].to_i if h[:length]
        elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
          super(args[0])
          @value = args[1].to_s.b
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, " \
                               "expected (type, value), wire bytes or a hash"
        end
      end

      def parse(s, extended = false)
        hdr = self.class.header_size(extended)
        @parm_type, len = extended ? s.unpack('Cn') : s.unpack('CC')
        @value = s.byteslice(hdr, s.size - hdr).to_s.b
        # Only kept when it disagrees with the octets that followed it, so
        # a parameter whose length was right encodes from its value and
        # carries no extra hash key.
        @declared_len = len if len != @value.size
      end

      # The length that arrived when it did not agree with the value, so a
      # malformed parameter a negative test captured can be sent again.
      # Optional_parameter#encode always writes the value's own size,
      # which is right for every other parameter and wrong for this one.
      def encode(extended: false)
        len = @declared_len || @value.size
        [@parm_type, len, @value].pack(extended ? 'Cna*' : 'CCa*')
      end

      def parm_type ; @parm_type ; end

      # No disagreeing length means no :length key, so the hash of an
      # ordinary unreadable parameter is the two entries it needs.
      def to_hash
        h = { :type => @parm_type }
        h[:value] = @value.unpack('H*')[0] unless @value.empty?
        h[:length] = @declared_len if @declared_len
        h
      end

      def to_s
        s = "Unknown Optional Parameter (#{@parm_type}), " \
            "#{@value.size} value octet#{@value.size == 1 ? '' : 's'}: " \
            "[#{@value.unpack('H*')[0]}]"
        s += ", Parameter Length says #{@declared_len}" if @declared_len
        s
      end

    end

  end
end
end