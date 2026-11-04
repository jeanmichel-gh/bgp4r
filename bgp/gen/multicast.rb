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


require 'bgp/gen/unicast'

module BGP
  class Gen
    # IPv4 and IPv6 multicast, SAFI 2: unicast's prefixes and patterns in
    # a family of their own.
    #
    # **IPv4 goes in MP_REACH_NLRI here**, not in the NLRI field of RFC
    # 4271 section 4.3, which carries IPv4 unicast and nothing else. RFC
    # 4760 section 3 is the attribute for every other family, so the one
    # difference from Unicast is `classic?` answering false for AFI 1.
    # That includes the next hop, which travels inside the attribute and
    # not in a NEXT_HOP attribute.
    class Multicast < Unicast
      SAFI = IANA::SAFI::MULTICAST
    end
  end
end
