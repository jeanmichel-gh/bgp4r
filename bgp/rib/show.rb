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
    #   puts rib.show(:iosxr)                # IOS-XR, show bgp
    #   puts rib.show(:iosxr, '10.0.0.0/8')  # one prefix, the detail form
    #
    # **These are written in the style of those commands, not copies of
    # them.** Three things are reproduced from samples in the vendors' own
    # documentation: the IOS header, legend and column layout, the Junos
    # detail shape with its Preference, State and Inactive reason lines, and
    # the IOS-XR legend, column layout and detail shape. The rest is
    # bgp4r's. No output here has been diffed against a real device, and a
    # release of any of them will differ in details, so do not write a test
    # elsewhere that depends on this text byte for byte, and do not read a
    # difference from your router as a bug here.
    #
    # IOS-XR is here as of #157, and was not before: no sample of its
    # `show bgp` output could be found, and inventing a format while calling
    # it IOS-XR would have been worse than not having it. The sample it is
    # written from is in the "Remove and Replace Private AS Numbers from AS
    # Path in BGP" section of Cisco's BGP Configuration Guide for the NCS
    # 5500, IOS XR release 7.11.x, which carries both the table form and a
    # `show bgp <prefix>` detail form.
    #
    # Two things IOS-XR prints that bgp4r does not, and will not:
    #
    # The header lines that report state bgp4r has none of. The sample's
    # Table ID, RD version, scan intervals, non-stop routing and the two NSR
    # and ISSU sync version lines are all device state, and a plausible
    # value in one of them would read as something bgp4r knows. The same
    # judgement left IOS's extra header lines out.
    #
    # In the detail form, the Versions block, Last Modified, Local Path ID,
    # version, and whether a path was advertised to a peer. The first two
    # need timestamps a Route does not carry, and the last needs the
    # Adj-RIB-Outs, which belong to a Router and not to a Table.
    #
    # And one thing it has no line for: why a path lost. IOS-XR prints the
    # winner's flags and nothing about the others' reasons, so `show(:iosxr,
    # prefix)` does not either. Use `show(:junos, prefix)` for that, which
    # has an Inactive reason line of its own to put it on.
    class Show

      STYLES = %i[ios junos iosxr].freeze

      # The origin codes both vendors print after the AS path, from the
      # ORIGIN values of RFC 4271 section 5.1.1: 0 IGP, 1 EGP, 2 INCOMPLETE.
      # IOS prints them lower case and Junos upper.
      ORIGIN_CODES = { 0 => 'i', 1 => 'e', 2 => '?' }.freeze

      # The same three ORIGIN values spelled out, which is what IOS-XR puts
      # in the detail form: the sample reads "Origin incomplete, metric 0,
      # localpref 100". IGP and EGP are upper case there and incomplete is
      # not, which looks like a typo in Cisco's output and is reproduced
      # because it is theirs.
      ORIGIN_WORDS = { 0 => 'IGP', 1 => 'EGP', 2 => 'incomplete' }.freeze

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

      # STYLES has already been checked in initialize, so the style names a
      # pair of methods below.
      def all
        send("#{@style}_all")
      end

      def one(prefix)
        send("#{@style}_one", prefix)
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

      # IOS-XR. The header, the legend and the column layout are the ones in
      # the `show bgp` sample named in the class comment.
      #
      # The legend is where this differs from IOS rather than merely being
      # IOS relabelled, and the difference is the sample's: IOS-XR breaks
      # the line after "> best" and puts "i - internal" on the second line
      # with the rest, spells stale with a small s where IOS has "S Stale",
      # and has an N for Nexthop-discard that IOS has no code for at all.
      def iosxr_header
        [format('BGP router identifier %s, local AS number %d',
                @table.router_id, @table.local_as),
         format('BGP main routing table version %d', @table.loc_rib.size),
         'BGP table state: Active',
         '',
         'Status codes: s suppressed, d damped, h history, * valid, > best',
         '              i - internal, r RIB-failure, S stale, N Nexthop-discard',
         'Origin codes: i - IGP, e - EGP, ? - incomplete',
         '',
         '   Network            Next Hop         Metric LocPrf Weight Path']
      end

      def iosxr_all
        lines = iosxr_header
        prefixes.each { |prefix| lines.concat(iosxr_rows(prefix)) }
        lines.join("\n") + "\n"
      end

      # The detail form rather than the table, because that is the one
      # IOS-XR gives for a single prefix.
      def iosxr_one(prefix)
        iosxr_entry(prefix).join("\n") + "\n"
      end

      # The Network column is wider here than IOS's and the Next Hop column
      # narrower, which is what puts Next Hop at the same offset in both.
      # Measured off the sample: its header and its rows agree that Next Hop
      # starts 22 characters in.
      #
      # ios_next_hop and ios_weight are shared, so a locally originated
      # route prints 0.0.0.0 and a weight of 32768 here as well. That pair
      # is borrowed: it comes from the IOS sample, and the IOS-XR sample has
      # no locally originated route in it either way. The detail form below
      # borrows nothing and prints what the Route carries, so the two forms
      # disagree about a local route's next hop on purpose.
      def iosxr_rows(prefix)
        rows = []
        paths(prefix).each_with_index do |(route, reason), i|
          status = +''
          status << (usable?(reason) ? '*' : ' ')
          status << (reason.nil? ? '>' : ' ')
          rows << format('%-3s%-19s%-17s%6s %6s %6s %s',
                         status, i.zero? ? prefix : '', ios_next_hop(route),
                         route.med || 0, route.local_pref, ios_weight(route),
                         ios_path(route))
        end
        rows
      end

      # "Paths: (N available, best #1)". The best path is always #1 because
      # paths returns it first; a real IOS-XR numbers them in the order it
      # received them and says which won, so the number it prints there
      # means something this cannot reproduce.
      def iosxr_entry(prefix)
        rows = paths(prefix)
        lines = [format('BGP routing table entry for %s', prefix)]
        best = rows.find_index { |(_, reason)| reason.nil? }
        lines << format('Paths: (%d available, %s)', rows.size,
                        best.nil? ? 'no best path' : "best ##{best + 1}")
        rows.each_with_index do |(route, reason), i|
          lines.concat(iosxr_path(route, reason, i + 1))
        end
        lines
      end

      def iosxr_path(route, reason, number)
        lines = [format('  Path #%d: Received by speaker 0', number)]
        lines << format('  %s', route.as_path == 'empty' ? 'Local' : route.as_path)
        lines << format('    %s from %s (%s)', route.next_hop || '0.0.0.0',
                        route.peer.address, route.peer.router_id)
        lines << format('      %s', iosxr_flags(route, reason))
        # RFC 7911 section 3: a path that arrived with a Path Identifier.
        # IOS-XR prints 0 for one that did not, which is what the sample
        # shows, since it has no add-path session.
        lines << format('      Received Path ID %d', route.path_id || 0)
        lines
      end

      # "Origin incomplete, metric 0, localpref 100, valid, external, best".
      # group-best and multipath are in the sample too and are not here:
      # bgp4r installs one best path per prefix and has no multipath, so
      # either flag would be a claim about something it does not do.
      def iosxr_flags(route, reason)
        parts = [format('Origin %s', ORIGIN_WORDS[route.origin] || 'incomplete'),
                 format('metric %d', route.med || 0),
                 format('localpref %d',
                        route.local_pref || Decision::DEFAULT_LOCAL_PREF)]
        parts << 'valid' if usable?(reason)
        parts << (route.local? ? 'local' : (route.peer.ebgp? ? 'external' : 'internal'))
        parts << 'best' if reason.nil?
        parts.join(', ')
      end
    end

  end
end
