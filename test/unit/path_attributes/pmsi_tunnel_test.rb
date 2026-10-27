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

require "test/unit"
require "bgp4r"

class TestPmsiTunnel < Test::Unit::TestCase
  include BGP

  def wire(hex) [hex].pack('H*').is_packed end

  # RFC 6514 section 5: flags, tunnel type, 3 octet label, identifier.
  # Label 100 sits in the high 20 bits, so the field is 100 << 4.
  def test_ingress_replication
    a = Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100)
    assert_equal 'c0160900060006400a000001', a.to_shex
    assert_equal 6, a.tunnel_type
    assert_equal :ingress_replication, a.tunnel_name
    assert_equal 100, a.label
    assert ! a.leaf_info_required?
    assert a.is_optional?
    assert a.is_transitive?
  end

  def test_pim_ssm_and_leaf_info_required
    a = Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'], :leaf_info_required => true)
    assert_equal 'c0160d01030000000a000001e8010101', a.to_shex
    assert a.leaf_info_required?
    assert_nil a.label, 'a zero label field means no label'
    assert_match(/pim_ssm: 10\.0\.0\.1 -> 232\.1\.1\.1, leaf info required/, a.to_s(:brief))
  end

  def test_no_tunnel
    a = Pmsi_tunnel.new(:no_tunnel)
    assert_equal 'c016050000000000', a.to_shex
    assert_equal :no_tunnel, a.tunnel_name
    assert_equal '', a.identifier
  end

  def test_from_wire
    a = Pmsi_tunnel.new(wire('c0160900060006400a000001'))
    assert_equal [6, 100, '0a000001'], [a.tunnel_type, a.label, a.identifier.unpack1('H*')]
    assert_equal 'c0160900060006400a000001', a.to_shex
    assert_instance_of Pmsi_tunnel, Attr.factory(wire('c0160900060006400a000001'))
  end

  def test_hash_round_trip
    [Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 100),
     Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'], :leaf_info_required => true),
     Pmsi_tunnel.new(:no_tunnel),
     Pmsi_tunnel.new(9, '0102030405')].each do |a|
      h = a.to_hash
      assert_equal a.encode, Pmsi_tunnel.new(h[:pmsi_tunnel]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :pmsi_tunnel => h[:pmsi_tunnel])
      assert_equal a.encode, pa[:pmsi_tunnel].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    end
  end

  # A tunnel type bgp4r has no shape for keeps its octets.
  def test_unknown_tunnel_type
    a = Pmsi_tunnel.new(9, '0102030405')
    assert_equal 'c0160a000900000' + '00102030405', a.to_shex
    assert_nil a.tunnel_name
    assert_equal({:pmsi_tunnel => {:tunnel_type => 9, :identifier => '0102030405'}}, a.to_hash)
    assert_equal a.encode, Pmsi_tunnel.new(a.encode).encode
  end

  def test_bad_values_raise
    assert_raise(ArgumentError) { Pmsi_tunnel.new(:no_such_tunnel) }
    assert_raise(ArgumentError) { Pmsi_tunnel.new(:ingress_replication, '10.0.0.1', :label => 0x100000) }
    assert_raise(ArgumentError) { Pmsi_tunnel.new(300, '10.0.0.1') }
  end

  # Building never refuses a shape the RFC does not define.
  def test_any_identifier_can_be_built
    a = Pmsi_tunnel.new(:pim_ssm, '00')
    assert_equal 'c01606000300000000', a.to_shex
  end

  # RFC 6514 section 5: the fixed part is 5 octets.
  def test_too_short
    pa = Path_attribute.new(wire('c01604' + '00000000'))
    assert_equal [[22, 5, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal 'c0160400000000', pa.encode.unpack1('H*')
    assert_equal [], Path_attribute.new(wire('c016050000000000')).errors
  end

  # RFC 6514 section 5: a value too short to hold the fixed part is kept
  # as it came, and the hash carries it as a :tail key (Attr::TAIL_KEY)
  # inside the nested hash, so a to_hash round trip is byte for byte on a
  # malformed attribute too.
  def test_hash_round_trip_keeps_the_short_value
    ['', '00', '00000000'].each do |value_hex|
      hex = format('c016%02x', value_hex.length / 2) + value_hex
      a = Pmsi_tunnel.new(wire(hex))
      h = a.to_hash
      assert_equal hex, a.to_shex
      assert_equal value_hex, h[:pmsi_tunnel][:tail], h.inspect
      assert_equal a.encode, Pmsi_tunnel.new(h[:pmsi_tunnel]).encode, h.inspect
      pa = Path_attribute.new(:origin => :igp, :pmsi_tunnel => h[:pmsi_tunnel])
      assert_equal a.encode, pa[:pmsi_tunnel].encode
      assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    end
  end

  # An attribute with no kept octets hashes as it always has.
  def test_hash_has_no_tail_key_without_a_short_value
    assert_equal({:pmsi_tunnel => {:tunnel_type => :no_tunnel}}, Pmsi_tunnel.new(:no_tunnel).to_hash)
  end

  def test_flags_are_checked
    pa = Path_attribute.new(wire('80160900060006400a000001'))
    assert_equal [[22, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
  end

  def test_validate_is_clean_for_a_good_attribute
    assert_equal [], Path_attribute.new(Pmsi_tunnel.new(:ingress_replication, '10.0.0.1')).validate
  end

end
