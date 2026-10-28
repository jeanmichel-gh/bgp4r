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

require 'bgp/rib/route'
# For BGP::Message::MAX_SIZE. route.rb pulls it in transitively today, but
# the dependency belongs here, where the constant is read.
require 'bgp/messages/message'

module BGP
  module Rib

    # Turns what we decided to send one peer into UPDATE messages.
    #
    #   b = UpdateBuilder.new(session_info: neighbor.session_info)
    #   msgs = b.build(:withdraw => [UpdateBuilder::Withdraw.new('10.9.0.0/16')],
    #                  :announce => [UpdateBuilder::Announce.new('10.1.0.0/16', pa, '10.0.0.1')])
    #
    # Pure, like Export: it reads tuples and returns messages, sends nothing
    # and keeps nothing, so the packing can be tested on its own.
    #
    # Prefixes that share a path attribute set travel in one UPDATE, which is
    # the whole economy of BGP: one attribute set, many prefixes. The grouping
    # key is the encoded attributes, the next hop, and the address family, so
    # routes that happen to agree are packed together even when they came from
    # different peers.
    #
    # Two things decide which field a prefix goes in. IPv4 unicast uses the
    # NLRI and Withdrawn Routes fields of RFC 4271 section 4.3, which carry
    # IPv4 only. Every other family uses MP_REACH_NLRI and MP_UNREACH_NLRI
    # (RFC 4760 sections 3 and 4), where the next hop travels inside the
    # attribute rather than in NEXT_HOP.
    #
    # Withdrawals come before announcements, the same order PeerAdapter
    # applies a received UPDATE in, so a prefix in both ends up announced.
    class UpdateBuilder

      # The message limit of RFC 4271 section 4, read from the one place it
      # is defined. RFC 8654 raises it when both speakers negotiate
      # extended messages, which is what max_size is for; bgp4r does not
      # negotiate that capability.
      MAX_MESSAGE_SIZE = BGP::Message::MAX_SIZE

      # One prefix to advertise. path_attribute is what Export returned, so
      # it carries no MP_REACH_NLRI; next_hop is what Export chose.
      Announce = Struct.new(:prefix, :path_attribute, :next_hop, :path_id)

      # One prefix to withdraw.
      Withdraw = Struct.new(:prefix, :path_id)

      attr_reader :session_info, :max_size

      # session_info: a Neighbor#session_info, so messages are sized the way
      #   that session will encode them. Without one the 4-octet AS form is
      #   used, which is the larger, so a message sized without it still
      #   fits when it is sent.
      def initialize(session_info: nil, max_size: MAX_MESSAGE_SIZE)
        @session_info = session_info
        @max_size = Integer(max_size)
        @info = session_info || Update::Info.new(true)
      end

      # Returns the UPDATE messages, withdrawals first.
      def build(announce: [], withdraw: [])
        msgs = []
        group_withdrawals(withdraw).each do |(afi, safi), entries|
          pack(entries) { |batch| msgs << checked(withdrawal_message(afi, safi, batch), batch) }
        end
        group_announcements(announce).each do |key, entries|
          _attrs, next_hop, afi, safi = key
          pa = entries.first.path_attribute
          pack(entries) do |batch|
            msgs << checked(announcement_message(afi, safi, next_hop, pa, batch), batch)
          end
        end
        msgs
      end

      # The address family of a prefix, as [afi, safi]. Only unicast is
      # built here, because that is what a Route can hold: see
      # PeerAdapter::MP_SAFIS for why a label or a Route Distinguisher needs
      # more than a prefix.
      def self.family(prefix)
        [prefix.to_s.include?(':') ? IANA::AFI::IPv6 : IANA::AFI::IPv4, IANA::SAFI::UNICAST]
      end

      private

      # Every message is measured once it is built, so an error in the
      # arithmetic above shows up here rather than as an oversized message
      # on the wire. One prefix that cannot fit on its own is the only case
      # that can reach this, since a prefix is never split, and it is the
      # case RFC 4271 section 9.2 rules on: when "a single route doesn't
      # fit into the message, the BGP speaker MUST not advertise the route
      # to its peers and MAY choose to log an error locally". Raising is how
      # that reaches Router#send_messages, which logs it and records it in
      # skipped rather than sending anything. Section 4, cited in the
      # message below, is where the 4096 octet limit itself comes from.
      def checked(msg, batch)
        size = msg.encode(@info).bytesize
        return msg if size <= @max_size
        raise ArgumentError, "#{batch.size} prefix#{'es' unless batch.size == 1} make a " \
                             "#{size} octet UPDATE; BGP allows #{@max_size} " \
                             '(RFC 4271 section 4)'
      end

      def group_withdrawals(list)
        list.group_by { |w| UpdateBuilder.family(w.prefix) }
      end

      # Routes with the same attributes, next hop and family share a message.
      # The attributes are compared by their encoded octets in the 4-octet AS
      # form, as AdjRibOut compares them, because Export builds a new
      # Path_attribute every run.
      def group_announcements(list)
        list.group_by do |a|
          afi, safi = UpdateBuilder.family(a.prefix)
          [a.path_attribute.encode(true), a.next_hop.to_s, afi, safi]
        end
      end

      # Yields batches that each fit in one message.
      #
      # The size is worked out rather than measured per prefix, because
      # measuring would mean encoding the message again for every prefix
      # added, and a full table is about a million of them. RFC 4271 section
      # 4.3 gives the arithmetic: a prefix is a 2-tuple <length, prefix>
      # where the prefix field is "the minimum number of trailing bits that
      # make the field end on an octet boundary", so the tuple is
      # 1+(length+7)/8 octets, and 4 more with an add-path Path Identifier
      # in front (RFC 7911 section 3). The finished message is then measured
      # once, so an arithmetic slip shows up as a raised error and not as an
      # oversized message on the wire.
      def pack(entries)
        batch = []
        room = nil
        entries.each do |e|
          room = room_for(entries.first) if room.nil?
          cost = prefix_cost(e)
          if !batch.empty? && cost > room
            yield batch
            batch = []
            room = room_for(entries.first)
          end
          batch << e
          room -= cost
        end
        yield batch unless batch.empty?
      end

      # How many octets of prefixes one message can hold, which is the limit
      # less everything else that message carries.
      def room_for(entry)
        @max_size - overhead(entry)
      end

      # The message with no prefixes in it at all, measured.
      def overhead(entry)
        afi, safi = UpdateBuilder.family(entry.prefix)
        msg = if entry.is_a?(Withdraw)
                withdrawal_message(afi, safi, [])
              else
                announcement_message(afi, safi, entry.next_hop, entry.path_attribute, [])
              end
        msg.encode(@info).bytesize
      rescue StandardError
        # An empty MP attribute some family refuses to build: fall back to
        # the header plus a generous allowance, and let the final check
        # catch anything that still does not fit.
        19 + 4
      end

      # RFC 4271 section 4.3, plus 4 octets for a Path Identifier.
      def prefix_cost(entry)
        ip = IPAddr.new(entry.prefix.to_s)
        1 + (ip.prefix + 7) / 8 + (entry.path_id ? 4 : 0)
      end

      def nlris(entries)
        entries.map { |e| e.path_id ? { :path_id => e.path_id, :nlri => e.prefix } : e.prefix }
      end

      # MP_REACH_NLRI and MP_UNREACH_NLRI want the Path Identifier flag set
      # on the attribute as well as on each prefix (RFC 7911 section 3).
      def mp_hash(afi, safi, entries)
        h = { :afi => afi, :safi => safi }
        h[:nlris] = entries.map do |e|
          e.path_id ? { :path_id => e.path_id, :prefix => e.prefix } : e.prefix
        end
        h[:path_id] = true if entries.any? { |e| e.path_id }
        h
      end

      def withdrawal_message(afi, safi, entries)
        if afi == IANA::AFI::IPv4 && safi == IANA::SAFI::UNICAST
          # RFC 4271 section 4.3: the Withdrawn Routes field, IPv4 only.
          Update.new(Withdrawn.new(*nlris(entries)))
        else
          # RFC 4760 section 4: MP_UNREACH_NLRI, which names its own family.
          Update.new(Path_attribute.new(Mp_unreach.new(mp_hash(afi, safi, entries))))
        end
      end

      def announcement_message(afi, safi, next_hop, path_attribute, entries)
        if afi == IANA::AFI::IPv4 && safi == IANA::SAFI::UNICAST
          # The attributes already carry NEXT_HOP, which Export set.
          Update.new(copy(path_attribute), Nlri.new(*nlris(entries)))
        else
          # RFC 4760 section 3: the next hop travels inside MP_REACH_NLRI,
          # so NEXT_HOP has no place in the message.
          pa = copy(path_attribute)
          pa.delete(Next_hop)
          h = mp_hash(afi, safi, entries).merge(:nexthop => [next_hop.to_s])
          pa << Mp_reach.new(h)
          Update.new(pa)
        end
      end

      # Each message gets its own attributes, so a message built here never
      # shares a mutable attribute set with another one or with the caller.
      def copy(path_attribute)
        Path_attribute.new(path_attribute.encode(true), true)
      end
    end

  end
end
