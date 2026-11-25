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

# End-of-RIB's families and configuration. What goes on the wire, and
# when, is test/functional/end_of_rib_test.rb.
class TestDaemonEndOfRib < Test::Unit::TestCase

  E = BGP::Daemon::EndOfRib

  def speaker(neighbors)
    BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'neighbors' => neighbors)
  end

  def open(*families)
    BGP::Open.new(4, 65_000, 180, '10.0.0.1', *families.collect { |a, s| BGP::OPT_PARM::CAP::Mbgp.new(a, s) })
  end

  def info(ours, theirs)
    BGP::Neighbor::Capabilities.new(ours, theirs)
  end

  # RFC 4760 section 8: a family both OPENs list, in our order.
  def test_the_families_are_those_both_list
    assert_equal([[1, 1], [2, 1]], E.families(info(open([1, 1], [2, 1], [1, 128]), open([2, 1], [1, 1]))))
    assert_equal([[1, 1]], E.families(info(open([1, 1], [2, 1]), open([1, 1]))))
    assert_equal([], E.families(info(open([2, 1]), open([1, 128]))))
  end

  # An OPEN without a Multiprotocol capability is IPv4 unicast only.
  def test_no_multiprotocol_capability_is_ipv4_unicast
    assert_equal([[1, 1]], E.families(info(open, open)))
    assert_equal([[1, 1]], E.families(info(open([1, 1], [2, 1]), open)))
    assert_equal([], E.families(info(open([2, 1]), open)))
    assert_equal([], E.families(nil), 'no session')
  end

  def test_the_marker_of_each_family
    assert_equal(23, E.marker(1, 1).encode.bytesize)
    assert_equal([2, 1], BGP::Update.new(E.marker(2, 1).encode).end_of_rib)
  end

  def test_true_or_false_and_nothing_else
    [true, false].each do |v|
      assert_nothing_raised { speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'end_of_rib' => v }]) }
    end
    ['yes', 1, 'true'].each do |v|
      e = assert_raise(ArgumentError, v.inspect) { speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'end_of_rib' => v }]) }
      assert_equal("neighbor 10.0.0.2: end_of_rib is true or false, got #{v.inspect}", e.message)
    end
  end

  def test_the_peer_reads_it
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001, 'end_of_rib' => true },
                  { 'address' => '10.0.0.3', 'as' => 65_001 }])
    assert_equal([true, false], %w[10.0.0.2 10.0.0.3].collect { |a| sp.peer(a).end_of_rib? })
  end

  # The Recorder keeps what came, once per family, and forgets it with
  # the session; the row says so only once one has come.
  def test_the_recorder_and_the_row
    sp = speaker([{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    peer = sp.peer('10.0.0.2')
    rows = -> { BGP::Daemon::Views.new(sp).peers.first }
    assert_equal(false, rows.().key?(:end_of_rib_received))
    [BGP::Update.end_of_rib_marker(:afi => 2, :safi => 1), BGP::Update.end_of_rib_marker,
     BGP::Update.end_of_rib_marker].each { |m| peer.recorder.update(BGP::Update.new(m.encode)) }
    assert_equal([{ :afi => 2, :safi => 1 }, { :afi => 1, :safi => 1 }], rows.()[:end_of_rib_received])
    assert_equal([{ 'afi' => 2, 'safi' => 1 }, { 'afi' => 1, 'safi' => 1 }], peer.recorder.snapshot['end_of_rib_received'])
    peer.recorder.session_down!
    assert_equal(false, rows.().key?(:end_of_rib_received))
  end
end
