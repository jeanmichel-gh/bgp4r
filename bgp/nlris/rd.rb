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


require 'bgp/common'
module BGP
  class Rd
    attr_reader :admin, :assign
    def bit_length ; 64 ; end
    def initialize(*args)
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args.empty?
        @enc_type, @admin, @assign = [0]*3
      elsif args.size==3
        admin, assign, @enc_type = args
        refuse_an_address_as_an_assigned_number(assign)
        refuse_a_value_too_wide_for_its_field('encoding type', @enc_type, 2)
        case @enc_type
        when 1
          @admin, @assign = IPAddr.new(admin), assign
        else
          # Types 0 and 2, and any type RFC 4364 section 4.2 does not
          # define: two Integers in the field widths that type gives them.
          refuse_a_value_too_wide_for_its_field('administrator', admin, admin_width)
          @admin, @assign = admin, assign
        end
        refuse_a_value_too_wide_for_its_field('assigned number', assign, assign_width)
      elsif args.size==2
        admin, assign = args
        refuse_an_address_as_an_assigned_number(assign)
        if admin.is_a?(String)
          @admin, @assign, @enc_type = IPAddr.new(admin), assign, 1
        else
          @admin, @assign, @enc_type = admin, assign, inferred_encoding_type(admin)
          refuse_a_value_too_wide_for_its_field('administrator', admin, admin_width)
        end
        refuse_a_value_too_wide_for_its_field('assigned number', assign, assign_width)
      elsif args.size==1 and args[0].is_a?(Hash)
        # assuming Rd.new :rd=> [100,100], or :rd=> [1,257,2] when the two
        # values do not say which encoding type they came from. See to_hash.
        parse(Rd.new(*args[0][:rd]).encode)
      end
    end

    # A hash that round trips through new. The two values cannot always say
    # which encoding type they came from: [1, 257] is a type 0 to the two
    # argument form, so a type 2 RD came back as a type 0 with its
    # administrator truncated by encode. The type goes in as a third
    # element, which feeds the three argument form, and only when a build
    # from the two values would infer a different one. An RD whose values
    # say all there is to say has no third element, so the hash of an
    # ordinary RD is the two element one it has always been, the hashes
    # callers write by hand mean what they always meant, and Vpn#to_hash
    # and Labeled#to_hash go on merging one :rd key into their own. That is
    # how Extended_community::TYPE_KEY carries a type octet the values
    # cannot reproduce, and the reason is the same.
    def to_hash
      rd = [@admin.is_a?(IPAddr) ? @admin.to_s : @admin, @assign]
      rd << @enc_type unless @enc_type == hash_encoding_type
      {:rd=> rd}
    end

    def encode
      case @enc_type
      when 0
        [@enc_type, @admin, @assign].pack('nnN')
      when 1
        [@enc_type, @admin.hton, @assign].pack('na*n')
      else
        # Type 2, and any type RFC 4364 section 4.2 does not define: see
        # parse. The type field used to fall through this case with no
        # else, so encode returned nil and an undefined type could not be
        # put on the wire at all.
        [@enc_type, @admin, @assign].pack('nNn')
      end
    end

    def parse(s)
      case s[0,2].unpack('n')[0]
      when 0
        @enc_type, @admin, @assign = s.unpack('nnN')
      when 1
        @enc_type, admin, @assign = s.unpack('na4n')
        @admin = IPAddr.new_ntoh(admin)
      else
        # RFC 4364 section 4.2 gives the RD a 2 octet type field and a
        # 6 octet value field, and defines three types: type 0 is a 2 octet
        # AS administrator and a 4 octet assigned number, type 1 a 4 octet
        # IP administrator and a 2 octet assigned number, type 2 a 4 octet
        # AS administrator and a 2 octet assigned number. The IANA Route
        # Distinguisher Type Field registry leaves 3 to 65534 unassigned and
        # gives 65535 to RFC 7524, for use only in certain Leaf A-D routes.
        #
        # The structure of the value field of a type the RFC does not define
        # is not known here, so it is read the way type 2 is. 2 + 4 + 2 is
        # the whole RD, so no octet is interpreted away: encode gives back
        # what arrived, byte for byte. This used to raise, so octets that a
        # router sent could not be read back at all.
        @enc_type, @admin, @assign = s.unpack('nNn')
      end
    end

    def to_s(verbose=true)
      if verbose
        case @enc_type
        # RFC 4364 section 4.2: type 0 is a 2 octet administrator and a
        # 4 octet assigned number, so print the administrator first.
        when 0 ; format "RD=%d:%d (0x%02x 0x%04x)", @admin, @assign, @admin, @assign
        when 1 ; format "RD=%s:%d (0x%04x 0x%02x)", @admin, @assign, @admin.to_i, @assign
        when 2 ; format "RD=%d:%d (0x%04x 0x%02x)", @admin, @assign, @admin, @assign
        else
          # A type the RFC does not define says so, so its two fields are
          # not read as a type 2's.
          format "RD=%d:%d (type %d, 0x%04x 0x%02x)", @admin, @assign, @enc_type, @admin, @assign
        end
      else
        case @enc_type
        when 1 ; format "RD=%s:%d", @admin, @assign
        else   ; format "RD=%d:%d", @admin, @assign
        end
      end
    end

    def encoding_type?
      @enc_type
    end

    private

    # RFC 4364 section 4.2 makes the assigned number a 4 octet field in
    # encoding type 0 and a 2 octet field in types 1 and 2. None of them
    # holds a 32 bit address, so an address String is refused here rather
    # than kept and silently truncated by encode. Nothing else is checked:
    # any value that fits its field goes to the wire as given, whatever the
    # RFC says it should mean, and arbitrary octets still go through
    # Rd.new(wire).
    def refuse_an_address_as_an_assigned_number(assign)
      return unless assign.is_a?(String)
      raise ArgumentError, "an RD assigned number cannot be the address " +
        "#{assign.inspect}: RFC 4364 section 4.2 makes it a 2 octet field in " +
        "encoding types 1 and 2, and a 4 octet field in type 0. Pass an Integer, " +
        "or build the octets with Rd.new(wire)."
    end

    # An Integer too large for the field it goes in cannot be represented at
    # all: encode would put its low octets on the wire and the object would
    # disagree with its own bytes, which is sending a different value
    # silently. So it is refused, as an address assigned number is. Only
    # what cannot be represented is refused; a value that fits is never
    # looked at again.
    def refuse_a_value_too_wide_for_its_field(what, value, octets)
      return unless value.is_a?(Integer)
      return if value >= 0 and value <= (1 << (8*octets)) - 1
      raise ArgumentError, "an RD #{what} cannot be #{value}: RFC 4364 " +
        "section 4.2 makes it a #{octets} octet field here. Name an encoding " +
        "type whose field is wide enough, or build the octets with Rd.new(wire)."
    end

    # The encoding type the two argument form infers from an Integer
    # administrator. RFC 4364 section 4.2 makes the type 0 administrator a
    # 2 octet AS and the type 2 one a 4 octet AS, so an AS above 65535 is
    # what type 2 is for: it is inferred rather than kept in a field that
    # cannot hold it.
    def inferred_encoding_type(admin)
      admin.is_a?(Integer) && admin > 0xffff ? 2 : 0
    end

    # The encoding type a build from the two values of the hash form gives
    # back, which is what the two argument form infers. to_hash carries the
    # type only when this is not the type the RD has.
    def hash_encoding_type
      @admin.is_a?(IPAddr) ? 1 : inferred_encoding_type(@admin)
    end

    # The width in octets of each field, per RFC 4364 section 4.2. A type
    # the RFC does not define is read and written the way type 2 is, so it
    # has type 2's widths.
    def admin_width
      @enc_type == 0 ? 2 : 4
    end

    def assign_width
      @enc_type == 0 ? 4 : 2
    end

  end
end
load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
