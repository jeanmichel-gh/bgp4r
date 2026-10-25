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

module BGP
  module Rib

    # The BGP speaker a route was learned from, as seen by us.
    #
    #   peer = Peer.new(address: '10.0.0.2', remote_as: 65002, router_id: '2.2.2.2', local_as: 65001)
    #   peer.ebgp?  # => true
    #
    # Two Peer objects with the same address are the same peer.
    class Peer
      attr_reader :address, :remote_as, :router_id, :local_as

      def initialize(address:, remote_as:, router_id:, local_as:)
        @address = IPAddr.new(address.to_s).to_s
        @remote_as, @local_as = Integer(remote_as), Integer(local_as)
        @router_id = IPAddr.new(router_id.to_s).to_s
        freeze
      end

      # RFC 4271 section 1.1: a peer in another AS is an external peer.
      def ebgp? ; @remote_as != @local_as ; end
      def ibgp? ; !ebgp? ; end

      def ==(other) ; other.is_a?(Peer) && other.address == @address ; end
      alias eql? ==
      def hash ; @address.hash ; end

      def to_s ; "#{@address} AS#{@remote_as}" ; end
    end

    # One path to one prefix, as received from one peer. A Route never
    # changes: import policy that edits a route builds a new one.
    #
    #   pa = Path_attribute.new(Origin.new(0), Next_hop.new('10.0.0.2'), As_path.new(65002))
    #   r  = Route.new('192.168.1.0/24', pa, peer)
    #   r.as_path_length  # => 1
    #
    # With add-path (RFC 7911) one peer can send several paths to the same
    # prefix; path_id tells them apart, and key is [prefix, path_id].
    class Route
      attr_reader :prefix, :path_id, :path_attribute, :peer

      def initialize(prefix, path_attribute, peer, path_id: nil)
        raise ArgumentError, "peer must be a BGP::Rib::Peer, got #{peer.class}" unless peer.is_a?(Peer)
        @prefix = Route.normalize(prefix)
        @path_attribute = path_attribute || Path_attribute.new
        @peer = peer
        @path_id = path_id.nil? ? nil : Integer(path_id)
        freeze
      end

      # "a.b.c.d/len" or "x::/len", with the host bits cleared.
      def self.normalize(prefix)
        ip = IPAddr.new(prefix.to_s)
        "#{ip}/#{ip.prefix}"
      end

      def key ; [@prefix, @path_id] ; end
      def ipv4? ; !@prefix.include?(':') ; end
      def afi ; ipv4? ? 1 : 2 ; end

      # LOCAL_PREF (RFC 4271 section 5.1.5), or nil when absent.
      def local_pref ; attr(Local_pref) { |a| a.to_i } ; end

      # MULTI_EXIT_DISC (RFC 4271 section 5.1.4), or nil when absent.
      def med ; attr(Multi_exit_disc) { |a| a.to_i } ; end

      # ORIGIN: 0 IGP, 1 EGP, 2 INCOMPLETE (RFC 4271 section 5.1.1), or nil.
      def origin ; attr(Origin) { |a| a.to_i } ; end

      # NEXT_HOP, or the first next hop in MP_REACH_NLRI (RFC 4760 section 3).
      def next_hop
        attr(Next_hop) { |a| a.next_hop } ||
          attr(Mp_reach) { |a| a.nexthops.to_s.split(/[\s,]+/).first }
      end

      # ORIGINATOR_ID (RFC 4456 section 8), or nil.
      def originator_id ; attr(Originator_id) { |a| a.originator_id } ; end

      # CLUSTER_LIST IDs (RFC 4456 section 8), nearest first. Empty when absent.
      def cluster_list ; attr(Cluster_list) { |a| a.cluster_ids } || [] ; end

      # The AS_PATH segments, in order. Empty when there is no AS_PATH.
      def as_path_segments ; attr(As_path) { |a| a.segments } || [] ; end

      # The AS_PATH as text, the way show commands print it: "65002 {1, 2}".
      def as_path ; attr(As_path) { |a| a.as_path } || 'empty' ; end

      # RFC 4271 section 9.1.2.2 a): an AS_SET counts as 1, however many ASes
      # it holds. RFC 5065 section 5.3: confederation segments count as 0.
      def as_path_length
        as_path_segments.sum do |seg|
          case seg.seg_type
          when As_path::SEQUENCE then seg.as.size
          when As_path::SET then 1
          else 0
          end
        end
      end

      # True if as appears in the AS_PATH, outside confederation segments.
      # Used to find AS loops (RFC 4271 section 9.1.2).
      def as_path_include?(as)
        as = Integer(as)
        as_path_segments.any? do |seg|
          [As_path::SEQUENCE, As_path::SET].include?(seg.seg_type) && seg.as.include?(as)
        end
      end

      # The neighboring AS used to decide which MEDs compare (RFC 4271
      # section 9.1.2.2 c): the first AS of the leftmost AS_SEQUENCE, after
      # any confederation segments. A route whose AS_PATH is empty or starts
      # with an AS_SET came from our own AS.
      def neighbor_as
        seg = as_path_segments.find { |s| ![As_path::CONFED_SEQUENCE, As_path::CONFED_SET].include?(s.seg_type) }
        return @peer.local_as unless seg && seg.seg_type == As_path::SEQUENCE && !seg.as.empty?
        seg.as.first
      end

      # The BGP Identifier used in tie breaking: ORIGINATOR_ID when present
      # (RFC 4456 section 9), else the peer's router ID (RFC 4271 9.1.2.2 f).
      def router_id ; originator_id || @peer.router_id ; end

      def to_s
        id = @path_id ? "ID=#{@path_id}, " : ''
        "#{id}#{@prefix} via #{next_hop || '-'} from #{@peer} path #{as_path}"
      end

      private

      # Yields the attribute of class klass and returns the block's value,
      # or returns nil when the route has no such attribute.
      def attr(klass)
        return nil unless @path_attribute.has?(klass)
        yield @path_attribute[klass]
      end
    end

  end
end
