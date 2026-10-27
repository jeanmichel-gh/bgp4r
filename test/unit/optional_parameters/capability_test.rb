#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

class Capability_Test < Test::Unit::TestCase
  include BGP::OPT_PARM
  include BGP::OPT_PARM::CAP
  def test_1
    cap = Capability.new(100)
    assert_equal '02026400', cap.to_shex
    assert_equal '0207640576616c7565', cap.to_shex('value')
    assert_equal "Option Capabilities Advertisement (2): [02026400]", cap.to_s
    assert_equal cap.to_shex, Capability.factory(cap.encode).to_shex
  end
  def test_factory_graceful_restart
    s = '020c400a00780001010100010201'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Graceful_restart, cap)
  end
  def test_factory_as4
    s = '0206410400000064'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(As4, cap)
  end
  def test_factory_route_refresh
    s = '02020200'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Route_refresh, cap)
    s = '02028000'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Route_refresh, cap)
  end
  def test_factory_mbgp
    s = '0206010400010001'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Mbgp, cap)
  end
  def test_factory_orf
    s = '0218031600010001030101020103010001000203010102010301'
    cap = Capability.factory([s].pack('H*'))
    assert_equal(Orf, cap.class)
  end
  def test_factory_add_path
    s = '020e450c000101010002800200020103'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Add_path, cap)
  end
  def test_factory_unknown
    s = '0207640576616c7565'
    cap = Capability.factory([s].pack('H*'))
    assert_equal(Capability::Unknown, cap.class)
  end
  def test_unknown_keeps_the_octets_it_cannot_name
    cap = Capability.factory(['0207640576616c7565'].pack('H*'))
    assert_equal(Capability::Unknown, cap.class)
    assert_equal '0207640576616c7565', cap.to_shex
    assert_equal({:code=>100}, cap.to_hash)
    assert_equal 'Option Capabilities Advertisement (2): [0207640576616c7565]', cap.to_s
  end
  def test_unknown_refuses_what_it_cannot_parse
    # Unknown only knows how to read wire bytes, so anything else is
    # refused rather than silently kept as a capability value.
    assert_raise(ArgumentError) { Capability::Unknown.new(42) }
    assert_raise(ArgumentError) { Capability::Unknown.new('0207640576616c7565') }
  end
  def test_to_hash
    assert_equal({:code=>100}, Capability.new(100).to_hash)
    assert_equal({:code=>100, :capability=>{:as=>100}},
                 Capability.new(100).to_hash({:as=>100}))
  end
  def test_factory_dynamic
    # RFC 5492 section 4 and draft-ietf-idr-dynamic-cap-19 section 9:
    # capability code 67, no value.
    cap = Capability.factory(['02024300'].pack('H*'))
    assert_instance_of(Dynamic, cap)
    # The capability came off the wire, so it has to go back on the wire
    # unchanged. Before this was fixed the factory handed Dynamic the
    # wire bytes where it wanted the code, and encode raised TypeError.
    assert_equal '02024300', cap.to_shex
    assert_equal({:code=>67}, cap.to_hash)
    assert_equal "Option Capabilities Advertisement (2): [02024300]\n" +
                 '    Dynamic Capability 67, length: 2', cap.to_s
  end
  def test_open_round_trips_a_dynamic_capability
    # The same bug seen from where it bites: an OPEN that advertises
    # dynamic capability could not be re-encoded or printed.
    body = '010400640078010101010402024300'
    w = ['ff' * 16 + format('%04x', 18 + (body.size / 2)) + body].pack('H*')
    open = BGP::Open.new(w)
    assert_instance_of(Dynamic, open.find(Dynamic))
    assert_equal w.unpack('H*')[0], open.to_shex
  end

  # RFC 5492 section 4: one Capabilities optional parameter carries one
  # or more capabilities. Reading only the first used to drop the rest
  # in silence, 4-octet AS among them.
  def test_capabilities_parameter_with_two_capabilities
    s = ['02080200410400000064'].pack('H*')
    caps = Optional_parameter.factory(s)
    assert_equal 2, caps.size
    assert_instance_of(Route_refresh, caps[0])
    assert_instance_of(As4, caps[1])
    # Each capability comes back as the one capability parameter bgp4r
    # sends, so each encodes on its own.
    assert_equal '02020200', caps[0].to_shex
    assert_equal '0206410400000064', caps[1].to_shex
    assert_equal({:code=>65, :capability=>{:as=>100}}, caps[1].to_hash)
    assert_equal 0, s.size, 'the whole parameter is consumed'
  end
  def test_capabilities_parameter_with_four_capabilities
    s = ['021002000104000100014104000000644300'].pack('H*')
    caps = Optional_parameter.factory(s)
    assert_equal [Route_refresh, Mbgp, As4, Dynamic], caps.collect { |c| c.class }
    assert_equal ['02020200', '0206010400010001', '0206410400000064', '02024300'],
                 caps.collect { |c| c.to_shex }
    assert_equal 0, s.size
  end
  def test_as4_is_read_when_it_is_not_the_first_capability
    # The bug this guards: 4-octet AS packed behind another capability
    # was missed, bgp4r kept the 2-octet default and sent an AS_PATH the
    # peer could not parse.
    body = '0104d6e00078010101010a0208' + '0200' + '410400010002'
    w = ['ff' * 16 + format('%04x', 18 + (body.size / 2)) + body].pack('H*')
    open = BGP::Open.new(w)
    assert_equal 2, open.opt_parms.size
    assert_instance_of(As4, open.find(As4))
    assert_equal({:as=>65538}, open.find(As4).to_hash[:capability])
  end
  def test_capabilities_parameter_stops_at_a_length_past_the_end
    # A capability whose declared length runs off the end of the
    # parameter is dropped rather than read as whatever follows it.
    s = ['0206410600000064'].pack('H*')
    assert_equal [], Optional_parameter.factory(s)
    s = ['020141'].pack('H*')
    assert_equal [], Optional_parameter.factory(s)
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: the same capabilities
  # carried in a Dynamic Capability message have a one octet code and a
  # two octet length, so they encode and parse through a different
  # branch.
  def test_dynamic_factory_as4
    cap = Capability.dynamic_factory(['41000400000064'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::As4, cap)
    assert_equal '41000400000064', cap.to_shex
    assert_equal({:code=>65, :capability=>{:as=>100}}, cap.to_hash)
  end
  def test_dynamic_factory_mbgp
    cap = Capability.dynamic_factory(['01000400010001'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Mbgp, cap)
    assert_equal '01000400010001', cap.to_shex
  end
  def test_dynamic_factory_route_refresh
    cap = Capability.dynamic_factory(['020000'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Route_refresh, cap)
    assert_equal '020000', cap.to_shex
    cap = Capability.dynamic_factory(['800000'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Route_refresh, cap)
    assert_equal '800000', cap.to_shex
  end
  def test_dynamic_factory_orf
    s = '03001600010001030101020103010001000203010102010301'
    cap = Capability.dynamic_factory([s].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Orf, cap)
    assert_equal s, cap.to_shex
  end
  def test_dynamic_factory_add_path
    cap = Capability.dynamic_factory(['45000400010101'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Add_path, cap)
    assert_equal '45000400010101', cap.to_shex
    assert_equal true, cap.send?(1, 1)
    assert_equal false, cap.recv?(1, 1)
  end
  def test_dynamic_factory_graceful_restart
    s = '40000a00780001010100010201'
    cap = Capability.dynamic_factory([s].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Graceful_restart, cap)
    assert_equal s, cap.to_shex
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: the capability here has a
  # one octet code and a two octet length, so a code bgp4r does not
  # implement has to be kept with that header. The fallback used to be
  # Capability::Unknown, which read the two octet optional parameter
  # header instead, left @code nil and raised TypeError, so a Dynamic
  # Capability message carrying an unimplemented code could not be read
  # at all.
  def test_dynamic_factory_keeps_an_unimplemented_capability
    s = '64000576616c7565'
    cap = Capability.dynamic_factory([s].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Unknown, cap)
    # Parsing cannot interpret the value, so the octets go back on the
    # wire byte for byte.
    assert_equal s, cap.to_shex
    assert_equal 'value', cap.value
    assert_equal({:code=>100, :value=>'76616c7565'}, cap.to_hash)
    assert_equal "Option Capabilities Advertisement (2): [#{s}]\n" +
                 '    Unknown Capability (100), 5 value octets: [76616c7565]',
                 cap.to_s
  end
  def test_dynamic_factory_keeps_an_unimplemented_capability_with_no_value
    cap = Capability.dynamic_factory(['640000'].pack('H*'))
    assert_instance_of(BGP::OPT_PARM::DYN_CAP::Unknown, cap)
    assert_equal '640000', cap.to_shex
    assert_equal({:code=>100}, cap.to_hash)
  end
  def test_dynamic_unknown_builds_three_ways
    s = '64000576616c7565'
    from_wire   = BGP::OPT_PARM::DYN_CAP::Unknown.new([s].pack('H*'))
    from_fields = BGP::OPT_PARM::DYN_CAP::Unknown.new(100, 'value')
    from_hash   = BGP::OPT_PARM::DYN_CAP::Unknown.new(:code=>100, :value=>'76616c7565')
    assert_equal s, from_wire.to_shex
    assert_equal s, from_fields.to_shex
    assert_equal s, from_hash.to_shex
    # to_hash round trips through new.
    assert_equal s, BGP::OPT_PARM::DYN_CAP::Unknown.new(from_wire.to_hash).to_shex
    assert_equal from_wire.to_hash, from_fields.to_hash
  end
  def test_cap_unknown_writes_the_optional_parameter_header
    # The same class under CAP writes the one octet length of RFC 5492
    # section 4, as every other capability does. The namespace picks the
    # header, nothing else changes.
    s = '0207640576616c7565'
    assert_equal s, CAP::Unknown.new(100, 'value').to_shex
    cap = CAP::Unknown.new([s].pack('H*'))
    assert_equal s, cap.to_shex
    assert_equal({:code=>100, :value=>'76616c7565'}, cap.to_hash)
    assert_equal s, CAP::Unknown.new(cap.to_hash).to_shex
  end
  def test_unknown_takes_any_code_and_any_value
    # Building is never validated: any code, any length, any octets.
    assert_equal '00000b' + ('ff' * 11),
                 BGP::OPT_PARM::DYN_CAP::Unknown.new(0, ['ff' * 11].pack('H*')).to_shex
    assert_equal 'ff0000', BGP::OPT_PARM::DYN_CAP::Unknown.new(255).to_shex
  end
  def test_unknown_refuses_a_code_it_cannot_hold
    # A code that is not an Integer cannot go in the field, and a String
    # that did not come off the wire is not a value either.
    assert_raise(ArgumentError) { CAP::Unknown.new('0207640576616c7565') }
    assert_raise(ArgumentError) { BGP::OPT_PARM::DYN_CAP::Unknown.new(:code) }
  end
end
