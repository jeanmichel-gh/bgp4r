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
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# Route refresh's rules and counts. The answers on the wire are
# test/functional/route_refresh_test.rb.
class TestDaemonRefresh < Test::Unit::TestCase

  R = BGP::Daemon::Refresh
  CAP = BGP::OPT_PARM::CAP

  def open(*caps)
    BGP::Open.new(4, 65_000, 180, '10.0.0.1', *caps)
  end

  def info(ours, theirs = open)
    BGP::Neighbor::Capabilities.new(ours, theirs)
  end

  def rr ; CAP::Route_refresh.new ; end
  def err ; CAP::Enhanced_route_refresh.new ; end
  def mp(afi, safi) ; CAP::Mbgp.new(afi, safi) ; end

  # RFC 2918 section 4: our OPEN must carry the capability and the
  # family; an OPEN with no Multiprotocol capability carries IPv4
  # unicast.
  def test_what_is_answered
    assert_nil(R.refusal(info(open(rr)), 1, 1))
    assert_nil(R.refusal(info(open(err)), 1, 1), 'capability 70 alone will do')
    assert_nil(R.refusal(info(open(rr, mp(1, 1), mp(2, 1))), 2, 1))
    assert_equal('we did not advertise AFI 2 SAFI 1', R.refusal(info(open(rr)), 2, 1))
    assert_equal('we did not advertise AFI 1 SAFI 1', R.refusal(info(open(rr, mp(2, 1))), 1, 1))
    assert_equal('we did not advertise the Route Refresh capability', R.refusal(info(open(mp(1, 1))), 1, 1))
    assert_equal('no session', R.refusal(nil, 1, 1))
  end

  # RFC 7313 section 4: BoRR and EoRR only to a peer that sent 70.
  def test_enhanced_is_the_peers_capability
    assert_equal(true, R.enhanced?(info(open(rr), open(rr, err))))
    assert_equal(false, R.enhanced?(info(open(rr, err), open(rr))))
    assert_equal(false, R.enhanced?(nil))
  end

  def test_the_family_of_an_update
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new, BGP::Next_hop.new('10.0.0.1'))
    assert_equal([1, 1], R.family(BGP::Update.new(pa, BGP::Nlri.new('10.1.0.0/16'))))
    assert_equal([1, 1], R.family(BGP::Update.new(BGP::Withdrawn.new('10.1.0.0/16'))))
    v6 = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :prefix => '2001:db8:1::/48'))
    assert_equal([2, 1], R.family(BGP::Update.new(v6)))
    assert_equal([2, 1], R.family(BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8:1::/48'])))))
  end

  # Counted by subtype both ways, as FRR counts; the row says so once
  # there is something to say, and a new session starts again.
  def test_counts_and_the_row
    sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1',
                                  'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    peer = sp.peer('10.0.0.2')
    row = -> { BGP::Daemon::Views.new(sp).peers.first }
    assert_equal(false, row.().key?(:refresh))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, :borr))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, :eorr))
    peer.route_refresh.update(BGP::Route_refresh.new(1, 1, 3))
    assert_equal({ :received => { :borr => 1, :eorr => 1, :other => 1 }, :sent => {}, :answered => 0, :ignored => 0 },
                 row.()[:refresh])
    peer.route_refresh.reset
    assert_equal(false, row.().key?(:refresh))
  end
end
