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

require 'ipaddr'

module BGP

  # The RPKI to Router protocol, RTR: RFC 8210 (version 1) and RFC 6810
  # (version 0). A cache sends a router the Validated ROA Payloads (VRPs)
  # that RFC 6811's origin validation reads. docs/design/bgp-operations.md
  # section 7, pull request 7a.
  #
  # Every PDU of RFC 8210 section 5 is a class here, each built four
  # ways, as every codec in bgp4r is:
  #
  #   Rtr::Ipv4_prefix.new(:prefix => '10.0.0.0/8', :max_length => 24, :asn => 65001)
  #   Rtr::Ipv4_prefix.new(octets)          # from the wire
  #   Rtr::Ipv4_prefix.new(other)           # from another instance
  #   Rtr::Ipv4_prefix.new(pdu.to_hash)     # from its own hash
  #
  # `Rtr::Pdu.factory(octets)` picks the class from the PDU Type, and a
  # type it does not know is an `Unknown`, kept whole. Nothing here
  # checks what it reads: `Rtr::Validation` does, and building never
  # checks, so a test can build any PDU at all.
  module Rtr

    # RFC 8210 section 5.1: "An 8-bit unsigned integer, currently 1".
    # RFC 6810 is version 0.
    VERSION = 1
    VERSIONS = [0, 1].freeze

    # Section 9: "a port, rpki-rtr (323)".
    PORT = 323

    # The 8 octets every PDU starts with: version, type, a 16-bit field
    # (Session ID, Error Code, Flags and zero, or zero) and the Length of
    # the whole PDU.
    HEADER = 8

    # Section 12, the Error Codes, and whether each is fatal.
    ERRORS = {
      0 => ['Corrupt Data', true],
      1 => ['Internal Error', true],
      2 => ['No Data Available', false],
      3 => ['Invalid Request', true],
      4 => ['Unsupported Protocol Version', true],
      5 => ['Unsupported PDU Type', true],
      6 => ['Withdrawal of Unknown Record', true],
      7 => ['Duplicate Announcement Received', true],
      8 => ['Unexpected Protocol Version', true],
    }.freeze

    def self.error_name(code) ; (ERRORS[code] || ["code #{code}"]).first ; end

    # Whole PDUs off the front of a buffer: [pdus, what is left]. A PDU
    # whose Length is not all there yet stays in what is left, which is
    # how a stream reader uses it. A Length below 8 cannot be stepped
    # over, so the rest is returned as one Unknown with what it holds.
    def self.pdus(buffer)
      list, rest = slices(buffer)
      [list.collect { |o| o.unpack1('@4N') < HEADER ? Unknown.new(o) : Pdu.factory(o) }, rest]
    end

    # The same as pdus, each PDU as its own octets, as they came. **This
    # is what a reader validates**: a PDU parsed and encoded again has
    # the Length its type should have, so a Length that is wrong, the
    # octets past the fields included, would never be seen
    # (Fault::RTR's rtr_corrupt_length).
    def self.slices(buffer)
      buffer = buffer.b
      list = []
      while buffer.bytesize >= HEADER
        length = buffer.unpack1('@4N')
        if length < HEADER
          list << buffer
          return [list, ''.b]
        end
        break if buffer.bytesize < length
        list << buffer.byteslice(0, length)
        buffer = buffer.byteslice(length..)
      end
      [list, buffer]
    end

    # What every PDU shares: the version, the type, and the four ways to
    # build one. A subclass names TYPE, its fields and their packing.
    class Pdu
      attr_accessor :version

      # The classes by PDU Type, filled as each class is defined.
      TYPES = {}

      def self.factory(octets)
        type = octets.getbyte(1)
        (TYPES[type] || Unknown).new(octets)
      end

      def self.type(n)
        const_set(:TYPE, n)
        TYPES[n] = self
      end

      def initialize(*args)
        @version = VERSION
        arg = args.first
        if args.size == 1 && arg.is_a?(String)
          parse(arg.b)
        elsif args.size == 1 && arg.is_a?(self.class)
          parse(arg.encode)
        elsif args.size == 1 && arg.is_a?(Hash)
          h = arg.key?(hash_key) ? arg[hash_key] : arg
          @version = h[:version] if h.key?(:version)
          from_hash(h)
        else
          from_fields(*args)
        end
      end

      def type ; self.class::TYPE ; end

      # The name a Hash of this PDU is keyed by, :serial_notify and the
      # rest.
      def hash_key ; self.class.name.split('::').last.downcase.to_sym ; end

      def encode
        body = encode_body
        [@version, type, field16].pack('CCn') + [HEADER + body.bytesize].pack('N') + body
      end

      def to_hash ; { hash_key => { :version => @version }.merge(hash_fields) } ; end

      def to_shex ; encode.unpack1('H*') ; end

      def ==(other) ; other.is_a?(Pdu) && other.encode == encode ; end

      def to_s
        "RTR #{self.class.name.split('::').last.tr('_', ' ')} (#{type}), version #{@version}, " \
          "length #{encode.bytesize}: #{hash_fields.collect { |k, v| "#{k} #{v}" }.join(', ')}"
      end

      private

      def parse(s)
        @version, _type, f16, _length = s.unpack('CCnN')
        parse_body(f16, s.byteslice(HEADER..) || ''.b)
      end

      # The 16-bit field after the type, zero unless a class says.
      def field16 ; 0 ; end
      def from_fields(*) ; end
      def from_hash(_h) ; end
      def hash_fields ; {} ; end
      def encode_body ; ''.b ; end
      def parse_body(_f16, _body) ; end
    end

    # Sections 5.2 and 5.3: a Session ID and a Serial Number.
    class Serial_pdu < Pdu
      attr_accessor :session_id, :serial

      private

      def from_fields(session_id = 0, serial = 0) ; @session_id, @serial = session_id, serial ; end
      def from_hash(h) ; from_fields(h[:session_id] || 0, h[:serial] || 0) ; end
      def hash_fields ; { :session_id => @session_id, :serial => @serial } ; end
      def field16 ; @session_id ; end
      def encode_body ; [@serial].pack('N') ; end
      def parse_body(f16, body) ; @session_id, @serial = f16, body.unpack1('N') ; end
    end

    # Section 5.2: "The cache notifies the router that the cache has new
    # data."
    class Serial_notify < Serial_pdu ; type 0 ; end

    # Section 5.3: the router asks for the changes since a Serial Number.
    class Serial_query < Serial_pdu ; type 1 ; end

    # Section 5.4: the router asks for the whole database.
    class Reset_query < Pdu ; type 2 ; end

    # Section 5.5: the start of an answer, with the cache's Session ID.
    class Cache_response < Pdu
      type 3
      attr_accessor :session_id

      private

      def from_fields(session_id = 0) ; @session_id = session_id ; end
      def from_hash(h) ; @session_id = h[:session_id] || 0 ; end
      def hash_fields ; { :session_id => @session_id } ; end
      def field16 ; @session_id ; end
      def parse_body(f16, _body) ; @session_id = f16 ; end
    end

    # Sections 5.6 and 5.7: one VRP. Flags bit 0 is 1 for an
    # announcement and 0 for a withdrawal.
    class Prefix_pdu < Pdu
      attr_accessor :flags, :prefix_length, :max_length, :address, :asn

      # The prefix as 'address/length'.
      def prefix ; "#{@address}/#{@prefix_length}" ; end
      def announce? ; @flags & 1 == 1 ; end

      # The {Prefix, Len, Max-Len, ASN} tuple RFC 8210 names a VRP by.
      def key ; [@address, @prefix_length, @max_length, @asn] ; end

      private

      # (prefix, max_length, asn, announce = true)
      def from_fields(prefix = nil, max_length = nil, asn = 0, announce = true)
        from_hash(:prefix => prefix || zero_prefix, :max_length => max_length, :asn => asn,
                  :flags => announce ? 1 : 0)
      end

      def from_hash(h)
        address, length = (h[:prefix] || zero_prefix).to_s.split('/')
        @address = IPAddr.new(address).to_s
        @prefix_length = (length || bits).to_i
        @max_length = h[:max_length] || @prefix_length
        @asn = h[:asn] || 0
        @flags = h.key?(:flags) ? h[:flags] : 1
      end

      def hash_fields
        { :flags => @flags, :prefix => prefix, :max_length => @max_length, :asn => @asn }
      end

      def encode_body
        [@flags, @prefix_length, @max_length, 0].pack('CCCC') + IPAddr.new(@address).hton + [@asn].pack('N')
      end

      def parse_body(_f16, body)
        @flags, @prefix_length, @max_length = body.unpack('CCC')
        octets = bits / 8
        @address = IPAddr.new_ntoh(body.byteslice(4, octets).ljust(octets, "\0")).to_s
        @asn = body.byteslice(4 + octets, 4).to_s.ljust(4, "\0").unpack1('N')
      end
    end

    class Ipv4_prefix < Prefix_pdu
      type 4
      private
      def bits ; 32 ; end
      def zero_prefix ; '0.0.0.0/0' ; end
    end

    class Ipv6_prefix < Prefix_pdu
      type 6
      private
      def bits ; 128 ; end
      def zero_prefix ; '::/0' ; end
    end

    # Section 5.8. Version 1 carries the three intervals of section 6;
    # version 0 (RFC 6810 section 5.7) ends at the Serial Number, so a
    # version 0 End of Data has none and is 12 octets long.
    class End_of_data < Pdu
      type 7
      attr_accessor :session_id, :serial, :refresh, :retry, :expire

      # Section 6's defaults: "Default: 3600", "Default: 600", "Default:
      # 7200".
      REFRESH = 3600
      RETRY = 600
      EXPIRE = 7200

      private

      def from_fields(session_id = 0, serial = 0, refresh = REFRESH, retry_ = RETRY, expire = EXPIRE)
        @session_id, @serial, @refresh, @retry, @expire = session_id, serial, refresh, retry_, expire
      end

      def from_hash(h)
        from_fields(h[:session_id] || 0, h[:serial] || 0, h[:refresh] || REFRESH, h[:retry] || RETRY, h[:expire] || EXPIRE)
      end

      def hash_fields
        h = { :session_id => @session_id, :serial => @serial }
        @version.zero? ? h : h.merge(:refresh => @refresh, :retry => @retry, :expire => @expire)
      end

      def field16 ; @session_id ; end

      def encode_body
        @version.zero? ? [@serial].pack('N') : [@serial, @refresh, @retry, @expire].pack('NNNN')
      end

      def parse_body(f16, body)
        @session_id = f16
        @serial, @refresh, @retry, @expire = body.ljust(16, "\0").unpack('NNNN')
        @refresh, @retry, @expire = nil if body.bytesize < 16
      end
    end

    # Section 5.9: the cache cannot answer a Serial Query incrementally.
    class Cache_reset < Pdu ; type 8 ; end

    # Section 5.10, version 1 only: a BGPsec router key. Flags in the
    # first octet of the 16-bit field, then zero.
    class Router_key < Pdu
      type 9
      attr_accessor :flags, :ski, :asn, :spki

      def announce? ; @flags & 1 == 1 ; end

      private

      # (ski, asn, spki, announce = true): the SKI is 20 octets, the
      # Subject Public Key Info any number.
      def from_fields(ski = "\0" * 20, asn = 0, spki = '', announce = true)
        @ski, @asn, @spki, @flags = ski.b, asn, spki.b, announce ? 1 : 0
      end

      def from_hash(h)
        @ski = [h[:ski] || '00' * 20].pack('H*')
        @spki = [h[:spki] || ''].pack('H*')
        @asn = h[:asn] || 0
        @flags = h.key?(:flags) ? h[:flags] : 1
      end

      def hash_fields
        { :flags => @flags, :ski => @ski.unpack1('H*'), :asn => @asn, :spki => @spki.unpack1('H*') }
      end

      def field16 ; @flags << 8 ; end
      def encode_body ; @ski.byteslice(0, 20).ljust(20, "\0") + [@asn].pack('N') + @spki ; end

      def parse_body(f16, body)
        @flags = f16 >> 8
        @ski = body.byteslice(0, 20).to_s
        @asn = body.byteslice(20, 4).to_s.ljust(4, "\0").unpack1('N')
        @spki = body.byteslice(24..) || ''.b
      end
    end

    # Section 5.11: an error, the PDU it is about, and text.
    class Error_report < Pdu
      type 10
      attr_accessor :code, :pdu, :text

      def name ; Rtr.error_name(@code) ; end
      def fatal? ; (ERRORS[@code] || [nil, true]).last ; end

      private

      # (code, pdu = '', text = ''): pdu is the erroneous PDU, as octets
      # or as a Pdu.
      def from_fields(code = 0, pdu = '', text = '')
        @code = code
        @pdu = (pdu.is_a?(Pdu) ? pdu.encode : pdu).b
        @text = text.to_s
      end

      def from_hash(h) ; from_fields(h[:code] || 0, [h[:pdu] || ''].pack('H*'), h[:text] || '') ; end

      def hash_fields ; { :code => @code, :pdu => @pdu.unpack1('H*'), :text => @text } ; end

      def field16 ; @code ; end

      def encode_body
        text = @text.b
        [@pdu.bytesize].pack('N') + @pdu + [text.bytesize].pack('N') + text
      end

      # Lengths that overrun are read as far as the octets go;
      # Rtr::Validation says so.
      def parse_body(f16, body)
        @code = f16
        n = body.unpack1('N').to_i
        @pdu = body.byteslice(4, n) || ''.b
        rest = body.byteslice(4 + @pdu.bytesize..) || ''.b
        @text = (rest.byteslice(4, rest.unpack1('N').to_i) || '').dup.force_encoding('UTF-8')
      end
    end

    # A PDU Type this code does not know, kept as it came, so it goes out
    # again unchanged.
    class Unknown < Pdu
      attr_reader :octets

      def type ; @octets.getbyte(1) ; end
      def encode ; @octets ; end
      def hash_fields ; { :octets => @octets.unpack1('H*') } ; end

      private

      # (type, version = 1, field16 = 0, body = ''): a PDU of any type.
      def from_fields(type = 255, version = VERSION, f16 = 0, body = '')
        @version = version
        @octets = [version, type, f16].pack('CCn') + [HEADER + body.bytesize].pack('N') + body.b
      end

      def from_hash(h) ; @octets = [h[:octets] || ''].pack('H*') ; end
      def parse(s) ; @octets = s ; @version = s.getbyte(0) ; end
    end
  end
end
