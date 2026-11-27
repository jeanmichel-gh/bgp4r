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
require 'set'

module BGP
  module Rtr

    # A set of Validated ROA Payloads, and RFC 6811 section 2's lookup
    # on it. It never changes: a new set of VRPs is a new Vrps, so a
    # reader holding one sees one state.
    #
    #   vrps = Rtr::Vrps.new([['192.0.2.0', 24, 24, 65001]])
    #   vrps.state('192.0.2.0/24', 65001)   # => :valid
    #   vrps.state('192.0.2.0/25', 65001)   # => :invalid, longer than the Max Length
    #   vrps.state('198.51.100.0/24', 1)    # => :not_found
    #
    # A VRP is its key, [address, prefix length, max length, asn], as
    # Rtr::Cache and the RTR PDUs (Prefix_pdu#key) name it.
    class Vrps
      include Enumerable

      STATES = %i[valid invalid not_found].freeze

      # The words routescope and the views use for each state.
      WORDS = { :valid => 'valid', :invalid => 'invalid', :not_found => 'notfound' }.freeze

      EMPTY_INDEX = {}.freeze

      def initialize(keys = [])
        @keys = keys.collect { |k| k.frozen? ? k : k.dup.freeze }.uniq.freeze
        # afi bits => { prefix length => { network as an Integer => [[max, asn], ...] } }
        index = { 32 => {}, 128 => {} }
        @keys.each do |address, length, max, asn|
          ip = IPAddr.new(address)
          bits = ip.ipv4? ? 32 : 128
          ((index[bits][length] ||= {})[ip.mask(length).to_i] ||= []) << [max, asn]
        end
        @index = index.transform_values(&:freeze).freeze
        freeze
      end

      def each(&block) ; @keys.each(&block) ; end
      def size ; @keys.size ; end
      def empty? ; @keys.empty? ; end
      def to_a ; @keys.dup ; end

      # How many VRPs are IPv4 and how many IPv6.
      def counts
        v6 = @keys.count { |k| k[0].include?(':') }
        { :v4 => @keys.size - v6, :v6 => v6 }
      end

      # RFC 6811 section 2: NotFound when no VRP Covers the prefix, Valid
      # when one Matches it, else Invalid. origin_asn nil is the RFC's
      # NONE, which no VRP Matches; a VRP for AS 0 Matches nothing either.
      def state(prefix, origin_asn)
        covering = covering(prefix)
        return :not_found if covering.empty?
        length = Integer(prefix.to_s.split('/')[1])
        return :valid if !origin_asn.nil? && covering.any? { |max, asn| asn != 0 && asn == origin_asn && length <= max }
        :invalid
      end

      # True when a VRP here Covers prefix: its length at most the
      # prefix's, and their addresses the same for its length.
      def covers?(prefix) ; !covering(prefix).empty? ; end

      # [added, removed] going from this set to other, as Vrps.
      def diff(other)
        mine, theirs = @keys.to_set, other.to_a.to_set
        [Vrps.new((theirs - mine).to_a), Vrps.new((mine - theirs).to_a)]
      end

      def ==(other) ; other.is_a?(Vrps) && other.to_a.sort == @keys.sort ; end

      private

      # [[max, asn], ...] of every VRP covering prefix, 'address/length'.
      def covering(prefix)
        address, length = prefix.to_s.split('/')
        ip = IPAddr.new(address)
        bits = ip.ipv4? ? 32 : 128
        length = Integer(length)
        by_length = @index[bits] || EMPTY_INDEX
        found = []
        by_length.each do |vrp_length, nets|
          next if vrp_length > length
          list = nets[ip.mask(vrp_length).to_i]
          found.concat(list) if list
        end
        found
      end
    end
  end
end
