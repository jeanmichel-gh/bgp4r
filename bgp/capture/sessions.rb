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

require 'bgp/messages/messages'
require 'bgp/optional_parameters/capabilities'

module BGP
  module Capture

    # What a capture learns from the OPENs of each TCP connection: whether
    # the session uses 4-octet AS numbers. RFC 6793 section 3: they are
    # used when both speakers sent the 4-octet AS capability. An UPDATE
    # does not say which size it carries, so without this a capture reads
    # every AS_PATH with 2-octet AS numbers, and a session of two modern
    # speakers looks malformed.
    #
    # A connection is both directions of one flow, keyed on its two
    # endpoints. A new OPEN in a direction replaces the old one, which is
    # how a session that comes back on the same ports is followed.
    #
    #   s = Sessions.new
    #   s.saw(msg.flow, msg.octets)   # each message, in order
    #   s.as4byte(msg.flow)           # true, false, or nil before both OPENs
    class Sessions

      def initialize
        @opens = {}
      end

      def saw(flow, octets)
        return unless octets.bytesize > 18 and octets.getbyte(18) == Message::OPEN
        @opens[flow] = as4?(octets)
      end

      def as4byte(flow)
        mine, theirs = @opens[flow], @opens[reverse(flow)]
        return nil if mine.nil? or theirs.nil?
        mine and theirs
      end

      private

      # "a:1 > b:2" is "b:2 > a:1" the other way. An IPv6 address holds
      # colons, so the split is on the arrow only.
      def reverse(flow)
        flow.split(' > ', 2).reverse.join(' > ')
      end

      # An OPEN that does not parse says nothing about the session, and
      # false is the safe reading: RFC 6793 section 4.1, a speaker that
      # does not see the capability uses 2-octet AS numbers.
      def as4?(octets)
        open = Message.factory(octets.dup.is_packed)
        !open.has?(OPT_PARM::CAP::As4).nil?
      rescue StandardError
        false
      end

    end

  end
end
