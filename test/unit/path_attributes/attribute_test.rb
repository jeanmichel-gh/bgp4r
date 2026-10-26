#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

require 'bgp4r'
require 'bgp/path_attributes/path_attribute'
require 'test/unit'

class ATTR_Test < Test::Unit::TestCase
  include BGP
  def test_1
    my_attr = Class.new(Attr)
    my_attr.class_eval do
      attr_reader :type, :flags, :value
      attr_writer :value
      def initialize(*args)
        if args.size>1
          @flags, @type,	@value = args
        else
          parse(*args)
        end
      end
      def parse(s)
        @flags, @type, _, @value = super
      end
      def encode
        super(value)
      end
    end
    assert_equal('40010101',my_attr.new(['40010101'].pack('H*')).to_shex)
    assert_equal('40010101',my_attr.new(BGP::ATTR::WELL_KNOWN_MANDATORY, 1, [1].pack('C')).to_shex)
    
    bogus_0 = my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 0, 'A BOGUS OPTIONAL TRANSITIVE ATTR WITH TYPE 0')
    bogus_999 = my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 999, 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 999')
    assert_equal bogus_0.to_shex, my_attr.new(bogus_0.encode).to_shex
    assert_equal bogus_999.to_shex, my_attr.new(bogus_999.encode).to_shex
    assert_equal 'A BOGUS OPTIONAL TRANSITIVE ATTR WITH TYPE 0', bogus_0.value
    assert_equal 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 999', bogus_999.value
  end
end
class Attr_factory_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = ['400101014003040a000001800404000000644005040000006440020c020500010002000300040005c0080c051f00010137003b0af50040'].pack('H*')
    assert_equal(Origin, BGP::Attr.factory(s).class)
    assert_equal(Next_hop, BGP::Attr.factory(s).class)
    assert_equal(Multi_exit_disc, BGP::Attr.factory(s).class)
    assert_equal(Local_pref, BGP::Attr.factory(s).class)
    assert_equal(As_path, BGP::Attr.factory(s).class)
    assert_equal(Communities, BGP::Attr.factory(s).class)
    assert_equal('',s)
  end

  # RFC 6793 section 3 and RFC 7311 section 3. These came back as
  # Attr::Unknown before the registry.
  def test_factory_as4_path_as4_aggregator_aigp
    { As4_path       => As4_path.new(As_path::Sequence.new(1,2)),
      As4_aggregator => As4_aggregator.new('1.1.1.1',100),
      Aigp           => Aigp.new(10),
    }.each do |klass, attr|
      wire = attr.encode
      parsed = Attr.factory(wire.dup)
      assert_equal(klass, parsed.class)
      assert_equal(wire, parsed.encode)
    end
    assert_equal('c0110a02020000000100000002', Attr.factory(['c0110a02020000000100000002'].pack('H*')).to_shex)
    assert_equal('c012080000006401010101', Attr.factory(['c012080000006401010101'].pack('H*')).to_shex)
    assert_equal('801a0b01000b000000000000000a', Attr.factory(['801a0b01000b000000000000000a'].pack('H*')).to_shex)
  end

  def test_factory_passes_as4byte_to_as_path
    wire = ['40020a02020000000100000002'].pack('H*')
    assert_equal('1 2', Attr.factory(wire.dup, true).as_path)
    assert_equal('1 2', Attr.factory(wire.dup, :as4byte=>true).as_path)
  end
end

class Attr_registry_Test < Test::Unit::TestCase
  include BGP

  def test_every_type_is_registered_once
    expected = {
      ATTR::ORIGIN => Origin, ATTR::AS_PATH => As_path, ATTR::NEXT_HOP => Next_hop,
      ATTR::MULTI_EXIT_DISC => Multi_exit_disc, ATTR::LOCAL_PREF => Local_pref,
      ATTR::ATOMIC_AGGREGATE => Atomic_aggregate, ATTR::AGGREGATOR => Aggregator,
      ATTR::COMMUNITIES => Communities, ATTR::ORIGINATOR_ID => Originator_id,
      ATTR::CLUSTER_LIST => Cluster_list, ATTR::MP_REACH => Mp_reach,
      ATTR::MP_UNREACH => Mp_unreach, ATTR::EXTENDED_COMMUNITY => Extended_communities,
      ATTR::AS4_PATH => As4_path, ATTR::AS4_AGGREGATOR => As4_aggregator,
      ATTR::ACCUMULATED_IGP_METRIC => Aigp,
    }
    expected.each { |type, klass| assert_equal(klass, Attr.by_type(type).klass, "type #{type}") }
    assert_equal(expected.size, Attr.registrations.size)
    assert_nil(Attr.by_type(99))
  end

  def test_keys_and_aliases
    { :next_hop=>Next_hop, :nexthop=>Next_hop, :med=>Multi_exit_disc,
      :multi_exit_disc=>Multi_exit_disc, :community=>Communities,
      :communities=>Communities, :extended_community=>Extended_communities,
      :extended_communities=>Extended_communities, :as4_path=>As4_path,
      :as4_aggregator=>As4_aggregator, :aigp=>Aigp,
    }.each { |key, klass| assert_equal(klass, Attr.by_key(key).klass, key.to_s) }
    assert_nil(Attr.by_key(:no_such_attr))
  end

  def test_session_option
    assert_equal(:as4byte, Attr.by_type(ATTR::AS_PATH).session)
    assert_equal(:path_id, Attr.by_type(ATTR::MP_REACH).session)
    assert_equal(:path_id, Attr.by_type(ATTR::MP_UNREACH).session)
    assert_nil(Attr.by_type(ATTR::AS4_PATH).session)
  end

  def test_type_cannot_be_taken_by_another_class
    assert_raise(ArgumentError) { Attr.register(ATTR::ORIGIN, Class.new(Attr), :other_origin) }
    assert_equal(Origin, Attr.by_type(ATTR::ORIGIN).klass)
    assert_nil(Attr.by_key(:other_origin))
  end
end

# Header overrides: write any flags, type or length, never checked.
class Attr_override_Test < Test::Unit::TestCase
  include BGP

  def test_origin
    assert_equal('40010100', Origin.new(:igp).to_shex)
    assert_equal('80010100', Origin.new(:igp, flags: ATTR::OPTIONAL).to_shex)
    assert_equal('40630100', Origin.new(:igp, type: 0x63).to_shex)
    assert_equal('40010300', Origin.new(:igp, length: 3).to_shex)
    assert_equal('80010300', Origin.new(:igp, flags: ATTR::OPTIONAL, length: 3).to_shex)
    # A long length override switches to a two octet length field.
    assert_equal('5001012c00', Origin.new(:igp, length: 300).to_shex)
    # Extended Length bit in the flags override: two octet length field.
    assert_equal('5001000100', Origin.new(:igp, flags: 0x5).to_shex)
    # Flags without the bit: a one octet field, even if the length is long.
    assert_equal('40012c00', Origin.new(:igp, flags: 0x4, length: 300).to_shex)
  end

  def test_next_hop
    assert_equal('4003040a000001', Next_hop.new('10.0.0.1').to_shex)
    assert_equal('c003040a000001', Next_hop.new('10.0.0.1', flags: 0xc).to_shex)
    assert_equal('4004040a000001', Next_hop.new('10.0.0.1', type: 4).to_shex)
    assert_equal('4003050a000001', Next_hop.new('10.0.0.1', length: 5).to_shex)
  end

  def test_as_path
    assert_equal('4002060202006400c8', As_path.new(100, 200).to_shex)
    assert_equal('500200060202006400c8', As_path.new(100, 200, flags: 0x5).to_shex)
    assert_equal('4011060202006400c8', As_path.new(100, 200, type: 17).to_shex)
    assert_equal('4002ff0202006400c8', As_path.new(100, 200, length: 255).to_shex)
    # The override holds for the 4 byte encoding too.
    assert_equal('5002000a020200000064000000c8', As_path.new(100, 200, flags: 0x5).encode4.unpack('H*')[0])
  end

  def test_communities
    assert_equal('c0080400010001', Communities.new('1:1').to_shex)
    assert_equal('40080400010001', Communities.new('1:1', flags: ATTR::WELL_KNOWN_MANDATORY).to_shex)
    assert_equal('c0200400010001', Communities.new('1:1', type: 32).to_shex)
    assert_equal('c0080300010001', Communities.new('1:1', length: 3).to_shex)
  end

  def test_mp_reach
    h = {:afi=>1, :safi=>1, :nexthop=>'10.0.0.1', :nlris=>'10.1.0.0/16'}
    assert_equal('800e0c000101040a00000100100a01', Mp_reach.new(h).to_shex)
    assert_equal('900e000c000101040a00000100100a01', Mp_reach.new(h, flags: 0x9).to_shex)
    assert_equal('80630c000101040a00000100100a01', Mp_reach.new(h, type: 0x63).to_shex)
    assert_equal('800e02000101040a00000100100a01', Mp_reach.new(h, length: 2).to_shex)
  end

  def test_override_setter
    o = Origin.new(:egp)
    assert_same(o, o.override(flags: 0xf, type: 0, length: 0))
    assert_equal('f000000001', o.to_shex)
    assert_equal({:flags=>0xf, :type=>0, :length=>0}, o.overrides)
    o.override(flags: nil, type: nil, length: nil)
    assert_equal('40010101', o.to_shex)
    assert_equal({}, o.overrides)
    assert_raise(ArgumentError) { o.override(colour: 1) }
  end

  def test_override_on_parsed_attr
    a = Attr.factory(['40010100'].pack('H*')).override(type: 2)
    assert_equal('40020100', a.to_shex)
  end

  def test_hash_forms_not_taken_as_options
    assert_equal('40010101', Origin.new(:origin=>1).to_shex)
    assert_equal('4003040a000001', Next_hop.new(:next_hop=>'10.0.0.1').to_shex)
  end

  def test_partial_known_attr
    # Communities is optional transitive: partial! sets the bit.
    assert_equal('e0080400010001', Communities.new('1:1').partial!.to_shex)
    # Origin is well known: partial! leaves it, override can still set it.
    assert_equal('40010100', Origin.new(:igp).partial!.to_shex)
    assert_equal('60010100', Origin.new(:igp, flags: 0x6).to_shex)
  end

end
