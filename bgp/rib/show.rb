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

require 'bgp/rib/decision'

module BGP
  module Rib

    # The Loc-RIB written out the way a router would print it, so that what
    # bgp4r decided can be read by someone who reads routers all day.
    #
    #   puts rib.show                        # IOS, show ip bgp
    #   puts rib.show(:junos)                # Junos, show route detail
    #   puts rib.show(:junos, '10.0.0.0/8')  # one prefix, and why each path lost
    #
    # **These are written in the style of those commands, not copies of
    # them.** Two things are reproduced from samples in the vendors' own
    # documentation: the IOS header, legend and column layout, and the Junos
    # detail shape with its Preference, State and Inactive reason lines. The
    # rest is bgp4r's. No output here has been diffed against a real device,
    # and a release of either will differ in details, so do not write a test
    # elsewhere that depends on this text byte for byte, and do not read a
    # difference from your router as a bug here.
    #
    # Only IOS and Junos are implemented. IOS-XR was in the plan and is not
    # here, because no sample of `show bgp` output could be found to check it
    # against, and inventing a format while calling it IOS-XR is worse than
    # not having it. See "Where the work is going" in CLAUDE.md.
    class Show

      STYLES = %i[ios junos].freeze

      # The origin codes both vendors print after the AS path, from the
      # ORIGIN values of RFC 4271 section 5.1.1: 0 IGP, 1 EGP, 2 INCOMPLETE.
      # IOS prints them lower case and Junos upper.
      ORIGIN_CODES = { 0 => 'i', 1 => 'e', 2 => '?' }.freeze

      # What Junos calls the step that left a route inactive.
      #
      # Only these three are Junos's own words, taken from the sample output
      # in its documentation. Every other step prints bgp4r's own symbol,
      # left in snake_case on purpose: no sample could be found to check the
      # real wording against, and a plausible invention in this field would
      # be read as a quote from a router. "router_id" is obviously ours and
      # greppable against Decision::STEPS; "Router ID" would not be.
      # :med is deliberately not mapped to "IGP metric". That reason is the
      # IGP cost to the next hop, which is what :igp_cost is here, and
      # labelling MULTI_EXIT_DISC with it would be a confident wrong answer.
      JUNOS_REASONS = {
        :local_pref      => 'Local Preference',
        :igp_cost        => 'IGP metric',
        :ebgp_over_ibgp  => 'Interior > Exterior > Exterior via Interior'
      }.freeze

      attr_reader :table, :style

      def initialize(table, style: :ios)
        @style = style.to_sym
        unless STYLES.include?(@style)
          raise ArgumentError, "unknown style #{style.inspect}, use #{STYLES.inspect}"
        end
        @table = table
      end

      # The whole Loc-RIB, or one prefix in detail.
      def to_s(prefix = nil)
        @table.synchronize do
          prefix ? one(Route.normalize(prefix)) : all
        end
      end

      private

      def prefixes ; @table.loc_rib.prefixes.sort_by { |p| sort_key(p) } ; end

      # Shortest prefix first, then by address, which is near enough to what
      # a router prints and is at least stable.
      def sort_key(prefix)
        ip = IPAddr.new(prefix)
        [ip.family, ip.to_i, ip.prefix]
      end

      def all
        @style == :ios ? ios_all : junos_all
      end

      def one(prefix)
        @style == :ios ? ios_one(prefix) : junos_one(prefix)
      end

      # Every path to a prefix, best first, then the ones that lost.
      def paths(prefix)
        result = @table.result(prefix)
        return [] unless result
        rest = @table.candidates(prefix).reject { |r| result.best && r.equal?(result.best) }
        [[result.best, nil]] + rest.map { |r| [r, (result.eliminated || {})[r]] }
      end

      def usable?(reason)
        !Decision::INELIGIBLE.include?(reason)
      end

      # IOS. The header, the legend and the column layout are the ones in
      # the `show ip bgp` sample in Cisco's own command reference, in the
      # classic form without the RPKI validation column.
      def ios_header
        [format('BGP table version is %d, local router ID is %s',
                @table.loc_rib.size, @table.router_id),
         'Status codes: s suppressed, d damped, h history, * valid, > best, i - internal,',
         '              r RIB-failure, S Stale',
         'Origin codes: i - IGP, e - EGP, ? - incomplete',
         '',
         '   Network          Next Hop            Metric LocPrf Weight Path']
      end

      def ios_all
        lines = ios_header
        prefixes.each { |prefix| lines.concat(ios_rows(prefix)) }
        lines.join("\n") + "\n"
      end

      def ios_one(prefix)
        (ios_header + ios_rows(prefix)).join("\n") + "\n"
      end

      # The prefix is printed on its first path only, the way the sample
      # leaves it blank on the lines under it.
      def ios_rows(prefix)
        rows = []
        paths(prefix).each_with_index do |(route, reason), i|
          status = +''
          status << (usable?(reason) ? '*' : ' ')
          status << (reason.nil? ? '>' : ' ')
          rows << format('%-3s%-17s%-20s%6s %6s %6s %s',
                         status, i.zero? ? prefix : '', ios_next_hop(route),
                         route.med || 0, route.local_pref, ios_weight(route),
                         ios_path(route))
        end
        rows
      end

      # The sample prints a locally originated route with 0.0.0.0 as its
      # next hop and a weight of 32768, where a learned route has the next
      # hop it came with and a weight of 0.
      def ios_next_hop(route)
        route.local? ? '0.0.0.0' : (route.next_hop || '')
      end

      def ios_weight(route)
        route.local? ? 32_768 : 0
      end

      def ios_path(route)
        path = route.as_path == 'empty' ? '' : route.as_path
        [path, ORIGIN_CODES[route.origin] || '?'].reject { |s| s.to_s.empty? }.join(' ')
      end

      # Junos. The shape is the one in the sample in Juniper's own
      # documentation: a table line, then an entry per destination, then a
      # block per route with Preference, Next hop, State, any Inactive
      # reason, the AS path and Localpref.
      def junos_all
        lines = [junos_table_line, '']
        prefixes.each { |prefix| lines.concat(junos_entry(prefix)) ; lines << '' }
        lines.join("\n")
      end

      def junos_one(prefix)
        ([junos_table_line, ''] + junos_entry(prefix) + ['']).join("\n")
      end

      def junos_table_line
        routes = prefixes.sum { |p| @table.candidates(p).size }
        active = @table.loc_rib.size
        format('inet.0: %d destinations, %d routes (%d active, 0 holddown, 0 hidden)',
               active, routes, active)
      end

      def junos_entry(prefix)
        rows = paths(prefix)
        lines = [format('%s (%d entries, %d announced)', prefix, rows.size,
                        rows.count { |(_, reason)| reason.nil? })]
        rows.each { |(route, reason)| lines.concat(junos_route(route, reason)) }
        lines
      end

      def junos_route(route, reason)
        pref = route.local_pref || Decision::DEFAULT_LOCAL_PREF
        lines = [format('        %sBGP    Preference: 170/-%d', reason.nil? ? '*' : ' ', pref + 1)]
        lines << format('                Next hop: %s, selected', route.next_hop || 'self')
        lines << format('                State: <%s>', junos_state(route, reason))
        lines << format('                Inactive reason: %s', junos_reason(reason)) if reason
        lines << format('                AS path: %s', junos_path(route))
        lines << format('                Localpref: %d', pref)
        lines
      end

      def junos_state(route, reason)
        parts = []
        parts << 'Active' if reason.nil?
        parts << (route.peer.ebgp? ? 'Ext' : 'Int')
        parts.join(' ')
      end

      def junos_reason(reason)
        JUNOS_REASONS[reason] || reason.to_s
      end

      def junos_path(route)
        path = route.as_path == 'empty' ? '' : route.as_path
        [path, (ORIGIN_CODES[route.origin] || '?').upcase].reject { |s| s.to_s.empty? }.join(' ')
      end
    end

  end
end
