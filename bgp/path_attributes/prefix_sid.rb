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

require 'bgp/path_attributes/attribute'

module BGP

  # BGP Prefix-SID, attribute 40, RFC 8669: an optional transitive
  # attribute holding TLVs.
  #
  #   Prefix_sid.new(Prefix_sid::Label_index.new(100))
  #   Prefix_sid.new(Prefix_sid::Label_index.new(100),
  #                  Prefix_sid::Originator_srgb.new([16000, 1000]))
  #   Prefix_sid.new(:label_index => 100, :srgb => [[16000, 1000]])
  #   Prefix_sid.new(wire_bytes)
  #
  # TLVs keep their order, and one bgp4r does not know is kept as it came
  # (RFC 8669 section 3: unknown TLVs are ignored and propagated
  # unmodified). Nothing is checked when building, so a test can send a
  # TLV of any length.
  class Prefix_sid < Attr

    # RFC 8669 section 7, Table 1.
    LABEL_INDEX     = 1
    DEPRECATED_TLV  = 2
    ORIGINATOR_SRGB = 3

    # A TLV bgp4r does not know, kept byte for byte.
    class Tlv
      attr_reader :type, :value

      def initialize(type, value = ''.b)
        @type, @value = type, value.to_s.b
      end

      # RFC 8669 section 3: type (1 octet), length (2 octets), value.
      def encode
        [@type, @value.size].pack('Cn') + @value
      end

      def to_s
        format('TLV type %d: %s', @type, @value.unpack1('H*'))
      end

      def to_hash
        { :type => @type, :value => @value.unpack1('H*') }
      end

      def ==(other)
        other.is_a?(Tlv) and other.type == @type and other.value == @value
      end
    end

    # RFC 8669 section 3.1: reserved (1 octet), flags (2 octets),
    # label index (4 octets). The length is always 7.
    class Label_index < Tlv
      attr_reader :label_index, :flags, :reserved

      def initialize(arg, flags: 0, reserved: 0)
        if arg.is_a?(String)
          @reserved, @flags, @label_index = arg.unpack('CnN')
          super(LABEL_INDEX, arg)
        else
          @label_index, @flags, @reserved = arg, flags, reserved
          super(LABEL_INDEX, [reserved, flags, arg].pack('CnN'))
        end
      end

      def to_s
        "Label index: #{@label_index}"
      end

      def to_hash
        { :label_index => @label_index }
      end
    end

    # RFC 8669 section 3.2: flags (2 octets), then 6 octet entries, each
    # a 3 octet first label and a 3 octet count.
    class Originator_srgb < Tlv
      attr_reader :ranges, :flags

      # new([base, count], [base, count], ...) or the TLV value octets.
      def initialize(*args, flags: 0)
        if args.size == 1 and args[0].is_a?(String)
          value = args[0]
          @flags = value.unpack1('n')
          @ranges = []
          i = 2
          while i + 6 <= value.size
            e = value.byteslice(i, 6).unpack('C6')
            @ranges << [(e[0] << 16) | (e[1] << 8) | e[2], (e[3] << 16) | (e[4] << 8) | e[5]]
            i += 6
          end
          super(ORIGINATOR_SRGB, value)
        else
          @flags = flags
          @ranges = args.collect { |r| [r[0].to_i, r[1].to_i] }
          packed = @ranges.collect { |base, count|
            [base >> 16, (base >> 8) & 0xff, base & 0xff,
             count >> 16, (count >> 8) & 0xff, count & 0xff].pack('C6')
          }.join
          super(ORIGINATOR_SRGB, [flags].pack('n') + packed)
        end
      end

      def to_s
        'SRGB: ' + @ranges.collect { |base, count| "#{base}..#{base + count - 1}" }.join(', ')
      end

      def to_hash
        { :srgb => @ranges }
      end
    end

    attr_reader :tlvs

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, PREFIX_SID
      @tlvs = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args.size == 1 and args[0].is_a?(Hash)
        h = args[0]
        take_tail_key(h)
        add Label_index.new(h[:label_index]) if h[:label_index]
        add Originator_srgb.new(*h[:srgb]) if h[:srgb]
        [h[:tlvs]].flatten.compact.each { |t| add Tlv.new(t[:type], [t[:value]].pack('H*')) }
      else
        add(*args)
      end
    end

    def add(*args)
      args.each do |arg|
        raise ArgumentError, "invalid TLV #{arg.inspect}" unless arg.is_a?(Tlv)
        @tlvs << arg
      end
      self
    end
    alias << add

    # The first Label-Index TLV, or nil. RFC 8669 section 6: later
    # copies of a single occurrence TLV are discarded.
    def label_index
      tlv = @tlvs.find { |t| t.is_a?(Label_index) }
      tlv && tlv.label_index
    end

    # The SRGB ranges of the first Originator SRGB TLV, or nil.
    def srgb
      tlv = @tlvs.find { |t| t.is_a?(Originator_srgb) }
      tlv && tlv.ranges
    end

    def to_s(method=:default)
      super(@tlvs.collect(&:to_s).join(', '), method)
    end

    # The TLVs, plus a :tail key (Attr::TAIL_KEY) when octets were kept,
    # so the hash of a malformed attribute round trips byte for byte
    # through new. The key sits in the nested hash, where the attributes
    # that hash a value list carry a {:tail=>hex} entry instead.
    def to_hash
      h = {}
      known, unknown = @tlvs.partition { |t| t.is_a?(Label_index) or t.is_a?(Originator_srgb) }
      known.each { |t| h = h.merge(t.to_hash) }
      h[:tlvs] = unknown.collect(&:to_hash) unless unknown.empty?
      h = h.merge(tail_entry) if tail
      { :prefix_sid => h }
    end

    def encode
      super(@tlvs.collect(&:encode).join + (tail || ''))
    end

    private

    # RFC 8669 section 3. A TLV that runs past the end, or a header too
    # short to read, is kept as trailing octets so encode gives back what
    # was received. Section 6 makes such an attribute malformed;
    # Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value = super(s)
      i = 0
      while i < value.size
        if value.size - i < 3
          @tail = value.byteslice(i, value.size - i).b
          break
        end
        type = value.getbyte(i)
        len = value.byteslice(i + 1, 2).unpack1('n')
        if i + 3 + len > value.size
          @tail = value.byteslice(i, value.size - i).b
          break
        end
        body = value.byteslice(i + 3, len)
        @tlvs << case type
                 when LABEL_INDEX     then len == 7 ? Label_index.new(body) : Tlv.new(type, body)
                 when ORIGINATOR_SRGB then (len >= 2 and (len - 2) % 6 == 0) ? Originator_srgb.new(body) : Tlv.new(type, body)
                 else                      Tlv.new(type, body)
                 end
        i += 3 + len
      end
    end

  end

  Attr.register(ATTR::PREFIX_SID, Prefix_sid, :prefix_sid) { |v| Prefix_sid.new(v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
