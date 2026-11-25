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
  module Daemon

    # End-of-RIB, RFC 4724 section 2, for a neighbor with
    # `end_of_rib: true`. docs/design/bgp-operations.md, section 1, is the
    # design.
    #
    # RFC 4724 section 2 recommends the marker outside graceful restart
    # too: "the generation of such a marker upon completion of the initial
    # update would be useful for routing convergence in general, and thus
    # the practice is recommended." It changes the wire, so it is off
    # until a neighbor asks for it.
    #
    # The receiving half is in the library: BGP::Neighbor publishes a
    # :session event for each marker it reads (Update#end_of_rib), and the
    # Recorder keeps the families for the peer's row.
    module EndOfRib

      module_function

      # Refuses an `end_of_rib` value that is not true or false. nil is
      # off.
      def check(value, address)
        return if value.nil? || value == true || value == false
        raise ArgumentError, "neighbor #{address}: end_of_rib is true or false, got #{value.inspect}"
      end

      # The <AFI, SAFI> pairs a session negotiated, as [afi, safi], in
      # the order our OPEN lists them. A pair counts when both OPENs list
      # it as a Multiprotocol capability, RFC 4760 section 8. An OPEN with
      # no such capability is IPv4 unicast only, which is what a speaker
      # that predates RFC 4760 carries.
      def families(session_info)
        return [] unless session_info
        ours = advertised(session_info.speaker)
        theirs = advertised(session_info.peer)
        ours & theirs
      end

      # What one OPEN lists, or IPv4 unicast when it lists nothing.
      def advertised(open)
        return [] unless open
        caps = Array(open.opt_parms).flat_map { |p| p.respond_to?(:capabilities) ? Array(p.capabilities) : [p] }
        mp = caps.grep(BGP::OPT_PARM::CAP::Mbgp).collect { |c| [c.afi, c.safi] }.uniq
        mp.empty? ? [[1, 1]] : mp
      end

      # The marker for one family: the 23-octet UPDATE for IPv4 unicast,
      # an UPDATE with one empty MP_UNREACH_NLRI for any other.
      def marker(afi, safi)
        [afi, safi] == [1, 1] ? BGP::Update.end_of_rib_marker : BGP::Update.end_of_rib_marker(:afi => afi, :safi => safi)
      end
    end
  end
end
