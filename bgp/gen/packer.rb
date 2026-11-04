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
require 'bgp/gen/spec'

module BGP
  class Gen
    # Packs routes into messages by arithmetic, so a million routes are
    # never encoded just to be counted.
    #
    # A message is at most BGP::Message::MAX_SIZE octets (RFC 4271
    # section 4). The size of a message is the size of the same message
    # with no routes in it, `base`, plus the octets of each route. One
    # thing does not add up that simply: MP_REACH_NLRI and MP_UNREACH_NLRI
    # carry the routes inside an attribute, and an attribute whose value
    # passes 255 octets takes a 2 octet Length with the Extended Length
    # bit set (RFC 4271 section 4.3). So `mp_value` is that attribute's
    # value length with no routes, and the crossing costs one octet.
    #
    # The packer only counts. The family builds each message, and the
    # first one is measured against #size so that a slip in this
    # arithmetic raises before anything reaches a wire.
    class Packer
      MAX = BGP::Message::MAX_SIZE

      attr_reader :base, :mp_value, :per_update

      # base::       octets of the message with no routes in it.
      # mp_value::   value length of the empty MP attribute, or nil when
      #              routes go in the RFC 4271 section 4.3 fields.
      # per_update:: the most routes in one message, or nil for as many
      #              as fit.
      def initialize(base, mp_value: nil, per_update: nil)
        @base, @mp_value, @per_update = base, mp_value, per_update
      end

      # The octets of a message whose routes take `octets` in total.
      def size(octets)
        grow = (@mp_value && @mp_value <= 255 && @mp_value + octets > 255) ? 1 : 0
        @base + octets + grow
      end

      # Whether a message holding `octets` of routes is within the limit.
      def fits?(octets)
        size(octets) <= MAX
      end

      # Yields each batch as [items, octets]. `items` yields pairs of an
      # item and the octets it takes. A message ends when per_update is
      # reached or when the next item would not fit, so every message but
      # the last is as full as those two limits allow. Raises Unpackable
      # for an item too large for a message on its own.
      def each_batch(items)
        return enum_for(:each_batch, items) unless block_given?
        batch, octets = [], 0
        items.each do |item, len|
          unless fits?(len)
            raise Unpackable, "a route of #{len} octets makes a #{size(len)} octet message on its own, " \
                              "where BGP allows #{MAX} (RFC 4271 section 4); the attributes leave no room"
          end
          if batch.size == @per_update || !fits?(octets + len)
            yield batch, octets
            batch, octets = [], 0
          end
          batch << item
          octets += len
        end
        yield batch, octets unless batch.empty?
      end
    end
  end
end
