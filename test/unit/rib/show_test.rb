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

require 'test/unit'
require 'bgp/rib'

# These tests check what the output says and how its columns line up, not
# that it matches any release of IOS or Junos byte for byte: see the comment
# on BGP::Rib::Show for why that is not claimed.
#
# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibShow < Test::Unit::TestCase

  LOCAL_AS = 65001
  E1 = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                          :router_id => '2.2.2.2', :local_as => LOCAL_AS)
  E2 = BGP::Rib::Peer.new(:address => '10.0.0.3', :remote_as => 65003,
                          :router_id => '3.3.3.3', :local_as => LOCAL_AS)
  I1 = BGP::Rib::Peer.new(:address => '10.0.0.4', :remote_as => LOCAL_AS,
                          :router_id => '4.4.4.4', :local_as => LOCAL_AS)

  def setup
    @rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1')
  end

  def route(peer, prefix = '10.1.0.0/16', origin: 0, med: nil, local_pref: nil, as_path: nil)
    attrs = [BGP::Origin.new(origin), BGP::Next_hop.new(peer.address)]
    attrs << BGP::As_path.new(*(as_path || (peer.ebgp? ? [peer.remote_as] : [])))
    attrs << BGP::Multi_exit_disc.new(med) if med
    attrs << BGP::Local_pref.new(local_pref) if local_pref
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), peer)
  end

  def ios ; @rib.show ; end
  def junos(prefix = nil) ; @rib.show(:junos, prefix) ; end

  # The row for a prefix, without the header.
  def ios_rows
    ios.lines.map(&:chomp).drop(6)
  end

  def test_an_unknown_style_is_refused
    e = assert_raise(ArgumentError) { @rib.show(:cisco_nx) }
    assert_match(/unknown style/, e.message)
    assert_equal(%i[ios junos], BGP::Rib::Show::STYLES)
  end

  def test_an_empty_table_still_prints_its_header
    out = ios
    assert_match(/^BGP table version is 0, local router ID is 1\.1\.1\.1$/, out)
    assert_equal(6, out.lines.size, 'the header and nothing else')
  end

  # The header, legend and column line are the ones in the sample output in
  # Cisco's own command reference, in the classic form with no RPKI column.
  def test_the_ios_header_is_the_documented_one
    lines = ios.lines.map(&:chomp)
    assert_equal('BGP table version is 0, local router ID is 1.1.1.1', lines[0])
    assert_equal('Status codes: s suppressed, d damped, h history, * valid, > best, i - internal,',
                 lines[1])
    assert_equal('              r RIB-failure, S Stale', lines[2])
    assert_equal('Origin codes: i - IGP, e - EGP, ? - incomplete', lines[3])
    assert_equal('', lines[4])
    assert_equal('   Network          Next Hop            Metric LocPrf Weight Path', lines[5])
  end

  # The columns have to line up under their own header, which is the one
  # thing about this output that is checkable without a router. The header
  # is the source of truth and the row is measured against it.
  def test_the_columns_line_up_under_the_header
    # An internal peer, so the route keeps its LOCAL_PREF and that column
    # has something in it; see the test below for why an external one does
    # not.
    @rib.announce(route(I1, '10.1.0.0/16', :med => 10, :local_pref => 250))
    header = ios.lines.map(&:chomp)[5]
    row = ios_rows.first
    # Each field is read out of the row at the offset its own heading sits
    # at, so the header is the source of truth and a column that slipped
    # would fail here.
    assert_equal('10.1.0.0/16', row[header.index('Network'), 17].strip, 'Network')
    assert_equal('10.0.0.4', row[header.index('Next Hop'), 20].strip, 'Next Hop')
    assert_equal('10', row[header.index('Metric'), 6].strip, 'Metric')
    assert_equal('250', row[header.index('LocPrf'), 6].strip, 'LocPrf')
    assert_equal('0', row[header.index('Weight'), 6].strip, 'Weight')
    assert_equal('i', row[header.index('Path')..-1].strip, 'Path')
  end

  # RFC 4271 section 5.1.5: LOCAL_PREF from an external peer is ignored, and
  # Table#import drops it, so the column is blank for such a route. That is
  # what a router shows too, and it is the import rule showing through
  # rather than anything this file does.
  def test_the_local_pref_column_is_blank_for_an_external_peers_route
    @rib.announce(route(E1, '10.1.0.0/16', :local_pref => 250))
    header = ios.lines.map(&:chomp)[5]
    assert_equal('', ios_rows.first[header.index('LocPrf'), 6].strip)
    assert_nil(@rib.best('10.1.0.0/16').local_pref)
  end

  def test_the_best_route_is_marked_and_the_others_are_not
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10))
    @rib.announce(route(E2, '10.1.0.0/16', :med => 20))
    rows = ios_rows
    assert_equal(2, rows.size)
    assert_equal('*>', rows[0][0, 2], 'valid and best')
    assert_equal('* ', rows[1][0, 2], 'valid, not best')
  end

  # The prefix is printed on the first path of a group and left blank under
  # it, the way the sample does.
  def test_the_prefix_is_printed_once_per_group
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10))
    @rib.announce(route(E2, '10.1.0.0/16', :med => 20))
    rows = ios_rows
    assert_match(/10\.1\.0\.0\/16/, rows[0])
    assert_no_match(/10\.1\.0\.0\/16/, rows[1])
    assert_match(/10\.0\.0\.3/, rows[1], 'but its next hop is there')
  end

  # The sample prints a locally originated route with 0.0.0.0 as its next
  # hop and a weight of 32768, where a learned route has a weight of 0.
  def test_an_originated_route_shows_no_next_hop_and_a_weight
    @rib.originate('10.9.0.0/16')
    row = ios_rows.first
    assert_match(/0\.0\.0\.0/, row)
    assert_match(/32768/, row)
  end

  def test_a_learned_route_has_a_weight_of_zero
    @rib.announce(route(E1))
    assert_no_match(/32768/, ios_rows.first)
  end

  # RFC 4271 section 5.1.1 ORIGIN: 0 IGP, 1 EGP, 2 INCOMPLETE, which both
  # vendors print as i, e and ?.
  def test_the_origin_code_ends_the_path
    [[0, 'i'], [1, 'e'], [2, '?']].each do |origin, code|
      rib = BGP::Rib.new(:local_as => LOCAL_AS, :router_id => '1.1.1.1')
      rib.announce(route(E1, '10.1.0.0/16', :origin => origin))
      assert_match(/65002 #{Regexp.escape(code)}$/, rib.show.lines.map(&:chomp).last,
                   "origin #{origin}")
    end
  end

  # A route from an internal peer with no AS_PATH prints the origin code
  # alone, not the word "empty".
  def test_an_empty_as_path_prints_only_the_origin_code
    @rib.announce(route(I1, '10.1.0.0/16', :local_pref => 100))
    row = ios_rows.first
    assert_no_match(/empty/, row)
    assert_match(/ i$/, row)
  end

  def test_prefixes_come_out_in_a_stable_order
    %w[192.168.0.0/24 10.1.0.0/16 10.0.0.0/8].each { |p| @rib.announce(route(E1, p)) }
    seen = ios_rows.map { |r| r[3, 17].strip }
    assert_equal(seen, @rib.show.lines.map(&:chomp).drop(6).map { |r| r[3, 17].strip },
                 'twice in a row gives the same order')
    assert_equal(3, seen.size)
    assert_equal(seen.sort_by { |p| IPAddr.new(p).to_i }, seen, 'by address')
  end

  def test_show_takes_one_prefix
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.announce(route(E1, '10.2.0.0/16'))
    out = @rib.show(:ios, '10.1.0.0/16')
    assert_match(/10\.1\.0\.0\/16/, out)
    assert_no_match(/10\.2\.0\.0\/16/, out)
  end

  # Junos. The shape is the one in the sample in Juniper's documentation.

  def test_the_junos_table_line_counts_destinations_and_routes
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10))
    @rib.announce(route(E2, '10.1.0.0/16', :med => 20))
    @rib.announce(route(E1, '10.2.0.0/16'))
    assert_match(/^inet\.0: 2 destinations, 3 routes \(2 active, 0 holddown, 0 hidden\)$/,
                 junos)
  end

  def test_a_junos_entry_counts_its_paths
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10))
    @rib.announce(route(E2, '10.1.0.0/16', :med => 20))
    assert_match(/^10\.1\.0\.0\/16 \(2 entries, 1 announced\)$/, junos)
  end

  # The sample shows the preference as 170/-(localpref+1): localpref 200
  # printed 170/-201 and localpref 100 printed 170/-101.
  def test_the_preference_follows_the_local_pref
    @rib.announce(route(I1, '10.1.0.0/16', :local_pref => 200))
    assert_match(%r{^        \*BGP    Preference: 170/-201$}, junos)
  end

  def test_the_best_path_is_starred_and_active
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10))
    @rib.announce(route(E2, '10.1.0.0/16', :med => 20))
    lines = junos('10.1.0.0/16').lines.map(&:chomp)
    assert_equal(1, lines.count { |l| l =~ /^        \*BGP/ }, 'one best path')
    assert_equal(1, lines.count { |l| l.include?('State: <Active Ext>') })
    assert_equal(1, lines.count { |l| l == '                State: <Ext>' })
  end

  def test_an_internal_peers_route_is_int
    @rib.announce(route(I1, '10.1.0.0/16', :local_pref => 100))
    assert_match(/State: <Active Int>/, junos)
  end

  # Only the reasons taken from Juniper's own sample are printed in its
  # words. Every other step prints bgp4r's symbol, in snake_case, so it
  # cannot be mistaken for a quote from a router.
  def test_a_reason_juniper_names_is_printed_in_its_words
    @rib.announce(route(I1, '10.1.0.0/16', :local_pref => 200))
    other = BGP::Rib::Peer.new(:address => '10.0.0.5', :remote_as => LOCAL_AS,
                               :router_id => '5.5.5.5', :local_as => LOCAL_AS)
    @rib.announce(route(other, '10.1.0.0/16', :local_pref => 100))
    assert_match(/Inactive reason: Local Preference/, junos)
  end

  def test_a_reason_juniper_does_not_name_prints_our_own_step
    @rib.announce(route(E1, '10.1.0.0/16'))
    @rib.announce(route(E2, '10.1.0.0/16'))
    assert_match(/Inactive reason: router_id$/, junos)
    assert_no_match(/Inactive reason: Router ID/, junos, 'not invented Junos wording')
  end

  # :med is deliberately not labelled "IGP metric": that reason is the IGP
  # cost to the next hop, which is a different step.
  def test_med_is_not_called_igp_metric
    @rib.announce(route(E1, '10.1.0.0/16', :med => 10, :as_path => [65002]))
    @rib.announce(route(E1.dup, '10.1.0.0/16', :med => 20, :as_path => [65002]))
    assert_equal(%w[local_pref igp_cost ebgp_over_ibgp].sort,
                 BGP::Rib::Show::JUNOS_REASONS.keys.map(&:to_s).sort)
    assert(!BGP::Rib::Show::JUNOS_REASONS.key?(:med))
  end

  def test_the_junos_as_path_ends_in_an_upper_case_origin_code
    @rib.announce(route(E1, '10.1.0.0/16'))
    assert_match(/^                AS path: 65002 I$/, junos)
  end

  def test_the_style_can_be_read_back
    s = BGP::Rib::Show.new(@rib, :style => :junos)
    assert_equal(:junos, s.style)
    assert_same(@rib, s.table)
  end
end
