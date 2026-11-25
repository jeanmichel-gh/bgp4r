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

# GTSM's arithmetic and its configuration. What the kernel does with the
# options is test/functional/gtsm_test.rb, over loopback.
class TestDaemonGtsm < Test::Unit::TestCase

  def speaker(neighbors, extra = {})
    BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1', 'neighbors' => neighbors }.merge(extra))
  end

  def test_the_minimum_is_256_less_the_hops
    assert_equal(255, BGP::Daemon::Gtsm.minimum(1))
    assert_equal(253, BGP::Daemon::Gtsm.minimum(3))
    assert_equal(2, BGP::Daemon::Gtsm.minimum(254))
  end

  def test_linux_ipv6_minhopcount_is_73
    assert_equal(73, BGP::Daemon::Gtsm::IPV6_MINHOPCOUNT)
  end

  # The listener drops only what every peer on it would.
  def test_the_listener_minimum
    g = BGP::Daemon::Gtsm
    assert_nil(g.listener_minimum([]), 'no passive peer')
    assert_nil(g.listener_minimum([nil, nil]), 'no GTSM peer')
    assert_equal(255, g.listener_minimum([1, 1]))
    assert_equal(253, g.listener_minimum([1, 3]), 'the loosest of them')
    assert_nil(g.listener_minimum([1, nil]),
               'a peer without GTSM sends at its default TTL, so nothing is dropped')
  end

  def test_hops_from_1_to_254_are_taken
    [1, 2, 254].each do |h|
      assert_nothing_raised { speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'ttl_security' => h }]) }
    end
  end

  # A value read some other way is refused at start, by name.
  def test_anything_else_is_refused
    [0, 255, -1, '1', 1.0, true].each do |v|
      e = assert_raise(ArgumentError, v.inspect) do
        speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'ttl_security' => v }])
      end
      assert_match(/neighbor 10.0.0.2: ttl_security is a number of hops, 1 to 254, got #{Regexp.escape(v.inspect)}/,
                   e.message)
    end
  end

  # Only passive peers on the listener count: an active one dials out
  # and never reaches it, and a CE's is its VRF's listener.
  def test_the_speaker_listener_minimum_reads_its_own_passive_peers
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'ttl_security' => 1 },
                  { 'address' => '10.0.0.3', 'as' => 65_001, 'ttl_security' => 5, 'connect' => true },
                  { 'address' => '10.0.0.4', 'as' => 65_001, 'ttl_security' => 3, 'vrf' => 'A' }],
                 'vrfs' => [{ 'name' => 'A', 'table' => 100, 'import' => ['65000:100'] }])
    assert_equal(255, sp.listener_minimum)
    assert_equal(true, sp.gtsm_listener?)
    assert_equal(253, sp.listener_minimum('A'))
  end

  def test_no_ttl_security_no_gtsm_listener
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    assert_equal(false, sp.gtsm_listener?)
    assert_nil(sp.listener_minimum)
  end

  # A peer row says so only where the key is set, so every other row
  # reads as it always has.
  def test_show_peers_has_ttl_security_on_a_gtsm_neighbor_only
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'ttl_security' => 2 },
                  { 'address' => '10.0.0.3', 'as' => 65_001 }])
    rows = BGP::Daemon::Views.new(sp).peers.to_h { |r| [r[:address], r] }
    assert_equal({ :hops => 2, :min_ttl => 254 }, rows['10.0.0.2'][:ttl_security])
    assert_equal(false, rows['10.0.0.3'].key?(:ttl_security))
  end
end
