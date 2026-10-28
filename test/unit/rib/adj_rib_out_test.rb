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

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibAdjRibOut < Test::Unit::TestCase

  PEER = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                            :router_id => '2.2.2.2', :local_as => 65001)

  def setup
    @out = BGP::Rib::AdjRibOut.new(PEER)
  end

  def attributes(next_hop = '10.0.0.1', local_pref: nil)
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new(next_hop), BGP::As_path.new(65001)]
    attrs << BGP::Local_pref.new(local_pref) if local_pref
    BGP::Path_attribute.new(*attrs)
  end

  def test_an_empty_one
    assert(@out.empty?)
    assert_equal(0, @out.size)
    assert_equal([], @out.prefixes)
    assert_equal(PEER, @out.peer)
    assert_nil(@out['10.0.0.0/8'])
  end

  def test_the_first_advertisement_is_new
    assert_equal(:new, @out.advertise('10.0.0.0/8', attributes))
    assert_equal(1, @out.size)
    assert_equal(['10.0.0.0/8'], @out.prefixes)
    assert(!@out.empty?)
  end

  # The point of keeping this: the same attributes again need no UPDATE.
  # Export builds a new Path_attribute every run, so the comparison is on
  # the encoded octets and not on object identity.
  def test_the_same_attributes_again_are_the_same
    @out.advertise('10.0.0.0/8', attributes)
    again = attributes
    assert_not_same(again, @out['10.0.0.0/8'], 'a different object')
    assert_equal(:same, @out.advertise('10.0.0.0/8', again))
    assert(@out.current?('10.0.0.0/8', attributes))
    assert_equal(1, @out.size, 'and it is still one route')
  end

  def test_other_attributes_are_a_change
    @out.advertise('10.0.0.0/8', attributes)
    assert_equal(:changed, @out.advertise('10.0.0.0/8', attributes('10.0.0.9')))
    assert_equal('10.0.0.9', @out['10.0.0.0/8'][BGP::Next_hop].next_hop)
    assert(!@out.current?('10.0.0.0/8', attributes))
    assert_equal(1, @out.size)
  end

  def test_withdraw_returns_what_was_sent
    pa = attributes
    @out.advertise('10.0.0.0/8', pa)
    assert_same(pa, @out.withdraw('10.0.0.0/8'))
    assert(@out.empty?)
    assert_nil(@out['10.0.0.0/8'])
  end

  # Nothing was sent for it, so nothing is withdrawn for it either.
  def test_withdrawing_what_the_peer_never_had_answers_nil
    assert_nil(@out.withdraw('10.0.0.0/8'))
    assert(@out.empty?)
  end

  def test_withdrawing_twice_answers_nil_the_second_time
    @out.advertise('10.0.0.0/8', attributes)
    assert_not_nil(@out.withdraw('10.0.0.0/8'))
    assert_nil(@out.withdraw('10.0.0.0/8'))
  end

  # The host bits are cleared and the prefix written one way, as everywhere
  # else in the RIB, so a lookup does not depend on how it was spelled.
  def test_a_prefix_is_normalised
    @out.advertise('10.0.0.1/8', attributes)
    assert_equal(['10.0.0.0/8'], @out.prefixes)
    assert_not_nil(@out['10.0.0.255/8'])
    assert_not_nil(@out.withdraw('10.0.0.0/8'))
  end

  # Add-path: one prefix, several paths, told apart by their Path Identifier
  # (RFC 7911 section 3), keyed the way AdjRibIn keys them.
  def test_two_paths_to_one_prefix
    assert_equal(:new, @out.advertise('10.0.0.0/8', attributes('10.0.0.1'), 7))
    assert_equal(:new, @out.advertise('10.0.0.0/8', attributes('10.0.0.2'), 9))
    assert_equal(2, @out.size)
    assert_equal(['10.0.0.0/8'], @out.prefixes, 'one prefix')
    assert_equal([7, 9], @out.path_ids('10.0.0.0/8').sort)
    assert_equal('10.0.0.1', @out['10.0.0.0/8', 7][BGP::Next_hop].next_hop)
    assert_equal('10.0.0.2', @out['10.0.0.0/8', 9][BGP::Next_hop].next_hop)
  end

  def test_withdrawing_one_path_leaves_the_other
    @out.advertise('10.0.0.0/8', attributes('10.0.0.1'), 7)
    @out.advertise('10.0.0.0/8', attributes('10.0.0.2'), 9)
    assert_not_nil(@out.withdraw('10.0.0.0/8', 7))
    assert_equal([9], @out.path_ids('10.0.0.0/8'))
    assert_equal(1, @out.size)
    assert_nil(@out['10.0.0.0/8', 7])
  end

  # A path with no Identifier and path 0 are different keys, the way they
  # are in the Adj-RIB-In.
  def test_no_path_id_is_not_path_id_zero
    @out.advertise('10.0.0.0/8', attributes('10.0.0.1'))
    @out.advertise('10.0.0.0/8', attributes('10.0.0.2'), 0)
    assert_equal(2, @out.size)
    assert_equal('10.0.0.1', @out['10.0.0.0/8'][BGP::Next_hop].next_hop)
    assert_equal('10.0.0.2', @out['10.0.0.0/8', 0][BGP::Next_hop].next_hop)
  end

  def test_a_path_id_is_read_as_an_integer
    @out.advertise('10.0.0.0/8', attributes, '7')
    assert_not_nil(@out['10.0.0.0/8', 7])
    assert_not_nil(@out['10.0.0.0/8', '7'])
  end

  def test_flush_forgets_everything
    @out.advertise('10.0.0.0/8', attributes)
    @out.advertise('10.1.0.0/16', attributes)
    assert_equal(%w[10.0.0.0/8 10.1.0.0/16], @out.flush.sort)
    assert(@out.empty?)
    assert_equal(0, @out.size)
    assert_nil(@out['10.0.0.0/8'])
  end

  def test_each_yields_the_prefix_the_path_id_and_the_attributes
    pa = attributes
    @out.advertise('10.0.0.0/8', pa)
    @out.advertise('10.1.0.0/16', pa, 7)
    seen = []
    @out.each { |prefix, id, attrs| seen << [prefix, id, attrs.equal?(pa)] }
    assert_equal([['10.0.0.0/8', nil, true], ['10.1.0.0/16', 7, true]], seen.sort_by { |s| s[0] })
  end

  def test_current_is_false_for_a_prefix_never_sent
    assert(!@out.current?('10.0.0.0/8', attributes))
  end

  # The comparison uses the 4-octet AS form, so what a session negotiated
  # cannot change the answer.
  def test_the_comparison_does_not_depend_on_the_as_encoding
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'),
                                 BGP::As_path.new(65536))
    @out.advertise('10.0.0.0/8', pa)
    same = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.1'),
                                   BGP::As_path.new(65536))
    assert_equal(:same, @out.advertise('10.0.0.0/8', same))
  end

  def test_to_s_counts_what_is_in_it
    assert_match(/0 routes/, @out.to_s)
    @out.advertise('10.0.0.0/8', attributes)
    assert_match(/1 route$/, @out.to_s)
    @out.advertise('10.1.0.0/16', attributes)
    assert_match(/2 routes/, @out.to_s)
  end
end
