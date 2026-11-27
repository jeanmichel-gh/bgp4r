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
require 'bgp/messages/messages'

module BGP

  # The BGP Monitoring Protocol, BMP: RFC 7854, with RFC 9069's Loc-RIB.
  # A monitored router sends a station what its BGP sessions carry.
  # docs/design/bgp-operations.md section 8, pull request 8a.
  #
  # Each of section 4's seven messages is a class here, each built four
  # ways, as every codec in bgp4r is:
  #
  #   Bmp::Initiation.new(:information => [{ :type => 2, :string => 'r1' }])
  #   Bmp::Initiation.new(octets)          # from the wire
  #   Bmp::Initiation.new(other)           # from another instance
  #   Bmp::Initiation.new(msg.to_hash)     # from its own hash
  #
  # `Bmp::Message.factory(octets)` picks the class from the Message
  # Type; a type it does not know is an `Unknown`, kept whole (section
  # 4.1: "MUST ignore unrecognized message types"). The BGP messages
  # inside are bgp4r's own: an Update, an Open, a Notification. Nothing
  # here checks what it reads: `Bmp::Validation` does.
  module Bmp

    # Section 4.1: "This is set to '3'". Version 0 "MUST NOT be sent".
    VERSION = 3

    # Section 4.1: version, a 4-octet Message Length, the Message Type.
    HEADER = 6

    # Section 4.2: Peer Type, Peer Flags, the Peer Distinguisher, the
    # Peer Address, Peer AS, Peer BGP ID and the two timestamps.
    PER_PEER = 42

    # Section 4.2 and RFC 9069 section 4.1.
    PEER_TYPES = { 0 => 'Global Instance Peer', 1 => 'RD Instance Peer', 2 => 'Local Instance Peer',
                   3 => 'Loc-RIB Instance Peer' }.freeze
    LOC_RIB = 3

    # Section 4.2's flags for peer types 0 to 2, the high-order bit
    # first; RFC 9069 section 4.2's F for type 3.
    FLAG_V = 0x80
    FLAG_L = 0x40
    FLAG_A = 0x20
    FLAG_F = 0x80

    # Section 4.9 and RFC 9069 section 5.3.
    PEER_DOWN_REASONS = {
      1 => 'Local system closed, NOTIFICATION PDU follows',
      2 => 'Local system closed, FSM Event follows',
      3 => 'Remote system closed, NOTIFICATION PDU follows',
      4 => 'Remote system closed, no data',
      5 => 'Peer de-configured',
      6 => 'Local system closed, TLV data follows',
    }.freeze

    # Section 4.5.
    TERMINATION_REASONS = {
      0 => 'Session administratively closed', 1 => 'Unspecified reason', 2 => 'Out of resources',
      3 => 'Redundant connection', 4 => 'Session permanently administratively closed',
    }.freeze

    # Section 4.8: each Stat Type and the shape of its data. :counter is
    # 32 bits, :gauge 64; :afi_safi_gauge is a 2-octet AFI, a 1-octet
    # SAFI and a 64-bit gauge.
    STATS = {
      0 => [:counter, 'prefixes rejected by inbound policy'],
      1 => [:counter, 'duplicate prefix advertisements'],
      2 => [:counter, 'duplicate withdraws'],
      3 => [:counter, 'updates invalidated due to CLUSTER_LIST loop'],
      4 => [:counter, 'updates invalidated due to AS_PATH loop'],
      5 => [:counter, 'updates invalidated due to ORIGINATOR_ID'],
      6 => [:counter, 'updates invalidated due to AS_CONFED loop'],
      7 => [:gauge, 'routes in Adj-RIBs-In'],
      8 => [:gauge, 'routes in Loc-RIB'],
      9 => [:afi_safi_gauge, 'routes in per-AFI/SAFI Adj-RIB-In'],
      10 => [:afi_safi_gauge, 'routes in per-AFI/SAFI Loc-RIB'],
      11 => [:counter, 'updates subjected to treat-as-withdraw'],
      12 => [:counter, 'prefixes subjected to treat-as-withdraw'],
      13 => [:counter, 'duplicate update messages received'],
    }.freeze
    STAT_LENGTH = { :counter => 4, :gauge => 8, :afi_safi_gauge => 11 }.freeze

    # Whole messages off the front of a buffer: [messages, what is
    # left], as octets, the way they came. A Length below the header
    # cannot be stepped over, so the rest is returned as one.
    def self.slices(buffer)
      buffer = buffer.b
      list = []
      while buffer.bytesize >= HEADER
        length = buffer.unpack1('@1N')
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

    # The same, each parsed.
    def self.messages(buffer)
      list, rest = slices(buffer)
      [list.collect { |o| Message.factory(o) }, rest]
    end

    # A BGP message's octets, from its Length (RFC 4271 section 4.1):
    # [message, rest].
    def self.bgp_split(octets)
      return [octets, ''.b] if octets.bytesize < 19
      length = octets.unpack1('@16n')
      [octets.byteslice(0, length), octets.byteslice(length..) || ''.b]
    end

    # Section 4.2: the per-peer header.
    class Per_peer
      attr_accessor :peer_type, :flags, :distinguisher, :address, :asn, :bgp_id, :seconds, :microseconds

      # (address, asn, bgp_id, peer_type = 0, flags = 0, ...) or a Hash
      # with those keys, or the 42 octets. The distinguisher is 16 hex
      # digits; the V flag follows the address unless flags say.
      def initialize(*args)
        arg = args.first
        if args.size == 1 && arg.is_a?(String)
          parse(arg.b)
        elsif args.size == 1 && arg.is_a?(Per_peer)
          parse(arg.encode)
        elsif args.size == 1 && arg.is_a?(Hash)
          from_hash(arg)
        else
          from_fields(*args)
        end
      end

      def loc_rib? ; @peer_type == LOC_RIB ; end
      def ipv6? ; !loc_rib? && @flags & FLAG_V != 0 ; end
      def post_policy? ; !loc_rib? && @flags & FLAG_L != 0 ; end
      def as2? ; !loc_rib? && @flags & FLAG_A != 0 ; end
      def filtered? ; loc_rib? && @flags & FLAG_F != 0 ; end

      def encode
        addr = IPAddr.new(@address)
        a = addr.ipv4? ? ("\0".b * 12) + addr.hton : addr.hton
        [@peer_type, @flags].pack('CC') + [@distinguisher].pack('H16') + a +
          [@asn, IPAddr.new(@bgp_id).to_i, @seconds, @microseconds].pack('NNNN')
      end

      def to_hash
        { :peer_type => @peer_type, :flags => @flags, :distinguisher => @distinguisher, :address => @address,
          :asn => @asn, :bgp_id => @bgp_id, :seconds => @seconds, :microseconds => @microseconds }
      end

      def to_s
        "#{PEER_TYPES[@peer_type] || "peer type #{@peer_type}"} #{@address} AS #{@asn} ID #{@bgp_id}" \
          "#{post_policy? ? ', post-policy' : ''}#{as2? ? ', 2-octet AS' : ''}#{filtered? ? ', filtered' : ''}"
      end

      private

      def from_fields(address = '0.0.0.0', asn = 0, bgp_id = '0.0.0.0', peer_type = 0, flags = nil,
                      distinguisher = '0' * 16, seconds = 0, microseconds = 0)
        @address = IPAddr.new(address.to_s).to_s
        @peer_type = peer_type
        @flags = flags || (peer_type != LOC_RIB && IPAddr.new(@address).ipv6? ? FLAG_V : 0)
        @distinguisher = distinguisher
        @asn, @bgp_id, @seconds, @microseconds = asn, IPAddr.new(bgp_id.to_s).to_s, seconds, microseconds
      end

      def from_hash(h)
        from_fields(h[:address] || '0.0.0.0', h[:asn] || 0, h[:bgp_id] || '0.0.0.0', h[:peer_type] || 0, h[:flags],
                    h[:distinguisher] || '0' * 16, h[:seconds] || 0, h[:microseconds] || 0)
      end

      def parse(s)
        @peer_type, @flags = s.unpack('CC')
        @distinguisher = s.byteslice(2, 8).unpack1('H16')
        raw = s.byteslice(10, 16)
        @address = IPAddr.new_ntoh(ipv6? ? raw : raw.byteslice(12, 4)).to_s
        @asn, id, @seconds, @microseconds = s.byteslice(26, 16).unpack('NNNN')
        @bgp_id = IPAddr.new(id, Socket::AF_INET).to_s
      end
    end

    # Sections 4.4, 4.5 and 4.7: a 2-octet type, a 2-octet length, the
    # value. What the value is depends on the message and the type, so
    # the message says (STRINGS and CODES below); the rest is hex.
    class Tlv
      attr_accessor :type, :value

      def self.list(octets)
        out = []
        while octets.bytesize >= 4
          _type, len = octets.unpack('nn')
          out << octets.byteslice(0, 4 + len)
          octets = octets.byteslice(4 + len..) || ''.b
        end
        out
      end

      def initialize(type = 0, value = ''.b)
        @type, @value = type, value.b
      end

      def encode ; [@type, @value.bytesize].pack('nn') + @value ; end

      def self.parse(octets)
        type, len = octets.unpack('nn')
        new(type, octets.byteslice(4, len) || ''.b)
      end
    end

    # What every message shares: the version, the type, and the four
    # ways to build one. A subclass names TYPE and its body.
    class Message
      attr_accessor :version

      # The classes by Message Type, filled as each class is defined.
      TYPES = {}

      # session_info: what an Update inside is read with (Update::Info,
      # or a Neighbor's capabilities from the Peer Up's two OPENs); with
      # none, the per-peer header's A flag says the AS width.
      def self.factory(octets, session_info = nil)
        type = octets.getbyte(5)
        klass = TYPES[type] || Unknown
        klass == Route_monitoring ? klass.new(octets, session_info) : klass.new(octets)
      end

      def self.type(n)
        const_set(:TYPE, n)
        TYPES[n] = self
      end

      def initialize(*args)
        @version = VERSION
        arg = args.first
        if arg.is_a?(String) && args.size <= 2
          @session_info = args[1]
          parse(arg.b)
        elsif args.size == 1 && arg.is_a?(self.class)
          @session_info = arg.instance_variable_get(:@session_info)
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

      # The name a Hash of this message is keyed by.
      def hash_key ; self.class.name.split('::').last.downcase.to_sym ; end

      def encode
        body = encode_body
        [@version, HEADER + body.bytesize, type].pack('CNC') + body
      end

      def to_hash ; { hash_key => { :version => @version }.merge(hash_fields) } ; end

      def to_shex ; encode.unpack1('H*') ; end

      def ==(other) ; other.is_a?(Message) && other.encode == encode ; end

      def to_s
        "BMP #{self.class.name.split('::').last.tr('_', ' ')} (#{type}), version #{@version}, length #{encode.bytesize}"
      end

      private

      def parse(s)
        @version = s.getbyte(0)
        parse_body(s.byteslice(HEADER..) || ''.b)
      end

      def from_fields(*) ; end
      def from_hash(_h) ; end
      def hash_fields ; {} ; end
      def encode_body ; ''.b ; end
      def parse_body(_body) ; end

      # Information TLVs as Hashes: each String type as :string, each
      # code type as :code, anything else as :hex.
      def tlv_hash(t)
        if self.class::CODES.include?(t.type) && t.value.bytesize == 2
          { :type => t.type, :code => t.value.unpack1('n') }
        elsif self.class::STRINGS.include?(t.type)
          { :type => t.type, :string => t.value.dup.force_encoding('UTF-8') }
        else
          { :type => t.type, :hex => t.value.unpack1('H*') }
        end
      end

      def tlv_from(h)
        return h if h.is_a?(Tlv)
        value = if h.key?(:code) then [h[:code]].pack('n')
                elsif h.key?(:string) then h[:string].to_s.b
                else [h[:hex].to_s].pack('H*')
                end
        Tlv.new(h[:type] || 0, value)
      end
    end

    # A message with a per-peer header first: Route Monitoring,
    # Statistics Report, Peer Down, Peer Up, Route Mirroring (section 4,
    # and RFC 7854 erratum 4830 for Peer Down).
    class Peer_message < Message
      attr_accessor :peer

      private

      def peer_from(p) ; p.is_a?(Per_peer) ? p : Per_peer.new(p || {}) ; end

      def parse_body(body)
        @peer = Per_peer.new(body.byteslice(0, PER_PEER).ljust(PER_PEER, "\0"))
        parse_rest(body.byteslice(PER_PEER..) || ''.b)
      end

      def encode_body ; @peer.encode + encode_rest ; end
      def hash_fields ; { :peer => @peer.to_hash }.merge(rest_hash) ; end
    end

    # Sections 4.6 and 5: a BGP UPDATE received from the peer, or the
    # Loc-RIB's (RFC 9069 section 5.4). An End-of-RIB marks the end of a
    # peer's dump.
    class Route_monitoring < Peer_message
      type 0
      attr_accessor :update

      # The Update::Info the UPDATE is read and written with: the given
      # session_info, or the A flag's AS width (RFC 9069 section 5.4.1:
      # the Loc-RIB's is always four octets).
      def session_info ; @session_info || Update::Info.new(!@peer.as2?) ; end

      def end_of_rib? ; @update.encode(session_info).bytesize == 23 ; end

      private

      def from_fields(peer = nil, update = nil, session_info = nil)
        @peer, @session_info = peer_from(peer), session_info
        @update = update || Update.new
      end

      def from_hash(h)
        @peer = peer_from(h[:peer])
        @update = Update.new(h[:update] || {})
      end

      def parse_rest(rest) ; @update = Update.new(rest.is_packed, session_info) ; end
      def encode_rest ; @update.encode(session_info) ; end
      def rest_hash ; { :update => @update.to_hash } ; end
    end

    # Sections 4.8 and 7: counters and gauges, each a Stat.
    class Stats_report < Peer_message
      type 1
      attr_accessor :stats

      # One stat: [type, value] or, for 9 and 10, [type, afi, safi,
      # value]. A type it does not know, or data of another length, is
      # kept as hex (section 4.8: "MUST ignore unrecognized stat types
      # ... and likewise MUST ignore unexpected data").
      Stat = Struct.new(:type, :value, :afi, :safi, :hex) do
        def shape
          kind, = STATS[type]
          kind && hex.nil? ? kind : nil
        end

        def encode
          data = case shape
                 when :counter then [value].pack('N')
                 when :gauge then [value].pack('Q>')
                 when :afi_safi_gauge then [afi, safi, value].pack('nCQ>')
                 else [hex.to_s].pack('H*')
                 end
          [type, data.bytesize].pack('nn') + data
        end

        def to_hash
          return { :type => type, :hex => hex } unless shape
          h = { :type => type, :value => value }
          h.merge!(:afi => afi, :safi => safi) if shape == :afi_safi_gauge
          h
        end

        def self.parse(octets)
          type, len = octets.unpack('nn')
          data = octets.byteslice(4, len) || ''.b
          kind, = STATS[type]
          return new(type, nil, nil, nil, data.unpack1('H*')) unless kind && data.bytesize == STAT_LENGTH[kind]
          case kind
          when :counter then new(type, data.unpack1('N'))
          when :gauge then new(type, data.unpack1('Q>'))
          else afi, safi, v = data.unpack('nCQ>') ; new(type, v, afi, safi)
          end
        end

        def self.from(h)
          return h if h.is_a?(Stat)
          new(h[:type], h[:value], h[:afi], h[:safi], h[:hex])
        end
      end

      private

      def from_fields(peer = nil, *stats)
        @peer = peer_from(peer)
        @stats = stats.collect { |s| s.is_a?(Array) ? Stat.new(*s) : Stat.from(s) }
      end

      def from_hash(h)
        @peer = peer_from(h[:peer])
        @stats = (h[:stats] || []).collect { |s| Stat.from(s) }
      end

      def parse_rest(rest)
        count = rest.unpack1('N').to_i
        rest = rest.byteslice(4..) || ''.b
        @stats = []
        count.times do
          break if rest.bytesize < 4
          len = rest.unpack1('@2n')
          @stats << Stat.parse(rest.byteslice(0, 4 + len))
          rest = rest.byteslice(4 + len..) || ''.b
        end
      end

      def encode_rest ; [@stats.size].pack('N') + @stats.collect(&:encode).join ; end
      def rest_hash ; { :stats => @stats.collect(&:to_hash) } ; end
    end

    # Section 4.9: why the session ended. 1 and 3 carry the
    # NOTIFICATION, 2 the FSM Event, 6 (RFC 9069 section 5.3)
    # Information TLVs.
    class Peer_down < Peer_message
      type 2
      attr_accessor :reason, :notification, :fsm_event, :information

      STRINGS = [0, 3].freeze
      CODES = [].freeze

      private

      def from_fields(peer = nil, reason = 4, data = nil)
        @peer, @reason = peer_from(peer), reason
        case reason
        when 1, 3 then @notification = data.is_a?(Notification) ? data : Notification.new(*Array(data))
        when 2 then @fsm_event = data || 0
        when 6 then @information = Array(data).collect { |t| tlv_from(t) }
        else @data = data.to_s.b
        end
      end

      def from_hash(h)
        data = case h[:reason]
               when 1, 3 then n = h[:notification] || {} ; Notification.new(n[:code], n[:subcode], *[n[:data]].compact)
               when 2 then h[:fsm_event]
               when 6 then h[:information]
               else [h[:hex].to_s].pack('H*')
               end
        from_fields(h[:peer], h[:reason] || 4, data)
      end

      def parse_rest(rest)
        @reason = rest.getbyte(0)
        data = rest.byteslice(1..) || ''.b
        case @reason
        when 1, 3 then @notification = Notification.new(data.is_packed)
        when 2 then @fsm_event = data.unpack1('n')
        when 6 then @information = Tlv.list(data).collect { |o| Tlv.parse(o) }
        else @data = data
        end
      end

      def encode_rest
        data = case @reason
               when 1, 3 then @notification.encode
               when 2 then [@fsm_event].pack('n')
               when 6 then @information.collect(&:encode).join
               else @data.to_s
               end
        [@reason].pack('C') + data
      end

      def rest_hash
        h = { :reason => @reason }
        case @reason
        when 1, 3 then h[:notification] = @notification.to_hash
        when 2 then h[:fsm_event] = @fsm_event
        when 6 then h[:information] = @information.collect { |t| tlv_hash(t) }
        else h[:hex] = @data.to_s.unpack1('H*') unless @data.to_s.empty?
        end
        h
      end
    end

    # Section 4.10: the session's addresses and ports, both OPENs, and
    # Information TLVs (String; RFC 9069's VRF/Table Name).
    class Peer_up < Peer_message
      type 3
      attr_accessor :local_address, :local_port, :remote_port, :sent_open, :received_open, :information

      STRINGS = [0, 3].freeze
      CODES = [].freeze

      # The capabilities both OPENs give a Route Monitoring of this peer,
      # seen from the monitored router: it sent one, it received the
      # other.
      def session_info ; Neighbor::Capabilities.new(@sent_open, @received_open) ; end

      private

      def from_fields(peer = nil, local_address = '0.0.0.0', local_port = 0, remote_port = 0, sent_open = nil,
                      received_open = nil, *information)
        @peer = peer_from(peer)
        @local_address = IPAddr.new(local_address.to_s).to_s
        @local_port, @remote_port = local_port, remote_port
        @sent_open, @received_open = sent_open, received_open || sent_open
        @information = information.collect { |t| tlv_from(t) }
      end

      def from_hash(h)
        from_fields(h[:peer], h[:local_address] || '0.0.0.0', h[:local_port] || 0, h[:remote_port] || 0,
                    Open.new(h[:sent_open]), Open.new(h[:received_open]), *(h[:information] || []))
      end

      def parse_rest(rest)
        raw = rest.byteslice(0, 16).to_s.ljust(16, "\0")
        @local_address = IPAddr.new_ntoh(@peer.ipv6? ? raw : raw.byteslice(12, 4)).to_s
        @local_port, @remote_port = rest.byteslice(16, 4).to_s.ljust(4, "\0").unpack('nn')
        sent, rest = Bmp.bgp_split(rest.byteslice(20..) || ''.b)
        received, rest = Bmp.bgp_split(rest)
        @sent_open, @received_open = Open.new(sent.is_packed), Open.new(received.is_packed)
        @information = Tlv.list(rest).collect { |o| Tlv.parse(o) }
      end

      def encode_rest
        addr = IPAddr.new(@local_address)
        a = addr.ipv4? ? ("\0".b * 12) + addr.hton : addr.hton
        a + [@local_port, @remote_port].pack('nn') + @sent_open.encode + @received_open.encode +
          @information.collect(&:encode).join
      end

      def rest_hash
        { :local_address => @local_address, :local_port => @local_port, :remote_port => @remote_port,
          :sent_open => @sent_open.to_hash, :received_open => @received_open.to_hash,
          :information => @information.collect { |t| tlv_hash(t) } }
      end
    end

    # Sections 4.3 and 4.4: who the router is, String, sysDescr and
    # sysName TLVs. No per-peer header.
    class Initiation < Message
      type 4
      attr_accessor :information

      STRINGS = [0, 1, 2].freeze
      CODES = [].freeze

      # The first TLV of type, as a String, or nil.
      def string(type) ; t = @information.find { |x| x.type == type } and t.value.dup.force_encoding('UTF-8') ; end
      def sys_descr ; string(1) ; end
      def sys_name ; string(2) ; end

      private

      def from_fields(*information) ; @information = information.collect { |t| tlv_from(t) } ; end
      # One TLV's Hash alone, { :type => 2, ... }, is the fields form.
      def from_hash(h) ; h.key?(:type) ? from_fields(h) : from_fields(*(h[:information] || [])) ; end
      def parse_body(body) ; @information = Tlv.list(body).collect { |o| Tlv.parse(o) } ; end
      def encode_body ; @information.collect(&:encode).join ; end
      def hash_fields ; { :information => @information.collect { |t| tlv_hash(t) } } ; end
    end

    # Section 4.5: why the router ends the session, a Reason TLV and
    # String TLVs. No per-peer header.
    class Termination < Initiation
      type 5

      STRINGS = [0].freeze
      CODES = [1].freeze

      # The Reason TLV's code, or nil.
      def reason ; t = @information.find { |x| x.type == 1 } and t.value.unpack1('n') ; end
    end

    # Sections 4.7 and 6: a BGP message as received, and an Information
    # code. The BGP message is kept as octets, since an errored one is
    # what this is for; `message` parses it.
    class Route_mirroring < Peer_message
      type 6
      attr_accessor :tlvs

      STRINGS = [].freeze
      CODES = [1].freeze

      # The BGP Message TLV's message, parsed, or nil.
      def message
        t = @tlvs.find { |x| x.type == 0 } or return nil
        BGP::Message.factory(t.value.is_packed)
      rescue StandardError
        nil
      end

      private

      def from_fields(peer = nil, *tlvs)
        @peer = peer_from(peer)
        @tlvs = tlvs.collect { |t| t.is_a?(BGP::Message) ? Tlv.new(0, t.encode) : tlv_from(t) }
      end

      def from_hash(h) ; from_fields(h[:peer], *(h[:tlvs] || [])) ; end
      def parse_rest(rest) ; @tlvs = Tlv.list(rest).collect { |o| Tlv.parse(o) } ; end
      def encode_rest ; @tlvs.collect(&:encode).join ; end
      def rest_hash ; { :tlvs => @tlvs.collect { |t| tlv_hash(t) } } ; end
    end

    # A Message Type this does not know, kept whole: section 4.1, "MUST
    # ignore unrecognized message types upon receipt".
    class Unknown < Message
      attr_reader :type, :body

      def hash_key ; :unknown ; end

      private

      def parse(s)
        @version, _len, @type = s.unpack('CNC')
        @body = s.byteslice(HEADER..) || ''.b
      end

      def from_fields(type = 255, body = ''.b) ; @type, @body = type, body.b ; end
      def from_hash(h) ; from_fields(h[:type] || 255, [h[:hex].to_s].pack('H*')) ; end
      def encode_body ; @body ; end
      def hash_fields ; { :type => @type, :hex => @body.unpack1('H*') } ; end
    end
  end
end
