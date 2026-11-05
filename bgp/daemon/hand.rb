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

require 'bgp4r'
require 'bgp/rib'

module BGP
  module Daemon

    # What bgp4rd sent to a peer by hand, per peer and per prefix: the
    # list `show.adj_out` answers under `hand` and `show.peers` counts.
    #
    # **The Adj-RIB-Out is never patched for a message sent by hand**,
    # because after one the daemon cannot know what the peer holds. A
    # peer that treats a fault as a withdrawal, as RFC 7606 asks for most
    # cases, holds nothing for the prefix; a peer that resets holds nothing
    # from us at all; a peer that discards an attribute holds a route we
    # never chose. So the record says what went out and when, and the
    # Adj-RIB-Out keeps saying what the daemon last sent the normal way.
    # docs/console.md section 10 has the decision.
    #
    # A row clears three ways:
    #
    # * the daemon sends that prefix to that peer the normal way, which
    #   `Rib::Router#on_sent` reports, since from then on the peer holds
    #   what the Adj-RIB-Out says;
    # * the session ends, since the peer then holds nothing from us;
    # * `peer.resend`, which sends the daemon's own answer for each row.
    #
    # Three kinds of row:
    #
    #   prefix       a unicast prefix, IPv4 or IPv6, read out of the NLRI,
    #                the Withdrawn Routes or an MP_REACH_NLRI or
    #                MP_UNREACH_NLRI of SAFI 1. `peer.resend` handles it.
    #   family       an NLRI of any other family, with :family set to
    #                "AFI/SAFI". The daemon holds no table for it, so it has
    #                no answer of its own to resend; it clears when the
    #                session ends.
    #   whole peer   :prefix nil, when octets sent by hand do not read
    #                back as a message at all, so the daemon cannot say
    #                what they touched. It clears when the session ends.
    class Hand

      def initialize
        @lock = Mutex.new
        @rows = {}   # address => { key => row }
      end

      # Records what one message sent by hand touches on one peer, read
      # back out of the message itself. msg is the object or the octets
      # that went to the session. Answers the rows added.
      def record(address, msg, verb, session_info = nil, at = Time.now)
        rows = Hand.read_back(msg, session_info)
        rows.each { |r| r.merge!(:verb => verb, :at => at) }
        @lock.synchronize do
          table = (@rows[address.to_s] ||= {})
          rows.each { |r| table[[r[:prefix], r[:family]]] = r }
        end
        rows
      end

      # The daemon sent these prefixes to this peer the normal way.
      def sent(address, prefixes)
        keys = prefixes.collect { |p| [Hand.normalize(p), nil] }
        @lock.synchronize do
          table = @rows[address.to_s]
          next unless table
          keys.each { |k| table.delete(k) }
          @rows.delete(address.to_s) if table.empty?
        end
        self
      end

      # The session to this peer ended, or every row is answered.
      def reset(address)
        @lock.synchronize { @rows.delete(address.to_s) }
        self
      end

      # The rows of one peer, oldest first, as plain data: :prefix, :verb
      # and :at, an ISO 8601 time in `Recorder.iso`'s format so it reads
      # like every other time the daemon answers, and :family for a row of another
      # family. A whole peer row has a nil :prefix.
      def rows(address)
        list = @lock.synchronize { (@rows[address.to_s] || {}).values.collect(&:dup) }
        list.each_with_index.sort_by { |r, i| [r[:at], i] }.collect do |r, _i|
          row = { :prefix => r[:prefix], :verb => r[:verb], :at => Recorder.iso(r[:at]) }
          row[:family] = r[:family] if r[:family]
          row
        end
      end

      def count(address)
        @lock.synchronize { (@rows[address.to_s] || {}).size }
      end

      # The unicast prefixes of one peer's rows, which are the ones
      # `peer.resend` can answer.
      def prefixes(address)
        @lock.synchronize do
          (@rows[address.to_s] || {}).values.select { |r| r[:prefix] && !r[:family] }
                                     .collect { |r| r[:prefix] }
        end
      end

      # A prefix as `Rib::Route` keys one, or the text unchanged when it
      # is not an address prefix.
      def self.normalize(prefix)
        BGP::Rib::Route.normalize(prefix)
      rescue ArgumentError
        prefix.to_s
      end

      # What msg touches, as rows with :prefix and, for another family,
      # :family. An UPDATE object is read as it is; octets are read as a
      # message first.
      #
      # **Octets that do not read as a message flag the whole peer**, and
      # octets that read as a message other than an UPDATE flag nothing,
      # since a KEEPALIVE or a ROUTE-REFRESH changes no route and a
      # NOTIFICATION ends the session, which clears the list anyway.
      def self.read_back(msg, session_info = nil)
        msg = message(msg, session_info) if msg.is_a?(String)
        return [{ :prefix => nil }] if msg == :unreadable
        return [] unless msg.is_a?(BGP::Update)
        rows = []
        unicast = lambda { |list| list.each { |n| rows << { :prefix => normalize(n.to_s) } } }
        unicast.call(msg.withdrawn.nlris) if msg.withdrawn
        unicast.call(msg.nlri.nlris) if msg.nlri
        pa = msg.path_attribute
        [BGP::ATTR::MP_UNREACH, BGP::ATTR::MP_REACH].each do |type|
          a = pa && pa[type]
          next unless a.respond_to?(:safi) && a.respond_to?(:nlris)
          if a.safi == 1
            unicast.call(a.nlris)
          else
            a.nlris.each { |n| rows << { :prefix => n.to_s, :family => "#{a.afi}/#{a.safi}" } }
          end
        end
        rows.uniq
      rescue StandardError
        [{ :prefix => nil }]
      end

      def self.message(octets, session_info)
        BGP::Message.factory(octets.dup.is_packed, session_info)
      rescue StandardError
        :unreadable
      end
      private_class_method :message

    end

  end
end
