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

# BGP::Gen against FRR: a generated feed from bgp4r into a standalone
# bgpd on loopback, no Docker and no zebra, and FRR's RIB compared with
# the spec's `expected`. The twin of gen_gobgp_test.rb, and phase 6 of
# docs/route-generation.md: both go through LabHelper#spec_crosses, so
# the count, the sample and the withdrawal are one piece of code.
#
#   ruby -I. test/functional/lab/gen_frr_test.rb
#
# Omitted when FRR's bgpd is not installed, unless LAB_REQUIRE_FRR=1.
#
# **Why a second router**: two implementations reading one generated
# feed is what tells a fault in the generator from a quirk of one
# reader. FRR names its attributes where GoBGP numbers them, so the two
# tests read the same rows through two unrelated parsers.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require 'bgp/gen'
require 'bgp/sim'
require_relative 'lab_helper'

class LabGenFrrTest < Test::Unit::TestCase
  include LabHelper

  # The families a feed here is generated in. coverage_matrix.rb reads
  # this line as text, and test/unit/coverage_matrix_test.rb holds it to
  # the 'family' literals below, so neither can drift from the other.
  GEN_FAMILIES = %w[unicast flow_spec]

  OUR_AS = 65001
  THEIR_AS = 65002
  F = LabHelper::Frr

  # The major versions these expectations were measured against, the
  # shape and the reason fault_matrix_frr_test.rb's MEASURED has.
  # 8.4.4, and 10.5.1 on the owner's VM on 2026-11-04 with no change to
  # an expectation: 5 tests, 241 assertions, all passing, and the IPv6
  # case omitted on 10 as its own comment says.
  MEASURED = (8..10).freeze

  # FRR's family names, by AFI.
  FAMILY = { 1 => 'ipv4 unicast', 2 => 'ipv6 unicast' }

  # FRR spells ORIGIN out, RFC 4271 section 5.1.1's three values.
  ORIGIN = { 0 => 'IGP', 1 => 'EGP', 2 => 'incomplete' }

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
  end

  def teardown
    @injector.stop if @injector
    @thread.kill if @thread
    @peer.close if @peer
    @server.close if @server && !@server.closed?
    if @router
      @router.down
      puts "\n== bgpd\n#{@router.log}" unless passed?
    end
  end

  # A bgpd that dials us, and a bgp4r speaker with 4-octet AS numbers
  # and IPv4 and IPv6 unicast, plus any extra families as [afi, safi].
  # ipv6: activate IPv6 unicast on FRR's side, which only the IPv6 case
  # needs. The harness leaves it off by default; see LabHelper::Frr.
  def session(extra = [], families = [], ipv6: false)
    @server = TCPServer.new('127.0.0.1', 0)
    @peer = BGP::Neighbor.new(4, OUR_AS, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
    @peer.capability :as4_byte
    @peer.capability :mbgp, :ipv4, :unicast
    @peer.capability :mbgp, :ipv6, :unicast
    extra.each { |afi, safi| @peer.add_cap BGP::OPT_PARM::CAP::Mbgp.new(afi, safi) }
    @thread = Thread.new do
      begin
        while (socket = @server.accept)
          @peer.start_session(socket)
        end
      rescue IOError, SystemCallError
      end
    end
    @router = F.new(:local => '127.0.0.2', :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS, :port => @server.addr[1],
                    :families => families, :ipv6 => ipv6)
    @router.up
    wait_for('the session', :timeout => 40) { @peer.is_established? }
  end

  # Announce, compare a sample with expected through FRR's per prefix
  # detail, which is the form that carries the communities, withdraw,
  # empty.
  def crosses(spec)
    g = BGP::Gen.new(spec)
    spec_crosses(@router, FAMILY[g.afi], g, @peer) do |rows|
      rows.each { |want| read(@router.detail(want['prefix'], FAMILY[g.afi]), want) }
    end
  end

  # What FRR read, against the row. LOCAL_PREF is not compared: FRR
  # drops it from an external peer, RFC 4271 section 5.1.5, and the
  # library alone sends what the spec says.
  def read(path, want)
    assert_not_nil(path, "FRR holds #{want['prefix']}")
    assert_equal(want['as_path'], path['aspath']['segments'].flat_map { |s| s['list'] }, want['prefix'])
    assert_equal(ORIGIN[want['origin']], path['origin'], 'ORIGIN')
    assert_equal(want['next_hop'], F.next_hop(path), 'the next hop, NEXT_HOP or inside MP_REACH_NLRI')
    assert_equal(want['med'], path['metric'], 'MULTI_EXIT_DISC')
    assert_equal(want['communities'], path['community'] && path['community']['list'], 'COMMUNITIES')
    assert_equal(want['large_communities'], path['largeCommunity'] && path['largeCommunity']['list'],
                 'LARGE_COMMUNITY')
  end

  ATTRIBUTES = { 'origin' => 2, 'as_path' => [OUR_AS, 65010, 4200000000], 'med' => 70,
                 'communities' => ['65000:1', '65000:2'], 'large_communities' => ['65000:1:1', '65000:2:3'] }

  def test_ipv4_unicast
    session
    crosses('family' => 'unicast', 'start' => '10.0.0.0/24', 'count' => 3000,
            'attributes' => ATTRIBUTES.merge('next_hop' => F::NEXT_HOP))
  end

  # FRR 10 refuses IPv6 unicast over an IPv4 session with no zebra, Cease
  # 6/0, measured against 10.5.1 on 2026-11-04. So this case needs 8.x
  # or a zebra, whatever LAB_FRR_ANY says.
  def test_ipv6_unicast
    major = F.major
    omit("FRR #{major} refuses IPv6 unicast here without zebra") if major && major >= 10
    session([], [], :ipv6 => true)
    crosses('family' => 'unicast', 'start' => '2001:db8::/64', 'count' => 1500,
            'attributes' => ATTRIBUTES.merge('next_hop' => '2001:db8::1'))
  end

  # A wrong set on a route, or two sets packed into one message, shows as
  # a sampled row FRR read differently from its expected values.
  def test_patterns_and_a_group
    session
    crosses('family' => 'unicast', 'start' => '10.0.0.0/24', 'count' => 2000, 'group' => 3, 'seed' => 21,
            'attributes' => {
              'origin' => { 'every' => { 'n' => 5, 'values' => [0, 2] } },
              'next_hop' => { 'step' => { 'start' => '192.0.2.1', 'by' => 1, 'wrap' => '192.0.2.200' } },
              'as_path' => { 'prepend' => { 'as' => OUR_AS, 'count' => { 'cycle' => [1, 2, 4] }, 'path' => [65010] } },
              'med' => { 'random' => { 'min' => 0, 'max' => 1000 } },
              'communities' => { 'count' => { 'base' => '65000:1', 'n' => { 'cycle' => [1, 3] } } },
              'large_communities' => { 'cycle' => [['65000:1:1'], ['65000:2:2', '65000:2:3']] } })
  end

  # RFC 8955: a flow spec feed, counted by FRR's own summary and read
  # back rule by rule. FRR's key for a rule carries the section 4.1
  # length, so it is FRR's rendering of our components and not ours.
  # The protocol per rule is stated by hand, so a component read off the
  # wrong route would not agree with itself here.
  def test_ipv4_flow_spec
    session([[1, 133]], [F::FS_IPV4])
    protocols = [6, 17]
    g = BGP::Gen.new('family' => 'flow_spec', 'start' => '10.0.0.0/24', 'count' => 200,
                     'protocol' => { 'cycle' => protocols },
                     'attributes' => { 'as_path' => [OUR_AS] })
    spec_crosses(@router, F::FS_IPV4, g, @peer) do |rows|
      held = @router.rib(F::FS_IPV4)
      rows.each do |want|
        key = held.keys.find { |k| k.start_with?("to #{want['destination']} ") }
        assert_not_nil(key, "FRR holds a rule to #{want['destination']}")
        n = want['destination'].split('.')[1].to_i * 256 + want['destination'].split('.')[2].to_i
        assert_match(/proto = #{protocols[n % 2]}\b/, key, "the protocol of rule #{n}")
      end
    end
  end

  # ---- through bgp4r-sim ------------------------------------------------

  # The same bgpd dialling an injector, so the session rules come from
  # the injector: our AS in front of the path and the next hop stated in
  # the spec, which FRR needs off loopback.
  def test_the_router_holds_what_the_injector_planned
    @router = F.new(:local => '127.0.0.2', :as => THEIR_AS, :router_id => '10.0.0.2',
                    :peer => '127.0.0.1', :peer_as => OUR_AS, :port => LabHelper::Local.free_port)
    @router.up
    @injector = BGP::Sim::Injector.new(
      'router_id' => '10.0.0.1', 'as' => OUR_AS,
      'listen_address' => '127.0.0.1', 'port' => @router.port,
      'neighbors' => [{ 'address' => '127.0.0.2', 'as' => THEIR_AS,
                        'capabilities' => ['as4_byte', { 'mbgp' => %w[ipv4 unicast] }] }])
    @injector.start
    wait_for('the injector session', :timeout => 40) { !@injector.speaker.established_peers.empty? }
    spec = { 'family' => 'unicast', 'start' => '10.0.0.0/24', 'count' => 1000, 'group' => 4,
             'attributes' => { 'as_path' => [65010], 'next_hop' => F::NEXT_HOP,
                               'med' => { 'cycle' => [5, 50, 500] } } }
    rows = @injector.plan('spec' => spec, 'limit' => 1000)[:plans].first[:rows]
    assert_equal(1000, rows.size)
    @injector.act('announce', { 'spec' => spec }, false)
    wait_for('FRR to hold 1000 routes', :timeout => 60) { @router.path_count == 1000 }
    LabHelper.sample(rows.size).each do |i|
      want = rows[i]
      assert_equal(OUR_AS, want['as_path'].first, 'the plan has our AS in front')
      read(@router.detail(want['prefix']), want)
    end
    @injector.act('withdraw', { 'spec' => spec }, false)
    wait_for('FRR to hold nothing', :timeout => 60) { @router.path_count == 0 }
  end
end
