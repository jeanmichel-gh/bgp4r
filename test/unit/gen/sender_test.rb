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
require 'bgp/gen'

# The session a spec is sent on: the three rules an announce block gets,
# applied to a spec, and the sender keys refused.
#
#   ruby -I. test/unit/gen/sender_test.rb
#
# **The assertion that matters is that `updates` and `expected` agree**,
# since the rules exist so that a dry run says what a send does. So each
# rule is read off the octets that would go out and off the expected row.
class TestBgpGenSender < Test::Unit::TestCase

  EBGP = { 'as' => 65_001, 'ebgp' => true, 'next_hop' => '10.0.0.1' }.freeze
  IBGP = { 'as' => 65_001, 'ebgp' => false, 'next_hop' => '10.0.0.1' }.freeze

  def gen(attributes, sender, spec = {})
    BGP::Gen.new({ 'start' => '10.0.0.0/24', 'count' => 2,
                   'attributes' => attributes }.merge(spec), sender)
  end

  def sent(g)
    BGP::Update.new(g.updates.first.encode(BGP::Update::Info.new(true)).is_packed,
                    BGP::Update::Info.new(true, :strict)).path_attribute
  end

  def test_over_ebgp_our_as_goes_in_front
    g = gen({ 'as_path' => [65_020] }, EBGP)
    assert_equal('65001 65020', sent(g)[:as_path].as_path)
    assert_equal([65_001, 65_020], g.expected.first['as_path'])
  end

  # Phase 0b's key, meaning the same thing for a spec.
  def test_as_path_literal_sends_the_path_as_written
    g = gen({ 'as_path' => [65_020] }, EBGP.merge('as_path_literal' => true))
    assert_equal('65020', sent(g)[:as_path].as_path)
    assert_equal([65_020], g.expected.first['as_path'])
  end

  def test_over_ibgp_the_path_is_left_alone
    g = gen({ 'as_path' => [65_020] }, IBGP)
    assert_equal('65020', sent(g)[:as_path].as_path)
  end

  # The prepend goes in front of what a pattern gives, route by route.
  def test_the_prepend_goes_in_front_of_a_pattern
    g = gen({ 'as_path' => { 'cycle' => [[1], [2]] } }, EBGP)
    assert_equal([[65_001, 1], [65_001, 2]], g.expected.collect { |r| r['as_path'] })
  end

  def test_the_session_address_is_the_next_hop_when_the_spec_gives_none
    g = gen({}, EBGP)
    assert_equal('10.0.0.1', sent(g)[:next_hop].next_hop)
    assert_equal('10.0.0.1', g.expected.first['next_hop'])
  end

  def test_a_next_hop_the_spec_gives_wins
    g = gen({ 'next_hop' => '192.0.2.9' }, EBGP)
    assert_equal('192.0.2.9', sent(g)[:next_hop].next_hop)
  end

  # An IPv6 spec on an IPv4 session: Mp_reach writes the IPv4 address as
  # an IPv4-mapped one by itself, which is the library's rule and not one
  # the sender adds.
  def test_an_ipv6_spec_on_an_ipv4_session_gets_a_mapped_next_hop
    g = gen({}, EBGP, 'start' => '2001:db8::/48')
    mp = sent(g)[:mp_reach]
    assert_match(/00000000000000000000ffff0a000001/, mp.to_shex, 'the IPv4-mapped form, RFC 4291 section 2.5.5.2')
    assert_equal('10.0.0.1', g.expected.first['next_hop'])
  end

  # RFC 4271 section 5.1.5, as an announce block gets it: dropped toward
  # an external peer even when the spec asks for one, and 100 toward an
  # internal peer when it does not.
  def test_local_pref_never_goes_to_an_external_peer
    g = gen({ 'local_pref' => 300 }, EBGP)
    assert_nil(sent(g)[:local_pref])
    assert_nil(g.expected.first['local_pref'])
  end

  def test_local_pref_defaults_to_100_toward_an_internal_peer
    g = gen({}, IBGP)
    assert_equal(100, sent(g)[:local_pref].to_i)
    assert_equal(100, g.expected.first['local_pref'])
  end

  def test_a_local_pref_the_spec_gives_goes_to_an_internal_peer
    g = gen({ 'local_pref' => 300 }, IBGP)
    assert_equal(300, sent(g)[:local_pref].to_i)
  end

  # The same spec on the two kinds of session is two different
  # expectations, which is why `/api/plan` answers per peer.
  def test_one_spec_two_sessions_two_answers
    a = gen({ 'as_path' => [65_020] }, EBGP).expected.first
    b = gen({ 'as_path' => [65_020] }, IBGP).expected.first
    assert_not_equal(a, b)
  end

  # With no sender nothing changes, which is phases 1 and 2.
  def test_no_sender_sends_as_written
    g = gen({ 'as_path' => [65_020] }, nil)
    assert_equal('65020', sent(g)[:as_path].as_path)
    assert_nil(sent(g)[:next_hop])
    assert_nil(sent(g)[:local_pref])
  end

  def test_symbol_keys_read_like_strings
    g = gen({ 'as_path' => [65_020] }, :as => 65_001, :ebgp => true)
    assert_equal('65001 65020', sent(g)[:as_path].as_path)
  end

  # ---- refusals ------------------------------------------------------

  def test_an_unknown_sender_key_is_refused
    e = assert_raise(BGP::Gen::SpecError) { gen({}, EBGP.merge('asn' => 1)) }
    assert_match(/asn/, e.message)
    assert_match(/as, ebgp, next_hop, as_path_literal/, e.message)
  end

  def test_a_sender_that_is_not_a_hash_is_refused
    assert_raise(BGP::Gen::SpecError) { gen({}, [1]) }
  end

  # A string "true" would quietly mean something, as Injector#check says
  # of as_path_literal.
  def test_a_flag_that_is_not_a_boolean_is_refused
    %w[ebgp as_path_literal].each do |k|
      e = assert_raise(BGP::Gen::SpecError, k) { gen({}, EBGP.merge(k => 'true')) }
      assert_match(/#{k}/, e.message)
    end
  end

  def test_an_ebgp_sender_needs_its_own_as
    [nil, -1, 2**32, '65001'].each do |bad|
      assert_raise(BGP::Gen::SpecError, bad.inspect) { gen({}, EBGP.merge('as' => bad)) }
    end
    assert_nothing_raised { gen({}, EBGP.merge('as' => nil, 'as_path_literal' => true)) }
  end

  def test_a_sender_next_hop_that_is_not_an_address_is_refused
    assert_raise(BGP::Gen::SpecError) { gen({}, EBGP.merge('next_hop' => 'router')) }
  end

end
