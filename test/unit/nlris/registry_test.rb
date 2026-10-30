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
require 'bgp/nlris/registry'
require 'bgp/nlris/nlris'
require 'bgp/path_attributes/mp_reach'
require 'bgp/path_attributes/mp_unreach'
# Path_attribute, for the Attr::Gap assertion. Named here because this
# file fails on its own without it and passes in the suite, which is the
# load order trap Conventions describes.
require 'bgp/path_attributes/path_attribute'

class Nlri_registry_Test < Test::Unit::TestCase

  # Registering mutates one process wide registry, so a test that adds a
  # family puts both hashes back afterwards. Otherwise a scratch SAFI
  # would leak into test_the_two_sides_agree_on_every_family below and
  # the suite would depend on the order it ran in.
  def with_a_scratch_registry
    parsers = BGP::Nlri_registry.send(:nlri_parsers).dup
    builders = BGP::Nlri_registry.send(:nlri_builders).dup
    yield
  ensure
    BGP::Nlri_registry.instance_variable_set(:@nlri_parsers, parsers)
    BGP::Nlri_registry.instance_variable_set(:@nlri_builders, builders)
  end

  def test_the_five_families_bgp4r_reads_are_registered
    assert_equal([1, 2, 4, 128, 129], BGP::Nlri_registry.registered_safis)
  end

  # The whole point of the registry: the build side and the parse side
  # used to be two case statements that could disagree, and did, since
  # the parse side grouped SAFI 4 with 128 and 129 and the build side did
  # not. One registration per family is what makes that impossible, and
  # this is what says so.
  def test_the_two_sides_agree_on_every_family
    BGP::Nlri_registry.registered_safis.each do |safi|
      assert_not_nil(BGP::Nlri_registry.builder(safi),
                     "SAFI #{safi} parses but cannot be built")
      assert_not_nil(BGP::Nlri_registry.parser(1, safi),
                     "SAFI #{safi} builds but cannot be parsed")
    end
  end

  # An exact AFI wins over the :any one. That is not decoration: AFI 1
  # with SAFI 1 reads a whole NLRI list in one go where every other
  # prefix family reads one prefix at a time.
  def test_an_exact_afi_wins_over_any
    whole_list = BGP::Nlri_registry.parser(1, 1)
    one_prefix = BGP::Nlri_registry.parser(2, 1)
    assert_not_same(whole_list, one_prefix)
    assert_same(one_prefix, BGP::Nlri_registry.parser(3, 1))
    # Two prefixes in one field: the AFI 1 parser reads both, which is
    # what being keyed by AFI buys.
    both = BGP::Nlri.factory(['18c000020a0a'].pack('H*'), 1, 1)
    assert_equal(2, both.nlris.size)
  end

  def test_building_is_keyed_by_safi_alone
    assert_same(BGP::Nlri_registry.builder(1), BGP::Nlri_registry.builder(2))
    assert_not_same(BGP::Nlri_registry.builder(1), BGP::Nlri_registry.builder(4))
  end

  # A family with no registration raises on both sides, with the messages
  # unchanged from the case statements these replaced, because a script
  # may be matching on them.
  def test_an_unregistered_family_raises_the_same_way_on_both_sides
    assert_nil(BGP::Nlri_registry.parser(25, 70))
    assert_nil(BGP::Nlri_registry.builder(70))
    e = assert_raise(RuntimeError) { BGP::Nlri.factory(['00'].pack('H*'), 25, 70) }
    assert_equal('Afi 25 Safi 70 not supported!', e.message)
    e = assert_raise(RuntimeError) { BGP::Mp_reach.new(:afi => 25, :safi => 70, :nlris => ['x']) }
    assert_equal('SAFI 70 not implemented!', e.message)
  end

  # **The parse side raise is load bearing**, which is why the message
  # above is asserted rather than left to drift. A decoder that raises is
  # how Path_attribute files an Attr::Gap and keeps the attribute as an
  # Attr::Raw that encodes byte for byte, so a family bgp4r cannot read
  # still replays. Returning an object instead would delete the Gap.
  def test_an_unregistered_family_still_replays_byte_for_byte
    hex = '800e0e' + '001946' + '04' + '0a000001' + '00' + '0102030405'
    pa = BGP::Path_attribute.new([hex].pack('H*').is_packed)
    assert_equal(hex, pa.to_shex)
    assert_equal([BGP::Attr::Raw], pa.attributes.collect { |a| a.class })
    assert_equal(0, pa.errors.size)
    assert_equal([BGP::Attr::Gap], pa.undecoded.collect { |g| g.class })
  end

  def test_a_family_can_be_added_from_outside
    with_a_scratch_registry do
      BGP::Nlri_registry.register_parse(70) { |s, _a, _s, _p, _w| s.unpack1('H*') }
      BGP::Nlri_registry.register_build(70) { |nlris, _a, _s, _p| [nlris].flatten }
      assert_equal('0a0b', BGP::Nlri.factory(['0a0b'].pack('H*'), 25, 70))
      assert_not_nil(BGP::Nlri_registry.builder(70))
    end
    assert_nil(BGP::Nlri_registry.builder(70), 'the scratch registry leaked')
  end

  # The trap this work fell into, so it cannot come back. nlri.rb creates
  # BGP::Nlri and BGP::Withdrawn inside `unless const_defined?(:Nlri)`,
  # so a file loading earlier that defines BGP::Nlri skips that whole
  # block: Nlri loses every Base_nlri method and Withdrawn is never
  # defined at all. The first draft of the registry did exactly that by
  # opening `class Nlri`, and the failures named neither constant.
  def test_nlri_and_withdrawn_are_the_base_nlri_subclasses
    assert_equal(BGP::Base_nlri, BGP::Nlri.superclass)
    assert_equal(BGP::Base_nlri, BGP::Withdrawn.superclass)
    assert_respond_to(BGP::Nlri, :new_ntop)
    assert(!BGP.const_defined?(:Nlri_registry, false) ||
           BGP::Nlri_registry.is_a?(Module),
           'the registry must be a module, not a reopened Nlri class')
  end

end
