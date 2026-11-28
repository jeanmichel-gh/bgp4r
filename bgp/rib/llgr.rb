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

module BGP
  module Rib

    # Long-lived graceful restart's two communities on a route, RFC 9494
    # sections 3.2 and 3.3, for the table, the decision and export.
    # docs/design/bgp-operations.md section 4.
    module Llgr

      # The stale mark of a route in its LLGR period.
      MARK = 'long_lived'

      module_function

      # True when the attributes carry LLGR_STALE.
      def stale?(pa) ; communities(pa)&.has_llgr_stale? || false ; end

      # True when they carry NO_LLGR.
      def no_llgr?(pa) ; communities(pa)&.has_no_llgr? || false ; end

      # A copy of pa with LLGR_STALE added, once (section 4.2: "MUST attach
      # the LLGR_STALE community").
      def attach(pa)
        copy = Path_attribute.new(pa.encode(true), true)
        if copy.has?(Communities)
          copy[Communities].add(:llgr_stale) unless copy[Communities].has_llgr_stale?
        else
          copy << Communities.new(:llgr_stale)
        end
        copy
      end

      def communities(pa) ; pa && pa.has?(Communities) ? pa[Communities] : nil ; end
    end
  end
end
