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
require 'bgp4r'

class Role_cap_Test < Test::Unit::TestCase

  # RFC 9234 section 4.1 gives the capability as three labelled fields:
  # "Code:" is "9", "Length:" is "1 (octet)" and the value is an "integer
  # corresponding to the speaker's BGP Role (see Table 1)". So the
  # capability is 09 01 <role> behind the RFC 5492 section 4 optional
  # parameter header.
  CUSTOMER_WIRE = '0203090103'

  # Table 1, "Predefined BGP Role Values": 0 Provider, 1 RS, 2 RS-Client,
  # 3 Customer, 4 "Peer (i.e., Lateral Peer)", 5 to 255 unassigned.
  TABLE_1 = {
    0 => [:provider,  'Provider'],
    1 => [:rs,        'RS'],
    2 => [:rs_client, 'RS-Client'],
    3 => [:customer,  'Customer'],
    4 => [:peer,      'Peer'],
  }

  def test_the_capability_code_is_9_and_the_length_is_one_octet
    assert_equal 9, BGP::OPT_PARM::CAP_ROLE
    cap = BGP::OPT_PARM::CAP::Role.new(:customer)
    assert_equal CUSTOMER_WIRE, cap.to_shex
    assert_equal 9, cap.to_hash[:code]
    # the optional parameter is 5 octets: its own 2, the capability code,
    # the capability length and the one octet Role
    assert_equal 5, cap.encode.size
    assert_equal 3, cap.role
  end

  # Every value of Table 1, by name and by number, with the name the RFC
  # gives it.
  def test_the_five_predefined_role_values
    TABLE_1.each do |value, (symbol, name)|
      by_symbol = BGP::OPT_PARM::CAP::Role.new(symbol)
      by_number = BGP::OPT_PARM::CAP::Role.new(value)
      assert_equal by_number.to_shex, by_symbol.to_shex, "role #{symbol}"
      assert_equal value, by_symbol.role
      assert_equal name, by_symbol.role_name
      assert_equal '020309' + '01' + ('%02x' % value), by_symbol.to_shex
      assert_equal({:code => 9, :role => value}, by_symbol.to_hash)
    end
  end

  def test_the_three_build_paths
    from_fields = BGP::OPT_PARM::CAP::Role.new(:customer)
    from_wire   = BGP::OPT_PARM::CAP::Role.new([CUSTOMER_WIRE].pack('H*'))
    from_hash   = BGP::OPT_PARM::CAP::Role.new(from_fields.to_hash)
    [from_fields, from_wire, from_hash].each do |cap|
      assert_equal CUSTOMER_WIRE, cap.to_shex
      assert_equal({:code => 9, :role => 3}, cap.to_hash)
      assert_equal 3, cap.role
    end
    # the hash takes a name too, not only the number it carries
    assert_equal CUSTOMER_WIRE,
                 BGP::OPT_PARM::CAP::Role.new(:role => :customer).to_shex
  end

  def test_it_round_trips_through_the_wire
    TABLE_1.each_key do |value|
      cap = BGP::OPT_PARM::CAP::Role.new(value)
      back = BGP::OPT_PARM::CAP::Role.new([cap.to_shex].pack('H*'))
      assert_equal cap.to_shex, back.to_shex
      assert_equal cap.to_hash, back.to_hash
      assert_equal cap.to_shex,
                   BGP::OPT_PARM::CAP::Role.new(back.to_hash).to_shex
    end
  end

  def test_the_factory_reads_it
    cap = BGP::OPT_PARM::Capability.factory([CUSTOMER_WIRE].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Role, cap
    assert_equal CUSTOMER_WIRE, cap.to_shex
    assert_equal({:code => 9, :role => 3}, cap.to_hash)
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: in a Capability message the
  # capability has a one octet code and a two octet length, so the DYN_CAP
  # class generated from this one writes 09 0001 03.
  def test_the_dynamic_factory_reads_it
    cap = BGP::OPT_PARM::Capability.dynamic_factory(['09000103'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::DYN_CAP::Role, cap
    assert_equal '09000103', cap.to_shex
    assert_equal '09000103', BGP::OPT_PARM::DYN_CAP::Role.new(:customer).to_shex
  end

  def test_to_s
    assert_equal "Option Capabilities Advertisement (2): [#{CUSTOMER_WIRE}]\n" +
                 '    BGP Role (9), length: 3: Customer (3)',
                 BGP::OPT_PARM::CAP::Role.new(:customer).to_s
    assert_equal 'BGP Role Customer (3)',
                 BGP::OPT_PARM::CAP::Role.new(:customer).to_s_brief
    assert_equal 'BGP Role Peer (4)',
                 BGP::OPT_PARM::CAP::Role.new(:peer).to_s_brief
  end

  # Nothing is validated on the way out. RFC 9234 section 4.1 leaves 5 to
  # 255 unassigned, and sending one to see what a router does is exactly
  # what this library is for, so it builds, encodes and round trips.
  def test_a_role_value_the_rfc_does_not_define
    cap = BGP::OPT_PARM::CAP::Role.new(200)
    assert_equal '02030901c8', cap.to_shex
    assert_equal 200, cap.role
    assert_equal 'Unassigned', cap.role_name
    assert_equal 'BGP Role Unassigned (200)', cap.to_s_brief
    assert_equal({:code => 9, :role => 200}, cap.to_hash)
    back = BGP::OPT_PARM::Capability.factory([cap.to_shex].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Role, back
    assert_equal cap.to_shex, back.to_shex
    assert_equal cap.to_hash, back.to_hash
    assert_equal cap.to_shex, BGP::OPT_PARM::CAP::Role.new(cap.to_hash).to_shex
    # the ends of the unassigned range, not just the one value
    [5, 127, 255].each do |value|
      assert_equal '020309' + '01' + ('%02x' % value),
                   BGP::OPT_PARM::CAP::Role.new(value).to_shex
    end
  end

  # The field is one octet, so an Integer outside it cannot be sent. Per
  # the rule on an input a field cannot hold, the constructor refuses it
  # rather than quietly advertising another Role.
  def test_a_role_the_one_octet_field_cannot_hold_is_refused
    assert_raise(ArgumentError) { BGP::OPT_PARM::CAP::Role.new(256) }
    assert_raise(ArgumentError) { BGP::OPT_PARM::CAP::Role.new(-1) }
    assert_raise(ArgumentError) { BGP::OPT_PARM::CAP::Role.new(:bogus) }
    # the octet level route stays open: 256 is two octets, so send them
    with_two = BGP::OPT_PARM::CAP::Role.new(:code => 9, :value => '0100')
    assert_equal '020409020100', with_two.to_shex
  end

  # RFC 9234 section 4.1 gives the capability a length of one octet, so a
  # value of another size is wrong by the RFC. An implementation that
  # sends one still has to be readable: the octets are kept and written
  # back, and nothing calls it a protocol error.
  def test_a_value_that_is_not_one_octet_is_kept
    with_value = BGP::OPT_PARM::CAP::Role.new(['020409' + '02' + 'aabb'].pack('H*'))
    assert_equal '02040902aabb', with_value.to_shex
    assert_nil with_value.role
    assert_equal({:code => 9, :value => 'aabb'}, with_value.to_hash)
    assert_equal '02040902aabb',
                 BGP::OPT_PARM::CAP::Role.new(with_value.to_hash).to_shex
    assert_match(/length: 4/, with_value.to_s)
    assert_match(/malformed, 2 value octets/, with_value.to_s)
    empty = BGP::OPT_PARM::CAP::Role.new(['020209' + '00'].pack('H*'))
    assert_equal '02020900', empty.to_shex
    assert_equal({:code => 9, :value => ''}, empty.to_hash)
  end

  # An OPEN carries it like any other capability. RFC 9234 section 4.1:
  # "If the BGP Role is locally configured, the eBGP speaker MUST
  # advertise the BGP Role Capability in the BGP OPEN message."
  def test_in_an_open_message
    open = BGP::Open.new(4, 100, 200, '10.0.0.1',
                         BGP::OPT_PARM::CAP::Role.new(:provider))
    back = BGP::Message.factory(open.encode)
    assert_equal open.to_shex, back.to_shex
    cap = back.find(BGP::OPT_PARM::CAP::Role)
    assert cap, 'the BGP Role capability reads back out of an OPEN'
    assert_equal 0, cap.role
    assert_equal 'Provider', cap.role_name
  end

  # Section 4.1: "An eBGP speaker MUST NOT advertise multiple versions of
  # the BGP Role Capability." Section 4.2 says what a receiver does with
  # two that disagree, so bgp4r has to be able to send them: nothing here
  # refuses the OPEN that breaks the MUST NOT.
  def test_two_role_capabilities_in_one_open
    open = BGP::Open.new(4, 100, 200, '10.0.0.1',
                         BGP::OPT_PARM::CAP::Role.new(:provider),
                         BGP::OPT_PARM::CAP::Role.new(:customer))
    back = BGP::Message.factory(open.encode)
    assert_equal open.to_shex, back.to_shex
    roles = back.opt_parms.find_all { |p| p.is_a?(BGP::OPT_PARM::CAP::Role) }
    assert_equal [0, 3], roles.collect { |p| p.role }
  end
end
