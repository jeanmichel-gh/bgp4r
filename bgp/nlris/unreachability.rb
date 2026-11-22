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

require 'bgp/common'
require 'ipaddr'
require 'time'

module BGP

  # The Unreachability Information NLRI, AFI 1 or 2 with SAFI 81, from
  # draft-tantsura-idr-unreachability-safi-06. The design is
  # docs/design/unreachability.md.
  #
  # Section 3.2, the same for IPv6 in 3.3:
  #
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                  NLRI Length (2 octets)                       |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   | Prefix Length |           IPv4 Prefix (variable)              |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #   |                  Reporter TLVs (variable)                     |
  #   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  #
  # The NLRI Length counts the octets after it. The prefix is RFC 4271's,
  # the octets its length needs. A withdrawal (section 4.3.2) is the same
  # NLRI with no Reporter TLVs, so it is this class with none.
  #
  # **Nothing validates**, per Conventions. A prefix length of 33, no
  # reporter in an announcement, a reporter in a withdrawal, a Length
  # that lies: each builds, encodes and parses back, so a test can send
  # it. What a receiver must do with them is in
  # `Attr::Check#unreachability_finding`.
  #
  # The Reporter TLV and its sub-TLVs are below. The EVPN route type of
  # draft-tantsura-bess-evpn-unreachability carries the same Reporter
  # TLV, with one more sub-TLV, so they are built to be shared.
  class Unreachability

    # The NLRI Length field.
    FRAMING = 2

    # Section 4.8: "Implementations SHOULD limit the number of Reporter
    # TLVs per prefix (RECOMMENDED maximum: 50)".
    MAX_REPORTERS = 50

    # Section 3.5.1's reason codes, which section 8.5 asks IANA to keep.
    # 64536 to 65535 are for private use.
    REASONS = {
      0 => 'Unspecified',
      1 => 'Policy Blocked',
      2 => 'Security Filtered',
      3 => 'RPKI Invalid',
      4 => 'No Export Policy',
      5 => 'Martian Address',
      6 => 'Bogon Prefix',
      7 => 'Maintenance',
      8 => 'Local Administrative Action',
      9 => 'Local Link Down',
    }.freeze

    PRIVATE_REASONS = (64536..65535)

    # The longest prefix per AFI, section 5.1: "0-32 for AFI=1, 0-128 for
    # AFI=2".
    MAX_MLEN = { 1 => 32, 2 => 128 }.freeze

    def self.reason_name(code)
      name = REASONS[code]
      return name if name
      PRIVATE_REASONS.include?(code) ? 'Private Use' : 'Unassigned'
    end

    # A TLV of this family: Type (1 octet), Length (2 octets), Value.
    # Section 3.4 frames the Reporter TLV this way and section 3.5 its
    # sub-TLVs, so one base serves both.
    class Tlv

      FRAMING = 3

      class << self
        def type
          self::TYPE
        end

        def hash_key
          self::HASH_KEY
        end

        # A TLV's own wrapped hash, {:reporter=>{...}}, or its field hash.
        def unwrap(h)
          return h unless h.is_a?(Hash)
          h.has_key?(hash_key) ? h[hash_key] : h
        end
      end

      # The Length that arrived, when it was not the number of octets that
      # came with it, so `encode` gives the peer's own Length back. nil on
      # anything built from values. The hash carries it as :length.
      attr_accessor :declared_len

      def type
        self.class.type
      end

      def length
        @declared_len || encode_value.size
      end

      def encode
        v = encode_value
        n = @declared_len || v.size
        if n > 0xffff
          raise ArgumentError, "a Length of #{n} does not fit in 2 octets"
        end
        [type.to_i, n, v].pack('Cna*')
      end

      def to_shex
        encode.unpack1('H*')
      end

      def size
        encode.size
      end

      def to_hash
        h = { self.class.hash_key => value_hash }
        h[:length] = @declared_len if @declared_len
        h
      end

      def ==(other)
        other.is_a?(Tlv) and other.encode == encode
      end

      private

      # The :length key, read the same way by every class.
      def length_from(h)
        @declared_len = h[:length] if h.is_a?(Hash) and h[:length]
      end

      # A TLV type no registry knows, kept whole and written back, so a
      # capture replays byte for byte. Sections 3.5 and 5.3 have a
      # receiver skip one; skipping is the receiver's business, keeping
      # it is this class's.
      #
      # **Mind the name.** It is `Unreachability::Tlv::Unknown`, used at
      # both levels, the Reporter TLVs and the sub-TLVs.
      public

      class Unknown < Tlv

        HASH_KEY = :unknown

        attr_reader :value

        def initialize(*args)
          @type, @value = 0, +''
          if args.size == 1 and args[0].is_a?(self.class)
            @type = args[0].type
            @value = args[0].value.dup
            @declared_len = args[0].declared_len
          elsif args.size == 1 and args[0].is_a?(Hash)
            h = self.class.unwrap(args[0])
            @type = h[:type].to_i
            @value = [h[:value].to_s].pack('H*')
            length_from(args[0])
          elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
            @type = args[0]
            @value = args[1].to_s.b
          else
            raise ArgumentError, "invalid argument: #{args.inspect}, " \
                                 'expected (type, value) or a hash'
          end
          refuse_a_type_the_field_cannot_hold
          self
        end

        def type
          @type
        end

        def encode_value
          @value
        end

        def value_hash
          { :type => @type, :value => @value.unpack1('H*') }
        end

        def to_s
          "type #{@type} (#{@value.unpack1('H*')})"
        end

        private

        def refuse_a_type_the_field_cannot_hold
          return if (0..255).include?(@type)
          raise ArgumentError, "a type of #{@type} does not fit in 1 octet"
        end

      end

      # Type number to class, and hash key back to class, for one level.
      # There are two: the Reporter TLV types of section 8.3 and the
      # sub-TLV types of section 8.4. The EVPN draft has its own sub-TLV
      # registry, with an EVI, so a Reporter TLV is read against one.
      class Registry

        def initialize(name)
          @name, @by_type, @by_key = name, {}, {}
        end

        # Add a class. Raises on a type or a key already taken.
        def register(klass)
          t, k = klass.type, klass.hash_key
          if @by_type.has_key?(t) and @by_type[t] != klass
            raise ArgumentError, "#{@name} type #{t} is already #{@by_type[t]}"
          end
          if @by_key.has_key?(k) and @by_key[k] != klass
            raise ArgumentError, "#{@name} key #{k.inspect} is already #{@by_key[k]}"
          end
          @by_type[t] = klass
          @by_key[k] = klass
          klass
        end

        def [](type)
          @by_type[type]
        end

        def types
          @by_type.keys.sort
        end

        # Read one TLV off the front of _s_, consuming its octets. nil when
        # fewer than 3 octets are left, so a list loop stops.
        #
        # A Length that overruns takes what is there and keeps the Length,
        # so `encode` replays it. A registered class is kept only when it
        # gives its own octets back; otherwise the TLV is an Unknown with
        # the same type, which replays the octets as they came.
        def factory(s)
          return nil if s.nil? or s.size < Tlv::FRAMING
          t, len = s.slice!(0, Tlv::FRAMING).unpack('Cn')
          value = s.slice!(0, [len, s.size].min).to_s
          tlv = read(t, value) || Tlv::Unknown.new(t, value)
          tlv.declared_len = len if len != value.size
          tlv
        end

        # Every TLV in _s_, consuming them. Fewer than 3 octets at the end
        # are left in _s_ for the caller to keep as a tail.
        def parse_list(s)
          list = []
          loop do
            tlv = factory(s)
            break if tlv.nil?
            list << tlv
          end
          list
        end

        # One TLV from its hash, by key, or an instance as it is.
        def build(h)
          return h if h.is_a?(Tlv)
          raise ArgumentError, "invalid #{@name}: #{h.inspect}" unless h.is_a?(Hash)
          return Tlv::Unknown.new(h) if h.has_key?(:unknown)
          key = h.keys.find { |k| @by_key.has_key?(k) }
          raise ArgumentError, "no #{@name} in #{h.inspect}" if key.nil?
          @by_key[key].new(h)
        end

        private

        def read(t, value)
          klass = @by_type[t]
          return nil if klass.nil?
          tlv = klass.new(value.dup.is_packed)
          tlv.encode_value == value ? tlv : nil
        rescue StandardError
          nil
        end

      end

    end

    # Section 3.5.1: the Reason Code sub-TLV, 2 octets.
    class Reason_code < Tlv

      TYPE = 1
      HASH_KEY = :reason_code

      attr_reader :code

      def initialize(*args)
        @code = 0
        arg = args[0]
        if args.size == 1 and arg.is_a?(String) and arg.is_packed?
          raise ArgumentError, "a Reason Code is 2 octets, not #{arg.size}" if arg.size != 2
          @code = arg.unpack1('n')
        elsif args.size == 1 and arg.is_a?(self.class)
          @code = arg.code
          @declared_len = arg.declared_len
        elsif args.size == 1 and arg.is_a?(Hash)
          @code = self.class.unwrap(arg).to_i
          length_from(arg)
        elsif args.size == 1 and arg.is_a?(Integer)
          @code = arg
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        raise ArgumentError, "a Reason Code of #{@code} does not fit in 2 octets" unless (0..0xffff).include?(@code)
        self
      end

      def encode_value
        [@code].pack('n')
      end

      def value_hash
        @code
      end

      def name
        Unreachability.reason_name(@code)
      end

      def to_s
        "reason #{name} (#{@code})"
      end

    end

    # Section 3.5.2: the Timestamp sub-TLV, 8 octets, Unix seconds.
    class Timestamp < Tlv

      TYPE = 2
      HASH_KEY = :timestamp

      attr_reader :seconds

      def initialize(*args)
        @seconds = 0
        arg = args[0]
        if args.size == 1 and arg.is_a?(String) and arg.is_packed?
          raise ArgumentError, "a Timestamp is 8 octets, not #{arg.size}" if arg.size != 8
          @seconds = arg.unpack1('Q>')
        elsif args.size == 1 and arg.is_a?(self.class)
          @seconds = arg.seconds
          @declared_len = arg.declared_len
        elsif args.size == 1 and arg.is_a?(Hash)
          @seconds = self.class.unwrap(arg).to_i
          length_from(arg)
        elsif args.size == 1 and arg.is_a?(Integer)
          @seconds = arg
        elsif args.size == 1 and arg.is_a?(Time)
          @seconds = arg.to_i
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        raise ArgumentError, "a Timestamp of #{@seconds} does not fit in 8 octets" unless (0..0xffff_ffff_ffff_ffff).include?(@seconds)
        self
      end

      def encode_value
        [@seconds].pack('Q>')
      end

      def value_hash
        @seconds
      end

      def time
        Time.at(@seconds).utc
      end

      def to_s
        "at #{time.iso8601}"
      end

    end

    # Section 8.4's sub-TLV registry for SAFI 81: types 1 and 2.
    SUB_TLVS = Tlv::Registry.new('Unreachability sub-TLV')
    SUB_TLVS.register(Reason_code)
    SUB_TLVS.register(Timestamp)

    # Section 3.4: the Reporter TLV, type 1.
    #
    #   |     Type      |            Length             |               |
    #   |                   Reporter Identifier (4 octets)              |
    #   |         Reporter AS Number (4 octets)                         |
    #   |               Sub-TLVs (variable)                             |
    #
    # A value shorter than the 8 octets the Identifier and AS need cannot
    # be this class; the registry keeps it as an Unknown of type 1, which
    # replays it. Octets after the last whole sub-TLV are kept as a tail.
    class Reporter < Tlv

      TYPE = 1
      HASH_KEY = :reporter

      # The Reporter Identifier and the Reporter AS.
      FIXED = 8

      attr_reader :identifier, :as, :sub_tlvs, :tail

      # Reporter.new('198.51.100.1', 65001, Reason_code.new(3), Timestamp.new(t))
      # Reporter.new(:identifier=>'198.51.100.1', :as=>65001,
      #              :sub_tlvs=>[{:reason_code=>3}, {:timestamp=>t}])
      # Reporter.new(:identifier=>'198.51.100.1', :as=>65001, :reason=>3, :timestamp=>t)
      #
      # The last form is a shortcut: a Reason Code, then a Timestamp, each
      # only when given. `to_hash` always answers :sub_tlvs, which keeps
      # their order, repeats and unknown types.
      def initialize(*args)
        @identifier, @as, @sub_tlvs, @tail = '0.0.0.0', 0, [], +''
        @sub_registry = self.class.sub_registry
        arg = args[0]
        if arg.is_a?(String) and arg.is_packed?
          @sub_registry = args[1] if args[1].is_a?(Tlv::Registry)
          parse(arg)
        elsif args.size == 1 and arg.is_a?(self.class)
          @sub_registry = arg.sub_registry
          @declared_len = arg.declared_len
          parse(arg.encode_value.is_packed)
        elsif arg.is_a?(Hash)
          @sub_registry = args[1] if args[1].is_a?(Tlv::Registry)
          from_hash(arg)
        elsif args.size >= 2
          @identifier = IPAddr.new(args[0].to_s).to_s
          @as = args[1].to_i
          @sub_tlvs = args[2..].collect { |t| @sub_registry.build(t) }
        else
          raise ArgumentError, "invalid argument: #{args.inspect}"
        end
        unless (0..0xffff_ffff).include?(@as)
          raise ArgumentError, "a Reporter AS of #{@as} does not fit in 4 octets"
        end
        self
      end

      # The sub-TLV registry a reporter of this class reads against:
      # section 8.4's for SAFI 81. Evpn_reporter answers the EVPN one.
      def self.sub_registry
        SUB_TLVS
      end

      # The sub-TLV registry this reporter reads against.
      attr_reader :sub_registry
      protected :sub_registry

      # Section 3.5.1: "When this Sub-TLV is absent from a Reporter TLV,
      # receivers MUST treat the reason as Unspecified (code 0)". Section
      # 3.5: of two of a type, "only the first occurrence SHOULD be
      # processed".
      def reason
        r = @sub_tlvs.find { |t| t.is_a?(Reason_code) }
        r ? r.code : 0
      end

      # The first Timestamp's seconds, or nil.
      def timestamp
        t = @sub_tlvs.find { |s| s.is_a?(Timestamp) }
        t && t.seconds
      end

      # Section 3.4: "The combination of Reporter Identifier and Reporter
      # AS Number uniquely identifies the Reporting Speaker."
      def key
        [@identifier, @as]
      end

      def encode_value
        [IPAddr.new(@identifier).hton, @as].pack('a4N') +
          @sub_tlvs.collect(&:encode).join + @tail
      end

      def value_hash
        h = { :identifier => @identifier, :as => @as }
        h[:sub_tlvs] = @sub_tlvs.collect(&:to_hash) unless @sub_tlvs.empty?
        h[:tail] = @tail.unpack1('H*') unless @tail.empty?
        h
      end

      def to_s
        s = +"reporter #{@identifier} AS#{@as}"
        @sub_tlvs.each { |t| s << ", #{t}" }
        s << ", tail #{@tail.unpack1('H*')}" unless @tail.empty?
        s
      end

      private

      def parse(s)
        raise ArgumentError, "a Reporter TLV needs #{FIXED} octets, has #{s.size}" if s.size < FIXED
        @identifier = IPAddr.new_ntoh(s.slice!(0, 4)).to_s
        @as = s.slice!(0, 4).unpack1('N')
        @sub_tlvs = @sub_registry.parse_list(s)
        @tail = s.to_s.b
      end

      def from_hash(h)
        length_from(h)
        v = self.class.unwrap(h)
        @identifier = IPAddr.new(v[:identifier].to_s).to_s
        @as = v[:as].to_i
        if v.has_key?(:sub_tlvs)
          @sub_tlvs = [v[:sub_tlvs]].flatten.compact.collect { |t| @sub_registry.build(t) }
        else
          # The registry's own classes, so an EVPN reporter gets the EVPN
          # Reason Code.
          @sub_tlvs << @sub_registry[Reason_code::TYPE].new(v[:reason].to_i) if v.has_key?(:reason)
          @sub_tlvs << @sub_registry[Timestamp::TYPE].new(v[:timestamp].to_i) if v.has_key?(:timestamp)
        end
        @tail = [v[:tail].to_s].pack('H*') if v[:tail]
      end

    end

    # Section 8.3's Reporter TLV registry: type 1.
    REPORTER_TLVS = Tlv::Registry.new('Unreachability Reporter TLV')
    REPORTER_TLVS.register(Reporter)

    class << self

      # The octets one NLRI occupies, its NLRI Length field included, for
      # `MpReachCommon::ClassMethods#nlri_size`. nil when fewer than the
      # 2 octets of the field are left.
      def nlri_size(s)
        return nil if s.nil? or s.size < FRAMING
        FRAMING + s.unpack1('n')
      end

      def new_ntop(s, afi = IANA::AFI::IPv4, path_id = nil)
        u = new(s.is_packed, afi)
        u.path_id = path_id if path_id
        u
      end

    end

    attr_reader :afi, :mlen, :reporters, :tail
    attr_accessor :path_id, :declared_len

    # Unreachability.new('192.0.2.0/24', reporter, ...)      an announcement
    # Unreachability.new('192.0.2.0/24')                     a withdrawal
    # Unreachability.new(octets, afi)                         from the wire
    # Unreachability.new(:prefix=>'192.0.2.0/24', :reporters=>[...])
    #
    # The AFI comes from the prefix, or from the caller for octets, since
    # nothing in them says which family it is.
    def initialize(*args)
      @afi, @mlen, @prefix, @reporters, @tail = IANA::AFI::IPv4, 0, +'', [], +''
      @path_id, @declared_len = nil, nil
      arg = args[0]
      if arg.is_a?(String) and arg.is_packed?
        @afi = (args[1] || IANA::AFI::IPv4).to_i
        parse(arg)
      elsif args.size == 1 and arg.is_a?(self.class)
        @afi, @path_id, @declared_len = arg.afi, arg.path_id, arg.declared_len
        parse(arg.encode_nlri.is_packed)
      elsif args.size == 1 and arg.is_a?(Hash)
        from_hash(arg)
      elsif arg.is_a?(String)
        prefix_from_string(arg)
        @reporters = args[1..].collect { |r| REPORTER_TLVS.build(r) }
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end
      self
    end

    # The prefix as text, '192.0.2.0/24', when its octets are what its
    # length needs and the length fits the family. nil otherwise: a
    # prefix length of 33, or fewer octets than the length asked for.
    def prefix
      return nil unless natural_prefix?
      octets = @prefix.ljust(@afi == IANA::AFI::IPv6 ? 16 : 4, "\x00")
      "#{IPAddr.new_ntoh(octets)}/#{@mlen}"
    end

    # The prefix octets as they came.
    def prefix_octets
      @prefix.dup
    end

    # Section 4.3.2: a withdrawal carries no Reporter TLVs.
    def withdrawal?
      @reporters.empty? and @tail.empty?
    end

    # Only the Reporter TLVs of type 1 that read as one.
    def reporter_tlvs
      @reporters.select { |r| r.is_a?(Reporter) }
    end

    # The NLRI from its NLRI Length on, without a Path Identifier.
    def encode_nlri
      body = @mlen.nil? ? +'' : [@mlen].pack('C')
      body << @prefix << @reporters.collect(&:encode).join << @tail
      n = @declared_len || body.size
      raise ArgumentError, "an NLRI Length of #{n} does not fit in 2 octets" if n > 0xffff
      [n].pack('n') + body
    end

    # RFC 7911 section 3 puts the Path Identifier before the NLRI Length,
    # which section 3.2 repeats.
    def encode
      s = +''
      s << [@path_id].pack('N') if @path_id
      s << encode_nlri
    end

    def to_shex
      encode.unpack1('H*')
    end

    def to_hash
      h = {}
      h[:path_id] = @path_id if @path_id
      if (p = prefix)
        h[:prefix] = p
      else
        h[:afi] = @afi
        h[:mlen] = @mlen
        h[:value] = @prefix.unpack1('H*')
      end
      h[:reporters] = @reporters.collect(&:to_hash) unless @reporters.empty?
      h[:length] = @declared_len if @declared_len
      h[:tail] = @tail.unpack1('H*') unless @tail.empty?
      h
    end

    def to_s
      s = +'Unreachability'
      s << " ID=#{@path_id}" if @path_id
      s << ": #{prefix || "#{@prefix.unpack1('H*')}/#{@mlen}"}"
      @reporters.each { |r| s << "\n      #{r}" }
      s << "\n      tail #{@tail.unpack1('H*')}" unless @tail.empty?
      s
    end

    def ==(other)
      other.is_a?(Unreachability) and other.afi == afi and other.encode == encode
    end

    private

    def natural_prefix?
      max = MAX_MLEN[@afi]
      max and @mlen and @mlen <= max and @prefix.size == (@mlen + 7) / 8
    end

    def parse(s)
      len = s.slice!(0, FRAMING).to_s.unpack1('n').to_i
      body = s.slice!(0, [len, s.size].min).to_s.b
      @declared_len = len if len != body.size
      if body.empty?
        @mlen = nil
        return
      end
      @mlen = body.slice!(0, 1).unpack1('C')
      @prefix = body.slice!(0, [(@mlen + 7) / 8, body.size].min)
      @reporters = REPORTER_TLVS.parse_list(body)
      @tail = body
    end

    def prefix_from_string(p)
      ip = IPAddr.new(p.to_s)
      @afi = ip.ipv6? ? IANA::AFI::IPv6 : IANA::AFI::IPv4
      @mlen = p.to_s.include?('/') ? p.to_s.split('/').last.to_i : (ip.ipv6? ? 128 : 32)
      @prefix = ip.hton.byteslice(0, (@mlen + 7) / 8)
    end

    def from_hash(h)
      @path_id = h[:path_id] if h[:path_id]
      if h[:prefix]
        prefix_from_string(h[:prefix])
      else
        @afi = (h[:afi] || IANA::AFI::IPv4).to_i
        @mlen = h[:mlen]
        @prefix = [h[:value].to_s].pack('H*')
      end
      @reporters = [h[:reporters]].flatten.compact.collect { |r| REPORTER_TLVS.build(r) }
      @declared_len = h[:length] if h[:length]
      @tail = [h[:tail].to_s].pack('H*') if h[:tail]
    end

  end

end
