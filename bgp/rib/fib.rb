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

require 'bgp/rib/loc_rib'

module BGP
  module Rib

    # The FIB side of the table: the Loc-RIB's best route per prefix, as a
    # forwarding table holds it.
    #
    # Pure, like Export, UpdateBuilder and Mrai. It reads Loc-RIB changes
    # and returns operations, and it records what it believes is installed
    # the way AdjRibOut records what was sent. Nothing in this class
    # touches a kernel. Fib::IpRoute turns one operation into an iproute2
    # command, and running it is the only impure part of the FIB side.
    #
    # Two things it deliberately does not do.
    #
    # It does not resolve a next hop. A real router resolves the BGP next
    # hop recursively against its IGP, and bgp4r has no IGP, so the next
    # hop goes to the kernel as it arrived and the kernel decides whether
    # it can reach it. A reader who expects recursive resolution will not
    # find it here, which is why this says so rather than leaving it to be
    # discovered.
    #
    # It holds one route per prefix and no multipath. The Loc-RIB has one
    # best route per prefix (RFC 4271 section 9.1.2), so that is what
    # there is to install; ECMP would mean reading the whole candidate set
    # and is its own piece of work.
    class Fib

      # What to do about one prefix. :install covers both a prefix the FIB
      # does not have and one whose next hop changed, because the command
      # for either is the same and is idempotent.
      Op = Struct.new(:action, :prefix, :next_hop) do
        def install? ; action == :install ; end
        def remove? ; action == :remove ; end
        def to_s
          install? ? "install #{prefix} via #{next_hop}" : "remove #{prefix}"
        end
      end

      def initialize
        @installed = {}
        @skipped = {}
      end

      # The operation one Loc-RIB change calls for, or nil when the FIB
      # already agrees with it.
      #
      # This records nothing. The installed table is written by commit,
      # once the command has actually run, because a planner that recorded
      # its own intent would claim a route the kernel refused. That is the
      # bug part 8 of RIB phase 3 nearly shipped in Mrai, and the fix
      # there was the same: one place that writes, reached after the work.
      def plan(change)
        prefix = change.prefix
        route = change.new
        return removal(prefix) if route.nil?
        next_hop = route.next_hop
        if next_hop.nil? or next_hop.to_s.empty?
          # A route the Loc-RIB can no longer describe is not a route to
          # keep forwarding on, so an installed one comes out.
          note_skip(prefix, :no_next_hop)
          return removal(prefix)
        end
        return nil if current?(prefix, next_hop)
        Op.new(:install, prefix, next_hop.to_s)
      end

      # Records what an operation did, after it did it. Answers what
      # changed, the way AdjRibOut#advertise does: :new, :changed, :same
      # for an install, and the next hop removed or nil for a removal.
      def commit(op)
        return nil if op.nil?
        if op.remove?
          @installed.delete(op.prefix)
        else
          was = @installed[op.prefix]
          @installed[op.prefix] = op.next_hop
          was.nil? ? :new : (was == op.next_hop ? :same : :changed)
        end
      end

      # The next hop installed for a prefix, or nil.
      def [](prefix) ; @installed[prefix] ; end

      def current?(prefix, next_hop)
        @installed.key?(prefix) && @installed[prefix] == next_hop.to_s
      end

      def prefixes ; @installed.keys ; end
      def size ; @installed.size ; end
      def empty? ; @installed.empty? ; end

      def each
        return enum_for(:each) unless block_given?
        @installed.each { |prefix, next_hop| yield prefix, next_hop }
      end

      # Forgets everything, for a FIB whose table was emptied underneath
      # it. It removes nothing by itself.
      def flush ; @installed.clear ; self ; end

      # Why a prefix was not installed, keyed by prefix. A route that
      # silently never reached the forwarding table is the hardest kind of
      # bug to see from outside, which is why Router#skipped exists too.
      def skipped ; @skipped.dup ; end
      def clear_skipped ; @skipped.clear ; self ; end

      def to_s
        "FIB: #{size} route#{'s' unless size == 1}"
      end

      private

      def removal(prefix)
        return nil unless @installed.key?(prefix)
        Op.new(:remove, prefix, nil)
      end

      def note_skip(prefix, reason)
        @skipped[prefix] = reason
      end

    end
  end
end

require 'bgp/rib/ip_route'
