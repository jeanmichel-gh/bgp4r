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

require 'bgp/bmp/messages'

module BGP
  module Bmp

    # What a station finds in one message's octets, against RFC 7854
    # and RFC 9069. BMP has no error codes and nothing goes back to the
    # router (section 3.2), so a finding is a name and a detail, for the
    # station to log or count. `ignore` findings are what section 4.1
    # and 4.8 say to pass over; the rest break a MUST.
    module Validation

      Finding = Struct.new(:name, :detail) do
        def ignore? ; IGNORE.include?(name) ; end
        def to_s ; "#{name}: #{detail}" ; end
      end

      # Section 4.1, "MUST ignore unrecognized message types"; section
      # 4.8, "MUST ignore unrecognized stat types".
      IGNORE = %i[unknown_type unknown_stat].freeze

      # The low bits section 4.2 and RFC 9069 section 4.2 reserve, by
      # peer type: "MUST be transmitted as 0".
      RESERVED_FLAGS = { 0 => 0x1f, 1 => 0x1f, 2 => 0x1f, 3 => 0x7f }.freeze

      def self.finding(name, detail) ; Finding.new(name, detail) ; end

      # The findings for one message's octets; [] for none.
      def self.check(octets)
        octets = octets.b
        return [finding(:short, "#{octets.bytesize} octets, shorter than the #{HEADER} of a header")] if octets.bytesize < HEADER
        version, length, type = octets.unpack('CNC')
        found = []
        # Section 4.1: "This is set to '3' ... Version 0 is reserved and
        # MUST NOT be sent."
        return [finding(:version, "version #{version}, where 3 is BMP's")] if version != VERSION
        found << finding(:length, "Message Length #{length}, the message is #{octets.bytesize} octets") if length != octets.bytesize
        return found << finding(:unknown_type, "Message Type #{type}") unless Message::TYPES.key?(type)
        body = octets.byteslice(HEADER..) || ''.b
        if Message::TYPES[type] <= Peer_message
          return found << finding(:short, "#{body.bytesize} octets after the header, short of a per-peer header") if body.bytesize < PER_PEER
          found.concat(per_peer_findings(body.byteslice(0, PER_PEER)))
        end
        found.concat(send("#{Message::TYPES[type].name.split('::').last.downcase}_findings", body)) if found.empty?
        found
      end

      # Section 4.2, and RFC 9069 sections 4.2 and 5.1.
      def self.per_peer_findings(peer)
        type, flags = peer.unpack('CC')
        return [finding(:peer_type, "Peer Type #{type}")] unless PEER_TYPES.key?(type)
        found = []
        found << finding(:reserved_flags, format('Peer Flags 0x%02x for peer type %d', flags, type)) if flags & RESERVED_FLAGS[type] != 0
        if type == LOC_RIB && peer.byteslice(10, 16) != "\0".b * 16
          found << finding(:loc_rib_address, 'a Loc-RIB peer with a Peer Address, which is "Zero-filled"')
        end
        found
      end

      def self.route_monitoring_findings(body)
        bgp_findings(body.byteslice(PER_PEER..), 'Route Monitoring', 2)
      end

      # Section 4.8: a count, then that many stats; "at least one
      # statistic MUST be carried".
      def self.stats_report_findings(body)
        rest = body.byteslice(PER_PEER..) || ''.b
        return [finding(:short, 'a Statistics Report with no Stats Count')] if rest.bytesize < 4
        count = rest.unpack1('N')
        found = []
        found << finding(:no_stats, 'a Statistics Report with a Stats Count of 0') if count.zero?
        rest = rest.byteslice(4..)
        n = 0
        while rest.bytesize >= 4
          type, len = rest.unpack('nn')
          return found << finding(:length, "Stat Type #{type}: Stat Len #{len} overruns the message") if 4 + len > rest.bytesize
          kind, = STATS[type]
          if kind.nil?
            found << finding(:unknown_stat, "Stat Type #{type}")
          elsif len != STAT_LENGTH[kind]
            found << finding(:unknown_stat, "Stat Type #{type} with #{len} octets, where it has #{STAT_LENGTH[kind]}")
          end
          rest = rest.byteslice(4 + len..)
          n += 1
        end
        found << finding(:length, "#{rest.bytesize} octets left after the stats") unless rest.empty?
        found << finding(:count, "Stats Count #{count}, #{n} stats") if n != count
        found
      end

      # Section 4.9 and RFC 9069 section 5.3: the data each reason has.
      def self.peer_down_findings(body)
        rest = body.byteslice(PER_PEER..) || ''.b
        return [finding(:short, 'a Peer Down with no Reason')] if rest.empty?
        reason = rest.getbyte(0)
        data = rest.byteslice(1..)
        case reason
        when 1, 3 then bgp_findings(data, "Peer Down reason #{reason}", 3)
        when 2 then data.bytesize == 2 ? [] : [finding(:length, "Peer Down reason 2 with #{data.bytesize} octets, where the FSM Event is 2")]
        when 4, 5 then data.empty? ? [] : [finding(:length, "Peer Down reason #{reason} with #{data.bytesize} octets of data")]
        when 6 then tlv_findings(data, 'Peer Down')
        else [finding(:reason, "Peer Down reason #{reason}")]
        end
      end

      # Section 4.10: two OPENs, then Information TLVs.
      def self.peer_up_findings(body)
        rest = body.byteslice(PER_PEER..) || ''.b
        return [finding(:short, 'a Peer Up shorter than its addresses and ports')] if rest.bytesize < 20
        rest = rest.byteslice(20..)
        found = []
        2.times do |i|
          which = i.zero? ? 'Sent OPEN' : 'Received OPEN'
          f = bgp_findings(rest, "Peer Up #{which}", 1, whole: false)
          return found.concat(f) unless f.empty?
          rest = rest.byteslice(rest.unpack1('@16n')..)
        end
        found.concat(tlv_findings(rest, 'Peer Up'))
      end

      # Section 4.3: "The sysDescr and sysName Information TLVs MUST be
      # sent".
      def self.initiation_findings(body)
        found = tlv_findings(body, 'Initiation')
        types = Tlv.list(body).collect { |o| o.unpack1('n') }
        { 1 => 'sysDescr', 2 => 'sysName' }.each do |t, n|
          found << finding(:missing, "an Initiation with no #{n}") unless types.include?(t)
        end
        found
      end

      # Section 4.5: the Reason TLV, "Inclusion of this TLV is REQUIRED".
      def self.termination_findings(body)
        found = tlv_findings(body, 'Termination')
        reasons = Tlv.list(body).select { |o| o.unpack1('n') == 1 }
        found << finding(:missing, 'a Termination with no Reason') if reasons.empty?
        reasons.each { |o| found << finding(:length, 'a Reason that is not 2 octets') if o.unpack1('@2n') != 2 }
        found
      end

      # Section 4.7: "If the BGP Message TLV occurs ... it MUST occur
      # last".
      def self.route_mirroring_findings(body)
        rest = body.byteslice(PER_PEER..) || ''.b
        found = tlv_findings(rest, 'Route Mirroring')
        types = Tlv.list(rest).collect { |o| o.unpack1('n') }
        found << finding(:order, 'a BGP Message TLV before the last') if types.include?(0) && types.last != 0
        found
      end

      # TLVs end to end, each length inside the message.
      def self.tlv_findings(octets, what)
        while octets.bytesize >= 4
          type, len = octets.unpack('nn')
          return [finding(:length, "#{what}: TLV type #{type}, length #{len}, overruns the message")] if 4 + len > octets.bytesize
          octets = octets.byteslice(4 + len..)
        end
        octets.empty? ? [] : [finding(:length, "#{what}: #{octets.bytesize} octets left, short of a TLV")]
      end

      # A BGP message of type at the start of octets: its marker, its
      # Length, and, when whole, the octets end with it.
      def self.bgp_findings(octets, what, type, whole: true)
        octets = octets.to_s
        return [finding(:bgp, "#{what}: #{octets.bytesize} octets, short of a BGP header")] if octets.bytesize < 19
        found = []
        found << finding(:bgp, "#{what}: the BGP marker is not all ones") if octets.byteslice(0, 16) != "\xff".b * 16
        length = octets.unpack1('@16n')
        found << finding(:bgp, "#{what}: BGP Length #{length}, the octets are #{octets.bytesize}") if
          length < 19 || length > octets.bytesize || (whole && length != octets.bytesize)
        found << finding(:bgp, "#{what}: BGP type #{octets.getbyte(18)}, where #{type} is expected") if octets.getbyte(18) != type
        found
      end
    end
  end
end
