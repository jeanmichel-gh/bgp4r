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
require 'bgp/iana'
require 'bgp/messages/messages'
require 'bgp/path_attributes/attributes'

module BGP
  module Capture

    # Dissects a captured frame down to its TCP payload, and a BGP message
    # down to its fields, for a packet decoder: every field with its byte
    # offset, length and, for bits, its mask, so a decoder can light up the
    # bytes of a field and the field of a byte. Every octet of a message
    # belongs to a field; reserved octets and bits are fields too.
    #
    #   seg = Dissect.segment(frame_bytes, :link => :ethernet)
    #   seg.payload                       # the TCP payload, or nil
    #   Dissect.message(octets).to_h      # => {:summary, :length, :fields, :errors}
    #
    # **The unit here is a BGP message and not a frame**, which is the one
    # way this differs from ospfv2's dissector and the reason for the split
    # into two entry points. OSPF is one packet per datagram, so there a
    # frame's octets and a packet's octets are the same thing and one set of
    # fields covers both. BGP runs over TCP, so a message may arrive in two
    # frames and two messages may share one: there is no frame whose octets
    # are the message. So offsets in the fields of Dissect.message are from
    # the start of the **message**, bgp/capture/stream.rb does the
    # reassembly, and the transport is reported as the flow rather than as
    # byte offset fields.
    #
    # Nothing here raises on a bad frame or a bad message. What does not
    # parse becomes a 'data' field and the reason goes to +errors+, which is
    # the keep-what-you-cannot-read rule of CLAUDE.md: a capture tool that
    # drops what it cannot read is useless for the job this library exists
    # to do.
    module Dissect

      # A field of a message. The shape is ospfv2's Dissect::Field minus
      # its +lsa+ key and its +leaves+ reader, so a console's decoder pane
      # reads one shape.
      #
      # **`leaves` was written here and removed**, which is worth a line
      # because the obvious thing is to copy ospfv2 whole. Nothing in the
      # library called it, nothing in the JSON carries it, and the one
      # test that used it was replaced by a stronger check that walks the
      # tree level by level. It also held a precedence bug, `children and
      # ... ? ... : [self]`, where `and` binds looser than `? :` so a
      # childless field answered nil and every leaf of every message was
      # nil. A method with a bug in it that nothing calls is the dead
      # constant case CLAUDE.md records in BGP-LS part 5b-ii, and the
      # answer there is to delete it rather than test it.
      #
      # +check+ is
      # kept for a verified computed field; BGP has none inside a message,
      # which is worth saying rather than leaving a reader to wonder: RFC
      # 4271 gives a message no checksum, and the only checksum over these
      # octets is TCP's, which belongs to a segment and not to a message.
      Field = Struct.new(:name, :offset, :length, :value, :show, :mask, :children, :check) do
        def to_h
          h = { :name => name, :offset => offset, :length => length }
          h[:value] = value unless value.nil?
          h[:show] = show unless show.nil?
          h[:mask] = mask if mask
          h[:check] = check if check
          h[:children] = children.collect { |c| c.to_h } if children and !children.empty?
          h
        end
      end

      Result = Struct.new(:summary, :length, :fields, :errors, :decoded, :decoded_error) do
        def to_h
          { :summary => summary, :length => length,
            :fields => fields.collect { |f| f.to_h }, :errors => errors }.tap { |h| h[:decoded] = decoded if decoded; h[:decoded_error] = decoded_error if decoded_error }
        end
      end

      # One direction of one TCP connection, with the payload that arrived
      # in this frame. +errors+ holds what could not be read on the way
      # down to it.
      Segment = Struct.new(:src, :dst, :sport, :dport, :seq, :payload, :errors) do
        # The flow key: one direction, so a session has two.
        def flow
          "#{src}:#{sport} > #{dst}:#{dport}"
        end
      end

      # pcap link types, as ospfv2's Dissect::LINKS has them, so the two
      # tools accept the same files. 1 Ethernet, 101 and 228 raw IP, 12 raw
      # IP on some systems, 113 Linux cooked.
      LINKS = { 1 => :ethernet, 101 => :ip, 12 => :ip, 113 => :sll, 228 => :ip }

      # RFC 4271 section 4.1: "Marker: This 16-octet field is included for
      # compatibility; it MUST be set to all ones." Followed by a 2-octet
      # Length and a 1-octet Type, so the header is 19 octets.
      MARKER_SIZE = 16
      HEADER_SIZE = 19

      # RFC 4271 section 4.1: the Length field "MUST always be at least 19
      # and no greater than 4096".
      MIN_LENGTH = 19

      TYPES = { Message::OPEN => 'OPEN', Message::UPDATE => 'UPDATE',
                Message::NOTIFICATION => 'NOTIFICATION', Message::KEEPALIVE => 'KEEPALIVE',
                Message::ROUTE_REFRESH => 'ROUTE-REFRESH', Message::CAPABILITY => 'CAPABILITY' }

      # RFC 4271 section 4.3, "Attr. Flags": bit 0 Optional, bit 1
      # Transitive, bit 2 Partial, bit 3 Extended Length, and "the lower
      # four bits of the Attribute Flags octet are unused".
      ATTR_FLAGS = { 0x80 => 'Optional', 0x40 => 'Transitive',
                     0x20 => 'Partial', 0x10 => 'Extended Length' }

      # RFC 7313 section 3.2: the Reserved octet of the RFC 2918
      # ROUTE-REFRESH "is redefined as the 'Message Subtype'".
      REFRESH_SUBTYPES = { 0 => 'normal', 1 => 'BoRR', 2 => 'EoRR', 255 => 'Reserved' }

      # Capability code to name, read out of OPT_PARM's own constants
      # rather than written down here, so a capability the library learns
      # is named by this dissector the same day. CAP_MBGP becomes 'MBGP'.
      CAPABILITIES = OPT_PARM.constants.grep(/\ACAP_/).inject({}) do |h, c|
        h[OPT_PARM.const_get(c)] = c.to_s.sub(/\ACAP_/, '').tr('_', ' ')
        h
      end

      def self.segment(bytes, link: :ethernet)
        Segments.new(bytes.b).run(link)
      end

      def self.message(octets)
        Messages.new(octets.b).run
      end

      # Reads the octets of a captured frame down to the TCP payload. It
      # produces no fields: the frame's own headers are not a message's
      # octets, so nothing a decoder lights up comes from here.
      class Segments

        def initialize(bytes)
          @b = bytes
          @errors = []
        end

        def run(link)
          off = case link
                when :ethernet then ethernet
                when :sll      then sll
                when :ip       then 0
                else
                  @errors << "link type #{link} is not supported"
                  nil
                end
          return none unless off
          case ip_version(off)
          when 4 then ipv4(off)
          when 6 then ipv6(off)
          else none
          end
        end

        private

        def none
          Segment.new(nil, nil, nil, nil, nil, nil, @errors)
        end

        def room?(off, len, what)
          return true if off + len <= @b.bytesize
          @errors << "#{what}: needs #{len} octets at #{off}, the frame ends at #{@b.bytesize}"
          false
        end

        def u8(off)  ; @b.getbyte(off) ; end
        def u16(off) ; @b[off, 2].unpack('n')[0] ; end
        def u32(off) ; @b[off, 4].unpack('N')[0] ; end
        def ip4(off) ; @b[off, 4].unpack('C4').join('.') ; end

        def ip6(off)
          # RFC 5952 is the recommended text form and IPAddr writes it, so
          # the address prints the way a router prints it.
          IPAddr.new_ntoh(@b[off, 16]).to_s
        end

        def ip_version(off)
          return nil unless room?(off, 1, 'IP header')
          u8(off) >> 4
        end

        # Returns where the IP header starts, or nil.
        def ethernet
          return nil unless room?(0, 14, 'Ethernet header')
          off = 12
          type = u16(off)
          # 0x8100 is an 802.1Q C-VLAN tag and 0x88a8 an 802.1ad S-VLAN
          # tag; a double tagged frame carries both, so this loops.
          while [0x8100, 0x88a8].include?(type) and room?(off, 6, 'VLAN tag')
            off += 4
            type = u16(off)
          end
          return off + 2 if [0x0800, 0x86dd].include?(type)
          @errors << "ethertype 0x%04x is not IPv4 or IPv6" % type
          nil
        end

        def sll
          return nil unless room?(0, 16, 'Linux cooked header')
          proto = u16(14)
          return 16 if [0x0800, 0x86dd].include?(proto)
          @errors << "Linux cooked protocol 0x%04x is not IPv4 or IPv6" % proto
          nil
        end

        # RFC 791. The payload ends where the Total Length says, clamped to
        # what the capture holds, since a snaplen cuts a frame short.
        def ipv4(off)
          return none unless room?(off, 20, 'IPv4 header')
          ihl = (u8(off) & 0x0f) * 4
          if ihl < 20
            @errors << "IPv4 header length #{ihl} is below the 20 octet minimum"
            return none
          end
          return none unless room?(off, ihl, 'IPv4 header and options')
          # RFC 791: a non-zero Fragment Offset means this frame carries no
          # transport header, so there is nothing to read. IP level
          # reassembly is deliberately not done here; a fragmented BGP
          # session is reported and skipped rather than guessed at.
          frag = u16(off + 6) & 0x1fff
          unless frag.zero?
            @errors << "IPv4 fragment at offset #{frag * 8}: no TCP header in this frame"
            return none
          end
          proto = u8(off + 9)
          unless proto == 6
            @errors << "IP protocol #{proto} is not TCP"
            return none
          end
          total = u16(off + 2)
          ip_end = total.zero? ? @b.bytesize : [off + total, @b.bytesize].min
          tcp(off + ihl, ip_end, ip4(off + 12), ip4(off + 16))
        end

        # RFC 8200. Only a Next Header of 6 is read. An extension header
        # chain is reported and skipped rather than walked: every header in
        # the chain has its own length rule, and a BGP session over one is
        # not a case this tool has met.
        def ipv6(off)
          return none unless room?(off, 40, 'IPv6 header')
          nh = u8(off + 6)
          unless nh == 6
            @errors << "IPv6 next header #{nh} is not TCP"
            return none
          end
          payload = u16(off + 4)
          ip_end = payload.zero? ? @b.bytesize : [off + 40 + payload, @b.bytesize].min
          tcp(off + 40, ip_end, ip6(off + 8), ip6(off + 24))
        end

        # RFC 9293 section 3.1. The Data Offset is the high nibble of the
        # octet at 12, in 32-bit words, so the header is that times four.
        # The TCP checksum is read and **not** verified, deliberately: a
        # capture taken on a host with checksum offload carries a wrong or
        # zero checksum on every frame it sent, so verifying it would turn
        # an ordinary lab capture into a wall of false errors. A
        # reassembled message spans segments in any case, so there is no
        # one checksum over a message's octets to report.
        def tcp(off, ip_end, src, dst)
          return none unless room?(off, 20, 'TCP header')
          doff = (u8(off + 12) >> 4) * 4
          if doff < 20
            @errors << "TCP data offset #{doff} is below the 20 octet minimum"
            return none
          end
          return none unless room?(off, doff, 'TCP header and options')
          data = off + doff
          payload = data < ip_end ? @b[data, ip_end - data] : String.new
          Segment.new(src, dst, u16(off), u16(off + 2), u32(off + 4), payload, @errors)
        end

      end

      # Reads one BGP message's octets field by field. The caller has
      # already framed it, so these octets are a message and nothing else;
      # offsets are from the message's first octet.
      class Messages

        def initialize(octets)
          @b = octets
          @errors = []
        end

        def run
          fields = []
          summary = header(fields)
          decode
          Result.new(summary, @b.bytesize, fields.compact, @errors, @decoded, @decoded_error)
        end

        private

        # Hands the octets to the library's own decoder, which is what
        # says whether bgp4r can read this message at all and what it
        # makes of a received UPDATE. The fields above are offsets and
        # nothing else; this is meaning, and the two are kept apart on
        # purpose: a message bgp4r cannot decode still gets every field it
        # has, with its hex, because a capture tool that drops what it
        # cannot read is useless for the job this library exists to do.
        #
        # **Three kinds of entry land in one errors list and the wording
        # is what tells them apart**, since the envelope ospfv2 set has
        # one channel. CLAUDE.md's Conventions keep these separate inside
        # the library and the distinction matters as much here: a finding
        # from validation.rb is what the **peer** got wrong, an
        # Attr::Gap is bgp4r's own missing code, and a decoder that
        # raises is bgp4r's gap too. So each is prefixed with whose fault
        # it is, and nothing here calls bgp4r's coverage a protocol
        # error. Nothing is raised: StandardError is rescued broadly
        # because a captured message is arbitrary octets and no reason to
        # stop reading a capture.
        def decode
          msg = Message.factory(@b.dup.is_packed)
          begin
            @decoded = msg.to_s
          rescue StandardError => error
            @decoded_error = "bgp4r could not print this message: #{error.class}: #{error.message}"
          end
          return unless msg.respond_to?(:path_attribute) and msg.path_attribute
          msg.path_attribute.errors.each do |f|
            @errors << "the sender got this wrong: #{f}"
          end
          msg.path_attribute.undecoded.each do |g|
            @errors << "bgp4r could not decode this: #{g}"
          end
        rescue StandardError => e
          @errors << "bgp4r could not decode this message: #{e.class}: #{e.message}"
        end

        def room?(off, len, what)
          return true if off + len <= @b.bytesize
          @errors << "#{what}: needs #{len} octets at #{off}, the message ends at #{@b.bytesize}"
          false
        end

        def u8(off)  ; @b.getbyte(off) ; end
        def u16(off) ; @b[off, 2].unpack('n')[0] ; end
        def u32(off) ; @b[off, 4].unpack('N')[0] ; end
        def hex(off, len) ; @b[off, len].unpack('H*')[0] ; end

        def field(name, off, len, value = nil, show = nil, mask = nil, children = nil)
          Field.new(name, off, len, value, show, mask, children, nil)
        end

        def num(name, off, len, show = nil)
          v = len == 1 ? u8(off) : (len == 2 ? u16(off) : u32(off))
          field(name, off, len, v, show)
        end

        def data(name, off, len)
          field(name, off, len, hex(off, len)) if len > 0
        end

        # A one octet bit field: a child per named bit, and whatever is
        # left as a reserved child, so every bit of the octet belongs to a
        # field.
        def bits(name, off, names)
          v = u8(off)
          kids = names.collect do |mask, n|
            field(n, off, 1, (v & mask).zero? ? 0 : 1, (v & mask).zero? ? '0' : '1', mask)
          end
          rsvd = 0xff & ~names.keys.inject(0) { |a, m| a | m }
          kids << field('unused', off, 1, v & rsvd, nil, rsvd) unless rsvd.zero?
          set = names.select { |m, _| (v & m) > 0 }.collect { |_, n| n }
          field(name, off, 1, v, set.empty? ? '0x%02x' % v : set.join(' '), nil, kids)
        end

        # RFC 4271 section 4.1.
        def header(fields)
          unless room?(0, HEADER_SIZE, 'BGP message header')
            fields << data('data', 0, @b.bytesize)
            return 'truncated BGP message'
          end
          marker = @b[0, MARKER_SIZE]
          ones = marker == ("\xff".b * MARKER_SIZE)
          @errors << 'the Marker is not all ones (RFC 4271 section 4.1)' unless ones
          len = u16(MARKER_SIZE)
          type = u8(18)
          name = TYPES[type] || "type #{type}"
          kids = [field('marker', 0, MARKER_SIZE, marker.unpack('H*')[0],
                        ones ? 'all ones' : 'not all ones'),
                  field('length', MARKER_SIZE, 2, len, len.to_s),
                  field('type', 18, 1, type, "#{type} #{name}")]
          fields << field('BGP header', 0, HEADER_SIZE, nil, name, nil, kids)
          @errors << "the Length field says #{len} and #{@b.bytesize} octets were framed" if len != @b.bytesize
          @errors << "the Length field says #{len}, below the 19 octet minimum (RFC 4271 section 4.1)" if len < MIN_LENGTH
          @errors << "the Length field says #{len}, above the 4096 octet maximum (RFC 4271 section 4.1)" if len > Message::MAX_SIZE
          body = HEADER_SIZE
          extra = case type
                  when Message::OPEN          then open(fields, body)
                  when Message::UPDATE        then update(fields, body)
                  when Message::NOTIFICATION  then notification(fields, body)
                  when Message::KEEPALIVE     then keepalive(fields, body)
                  when Message::ROUTE_REFRESH then route_refresh(fields, body)
                  else
                    # RFC 4271 section 6.1 makes an unrecognised type a Bad
                    # Message Type, and bgp4r keeps the octets rather than
                    # inventing a layout for them.
                    @errors << "message type #{type} is not one bgp4r decodes"
                    fields << data('body', body, @b.bytesize - body)
                    nil
                  end
          extra ? "#{name} #{extra}" : name
        end

        # RFC 4271 section 4.2, with the extended Optional Parameters
        # Length of RFC 9072 section 2.
        def open(fields, off)
          return (fields << data('body', off, @b.bytesize - off)) && nil unless room?(off, 10, 'OPEN body')
          kids = [num('version', off, 1),
                  num('my autonomous system', off + 1, 2),
                  num('hold time', off + 3, 2, "#{u16(off + 3)}s"),
                  field('BGP identifier', off + 5, 4, @b[off + 5, 4].unpack('C4').join('.'),
                        @b[off + 5, 4].unpack('C4').join('.'))]
          # RFC 9072 section 2, Figure 2: the octet after the one octet
          # Non-Ext OP Len. is the Non-Ext OP Type, and "On receipt, a
          # value of 255 for this field is the indication that the extended
          # format is in use". That octet alone decides, as Open#parse has
          # it, because the length before it "MUST be ignored on receipt
          # once the use of the extended format is determined positively".
          extended = @b.bytesize > off + 10 && u8(off + 10) == 255
          if extended
            return (fields << data('body', off, @b.bytesize - off)) && nil unless room?(off, 13, 'extended OPEN body')
            kids << num('non-ext optional parameters length', off + 9, 1)
            kids << field('non-ext optional parameters type', off + 10, 1, 255, '255 Extended Length')
            parm_len = u16(off + 11)
            kids << field('optional parameters length', off + 11, 2, parm_len, parm_len.to_s)
            parms = off + 13
          else
            parm_len = u8(off + 9)
            kids << field('optional parameters length', off + 9, 1, parm_len, parm_len.to_s)
            parms = off + 10
          end
          fields << field('OPEN', off, parms - off, nil, nil, nil, kids)
          @errors << "the Optional Parameters Length says #{parm_len} and " \
                     "#{@b.bytesize - parms} octets followed it" if parm_len != @b.bytesize - parms
          optional_parameters(fields, parms, extended)
          "AS #{u16(off + 1)} holdtime #{u16(off + 3)}s id #{@b[off + 5, 4].unpack('C4').join('.')}"
        end

        # RFC 4271 section 4.2: a parameter is a 1 octet Parameter Type, a
        # 1 octet Parameter Length and the value. RFC 9072 section 2
        # widens that length to two octets in the extended form.
        def optional_parameters(fields, off, extended)
          lenw = extended ? 2 : 1
          head = 1 + lenw
          while off < @b.bytesize
            unless room?(off, head, 'optional parameter header')
              fields << data('data', off, @b.bytesize - off)
              return
            end
            type = u8(off)
            len = lenw == 1 ? u8(off + 1) : u16(off + 1)
            kids = [field('parameter type', off, 1, type,
                          type == 2 ? '2 Capabilities' : type.to_s),
                    field('parameter length', off + 1, lenw, len, len.to_s)]
            avail = @b.bytesize - off - head
            if len > avail
              @errors << "optional parameter at #{off} says #{len} octets and #{avail} are left"
              len = avail
            end
            # RFC 5492 section 4: one Capabilities parameter carries a
            # sequence of capabilities, each a 1 octet code, a 1 octet
            # length and the value. RFC 9072 widens the parameter header
            # and nothing else, so these two stay one octet each.
            if type == 2
              kids << capabilities(off + head, len)
            elsif len > 0
              kids << data('parameter value', off + head, len)
            end
            fields << field('optional parameter', off, head + len, nil,
                            type == 2 ? 'Capabilities' : "type #{type}", nil, kids.compact)
            off += head + len
          end
        end

        def capabilities(off, len)
          kids = []
          stop = off + len
          at = off
          while at < stop
            unless at + 2 <= stop
              @errors << "capability header at #{at} runs past the parameter"
              kids << data('data', at, stop - at)
              break
            end
            code = u8(at)
            clen = u8(at + 1)
            name = CAPABILITIES[code]
            cap = [field('capability code', at, 1, code, name ? "#{code} #{name}" : code.to_s),
                   field('capability length', at + 1, 1, clen, clen.to_s)]
            avail = stop - at - 2
            if clen > avail
              @errors << "capability at #{at} says #{clen} octets and #{avail} are left"
              clen = avail
            end
            cap << data('capability value', at + 2, clen)
            kids << field('capability', at, 2 + clen, nil, name || "code #{code}", nil, cap.compact)
            at += 2 + clen
          end
          return nil if kids.empty?
          field('capabilities', off, len, nil, nil, nil, kids)
        end

        # RFC 4271 section 4.3.
        def update(fields, off)
          return (fields << data('body', off, @b.bytesize - off)) && nil unless room?(off, 2, 'UPDATE body')
          wlen = u16(off)
          fields << field('withdrawn routes length', off, 2, wlen, wlen.to_s)
          at = off + 2
          avail = @b.bytesize - at
          if wlen > avail
            @errors << "the Withdrawn Routes Length says #{wlen} and #{avail} octets are left"
            wlen = avail
          end
          withdrawn = prefixes('withdrawn routes', at, wlen)
          fields << withdrawn if withdrawn
          nw = withdrawn ? withdrawn.children.size : 0
          at += wlen
          unless room?(at, 2, 'total path attribute length')
            fields << data('data', at, @b.bytesize - at)
            return "0 attributes 0 nlri #{nw} withdrawn"
          end
          alen = u16(at)
          fields << field('total path attribute length', at, 2, alen, alen.to_s)
          at += 2
          avail = @b.bytesize - at
          if alen > avail
            @errors << "the Total Path Attribute Length says #{alen} and #{avail} octets are left"
            alen = avail
          end
          attrs = path_attributes(at, alen)
          fields << attrs if attrs
          at += alen
          nlri = prefixes('network layer reachability information', at, @b.bytesize - at)
          fields << nlri if nlri
          nn = nlri ? nlri.children.size : 0
          na = attrs ? attrs.children.size : 0
          if nw.zero? and nn.zero? and na.zero?
            # RFC 4724 section 2: an UPDATE with no reachable NLRI and no
            # withdrawn routes is the End-of-RIB marker.
            'End-of-RIB'
          else
            "#{na} attribute#{na == 1 ? '' : 's'} #{nn} nlri #{nw} withdrawn"
          end
        end

        # RFC 4271 section 4.3: "Each IP address prefix is encoded as a
        # 2-tuple", a 1 octet Length in bits and "the minimum number of
        # octets necessary to contain the value", which is (bits + 7) / 8.
        # A Path Identifier (RFC 7911 section 3) is **not** read here:
        # whether one is present is a property of the session's
        # capabilities and not of these octets, so reading one would be a
        # guess. A session that negotiated ADD-PATH therefore shows four
        # octets of identifier as a wrong prefix length, which is what the
        # octets say on their own.
        def prefixes(name, off, len)
          return nil if len <= 0
          kids = []
          at = off
          stop = off + len
          while at < stop
            bits = u8(at)
            width = (bits + 7) / 8
            if at + 1 + width > stop
              @errors << "a prefix at #{at} of #{bits} bits needs #{width} octets and " \
                         "#{stop - at - 1} are left"
              kids << data('data', at, stop - at)
              break
            end
            octets = @b[at + 1, width]
            show = width.zero? ? "0.0.0.0/0" : "#{(octets.unpack('C*') + [0, 0, 0, 0])[0, 4].join('.')}/#{bits}"
            kids << field('prefix', at, 1 + width, show, show, nil,
                          [field('prefix length', at, 1, bits, "#{bits} bits"),
                           data('prefix', at + 1, width)].compact)
            at += 1 + width
          end
          field(name, off, len, nil, "#{kids.size} prefix#{kids.size == 1 ? '' : 'es'}", nil, kids)
        end

        # RFC 4271 section 4.3: a path attribute is an Attribute Type, two
        # octets of Flags and Type Code, then a length of one octet, or two
        # "if the Extended Length attribute flag is set".
        def path_attributes(off, len)
          return nil if len <= 0
          kids = []
          at = off
          stop = off + len
          while at < stop
            unless at + 3 <= stop
              @errors << "a path attribute header at #{at} runs past the attributes"
              kids << data('data', at, stop - at)
              break
            end
            flags = u8(at)
            type = u8(at + 1)
            lenw = (flags & 0x10).zero? ? 1 : 2
            unless at + 2 + lenw <= stop
              @errors << "a path attribute length at #{at + 2} runs past the attributes"
              kids << data('data', at, stop - at)
              break
            end
            alen = lenw == 1 ? u8(at + 2) : u16(at + 2)
            reg = Attr.by_type(type)
            name = reg ? reg.name.to_s : "type #{type}"
            akids = [bits('flags', at, ATTR_FLAGS),
                     field('type code', at + 1, 1, type, "#{type} #{name}"),
                     field('length', at + 2, lenw, alen, alen.to_s)]
            avail = stop - at - 2 - lenw
            if alen > avail
              @errors << "the path attribute at #{at} says #{alen} octets and #{avail} are left"
              alen = avail
            end
            akids << data('value', at + 2 + lenw, alen)
            kids << field('path attribute', at, 2 + lenw + alen, nil, name, nil, akids.compact)
            at += 2 + lenw + alen
          end
          field('path attributes', off, len, nil,
                "#{kids.size} attribute#{kids.size == 1 ? '' : 's'}", nil, kids)
        end

        # RFC 4271 section 4.5.
        def notification(fields, off)
          return (fields << data('body', off, @b.bytesize - off)) && nil unless room?(off, 2, 'NOTIFICATION body')
          code = u8(off)
          sub = u8(off + 1)
          cname = Notification.code_to_s(code).to_s
          sname = Notification.code_to_s(code, sub).to_s
          kids = [field('error code', off, 1, code, "#{code} #{cname}"),
                  field('error subcode', off + 1, 1, sub, "#{sub} #{sname}")]
          kids << data('data', off + 2, @b.bytesize - off - 2)
          fields << field('NOTIFICATION', off, @b.bytesize - off, nil,
                          "#{cname} / #{sname}", nil, kids.compact)
          "#{code}/#{sub} #{cname}#{sname.empty? ? '' : " / #{sname}"}"
        end

        # RFC 4271 section 4.4: "A KEEPALIVE message consists of only the
        # message header and has a length of 19 octets." Anything after it
        # is kept rather than dropped.
        def keepalive(fields, off)
          return nil if off >= @b.bytesize
          @errors << "a KEEPALIVE carries #{@b.bytesize - off} octets after its header " \
                     '(RFC 4271 section 4.4)'
          fields << data('body', off, @b.bytesize - off)
          nil
        end

        # RFC 2918 section 3 gives the AFI, a Reserved octet and the SAFI.
        # RFC 7313 section 3.2 redefines the Reserved octet as the Message
        # Subtype. What follows is the ORF entries of RFC 5291 section 4,
        # kept as octets here rather than framed: an entry's own length is
        # readable but its meaning is per ORF type, which is bgp4r's
        # Orf_route_refresh and not a dissector's business.
        def route_refresh(fields, off)
          return (fields << data('body', off, @b.bytesize - off)) && nil unless room?(off, 4, 'ROUTE-REFRESH body')
          afi = u16(off)
          sub = u8(off + 2)
          safi = u8(off + 3)
          aname = ::IANA.afi?(afi) || "afi #{afi}"
          sname = ::IANA.safi?(safi) || "safi #{safi}"
          kids = [field('afi', off, 2, afi, "#{afi} #{aname}"),
                  field('message subtype', off + 2, 1, sub,
                        "#{sub} #{REFRESH_SUBTYPES[sub] || 'unassigned'}"),
                  field('safi', off + 3, 1, safi, "#{safi} #{sname}")]
          kids << data('outbound route filters', off + 4, @b.bytesize - off - 4)
          fields << field('ROUTE-REFRESH', off, @b.bytesize - off, nil, nil, nil, kids.compact)
          "#{aname}/#{sname} #{REFRESH_SUBTYPES[sub] || sub}"
        end

      end

    end
  end
end
