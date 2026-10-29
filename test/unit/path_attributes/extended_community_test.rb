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

require 'bgp/path_attributes/extended_community'
# The new test checks the collection route as well as the community's own.
require 'bgp/path_attributes/extended_communities'
require 'test/unit'
require 'stringio'
class Extended_community_Test < Test::Unit::TestCase
  include BGP
  def test_community
    ec = Extended_community.new
    assert_equal('Extended community: 0:0', ec.to_s)
    assert_equal('0000000000000000',ec.to_shex)
    assert_equal('Extended community: 0:0', ec.to_s)
    assert_raise(ArgumentError) { Extended_community.new(0,2, '192.168.0.1',1) }
  end

  def test_to_i
    assert_equal("000200ff00deadbe",Route_target.new(0xff,0xdeadbe).to_shex)
    assert_equal(0x200ff00deadbe,Route_target.new(0xff,0xdeadbe).to_i)
    assert_equal('030a0a0000010064', Opaque.new(0,10,"0a0000010064").to_shex)
    assert_equal(0x030a0a0000010064, Opaque.new(0,10,"0a0000010064").to_i)
  end

  # RFC 4360 section 2: a community is 8 octets. An Integer holds those
  # octets as one number, so it round trips through to_i.
  def test_new_with_an_integer
    assert_equal('0000000000000064', Extended_community.new(100).to_shex)
    assert_equal(100, Extended_community.new(100).to_i)
    assert_equal(0x0002000a00000014, Extended_community.new(0x0002000a00000014).to_i)
    assert_equal('Extended community: 10:20', Extended_community.new(0x0002000a00000014).to_s)
    rt = Route_target.new(0xff,0xdeadbe)
    assert_equal(rt.to_i, Extended_community.new(rt.to_i).to_i)
  end

  # An Integer outside the 8 octets has no community to stand for. It used
  # to wrap into a valid looking one instead of being refused.
  def test_new_with_an_out_of_range_integer
    assert_equal('ffffffffffffffff', Extended_community.new(2**64 - 1).to_shex)
    assert_equal(2**64 - 1, Extended_community.new(2**64 - 1).to_i)
    e = assert_raise(ArgumentError) { Extended_community.new(2**64) }
    assert_match(/#{2**64}/, e.message)
    assert_match(/#{2**64 - 1}/, e.message)
    assert_raise(ArgumentError) { Extended_community.new(-1) }
  end

  # The other two Integer paths. They used to wrap silently while new
  # refused, so the same value gave a community through one door and an
  # error through another.
  def test_every_integer_path_refuses_an_out_of_range_value
    [->(n) { Extended_community.new(n) },
     ->(n) { Extended_community.factory(n) },
     ->(n) { Extended_community::Unknown.new(n) },
    ].each do |build|
      assert_raise(ArgumentError, "2**64 through #{build}")     { build.call(2**64) }
      assert_raise(ArgumentError, "-1 through #{build}")        { build.call(-1) }
      assert_equal 'ffffffffffffffff', build.call(2**64 - 1).to_shex, build.to_s
      assert_equal '0000000000000000', build.call(0).to_shex, build.to_s
    end
    assert_equal 0x000200ff00deadbe, Extended_community.factory(0x000200ff00deadbe).to_i
  end

  # The String form is the 8 octets as hex. Anything else used to be fed
  # to pack('H16'), which invents octets rather than complaining, so a
  # string that cannot be a community built a different one in silence.
  # There is no 'rt=1:1' notation here.
  def test_a_string_that_is_not_hex_is_refused
    { 'rt=1:1' => 'bdd1a10000000000',   # what it used to build
      'zzzz'   => '3333000000000000',
      '0002'   => '0002000000000000',   # short hex was zero padded
      '0002000100000001ff' => nil,      # and long hex truncated
    }.each_key do |s|
      e = assert_raise(ArgumentError, s.inspect) { Extended_community.factory(s) }
      assert_match(/16 hex digits/, e.message, s.inspect)
      assert_raise(ArgumentError, s.inspect) { Extended_community::Unknown.new(s) }
    end
  end

  def test_the_hex_string_form_still_builds
    assert_equal '0002000100000001', Extended_community.factory('0002000100000001').to_shex
    assert_equal '0002000100000001', Extended_community.factory('00 02 00 01 00 00 00 01').to_shex
    assert_equal 'ffffffffffffffff', Extended_community::Unknown.new('ffffffffffffffff').to_shex
  end

  # Refusing an unrepresentable Integer takes nothing away from negative
  # testing, which is what the conventions require of a constructor that
  # refuses anything: the octet form still builds a community no RFC
  # defines. The attribute level routes are covered in
  # extended_communities_test.rb and fault_test.rb.
  def test_octets_still_build_anything
    assert_equal 'ffff0000deadbeef', Extended_community.factory(['ffff0000deadbeef'].pack('H*')).to_shex
    assert_equal 'ffffffffffffffff', Extended_community::Unknown.new('ffffffffffffffff').to_shex
  end

  # RFC 4360 section 2: the low 2 bits of the type octet say which
  # structure the community has, so exactly one predicate is true.
  def test_structure_predicates
    two_octet = Route_target.new(10, 20)
    ipv4_addr = Route_target.new('1.1.1.1', 100)
    # RFC 5668 section 2: a 4 octet AS gives type 0x02.
    four_octet = Route_target.new(4200000001, 9)
    opaque = Opaque.new(0, 10, '0a0000010064')
    assert_equal('0002000a00000014', two_octet.to_shex)
    assert_equal('0102010101010064', ipv4_addr.to_shex)
    assert_equal('0202fa56ea010009', four_octet.to_shex)
    assert_equal('030a0a0000010064', opaque.to_shex)

    assert_equal([true, false, false], [two_octet.is_two_octet_asn?, two_octet.is_ipv4_addr?, two_octet.is_opaque?])
    assert_equal([false, true, false], [ipv4_addr.is_two_octet_asn?, ipv4_addr.is_ipv4_addr?, ipv4_addr.is_opaque?])
    # No predicate for the 4 octet AS structure, so all three are false.
    assert_equal([false, false, false], [four_octet.is_two_octet_asn?, four_octet.is_ipv4_addr?, four_octet.is_opaque?])
    assert_equal([false, false, true], [opaque.is_two_octet_asn?, opaque.is_ipv4_addr?, opaque.is_opaque?])

    # The transitive bit (0x40) does not change the structure.
    non_transitive = Opaque.new(ATTR::XTENDED_COMMUNITY::NON_TRANSITIVE, 10, '0a0000010064')
    assert_equal('430a0a0000010064', non_transitive.to_shex)
    assert_equal([false, false, true],
                 [non_transitive.is_two_octet_asn?, non_transitive.is_ipv4_addr?, non_transitive.is_opaque?])
  end

  # Any Integer type encodes, whether or not it means anything, because
  # negative testing needs it to. @type & 3 is one of the four
  # structures for every Integer, so the else branches of value and
  # _encoded_value_ never see one.
  def test_a_bogus_integer_type_still_encodes
    # Through the structured path: type 0xf0 becomes 0xf3, an opaque.
    ec = Opaque.new(0xf0, 0x99, '0a0000010064')
    assert_equal('f3990a0000010064', ec.to_shex)
    assert_equal('Opaque: 0a0000010064', ec.to_s)
    # Through the wire form: an unassigned type and subtype come back
    # byte for byte as an Unknown.
    wire = Extended_community.factory(['ff99000000000000'].pack('H*'))
    assert_equal(Extended_community::Unknown, wire.class)
    assert_equal('ff99000000000000', wire.to_shex)
  end

  # The one way past those else branches is a type that is not an
  # Integer. Opaque.new takes the type octet it is given, and true | 3
  # is true, which no structure matches. Both branches say so, rather
  # than showing an empty value or failing inside pack.
  def test_a_type_that_is_not_an_integer_says_so
    ec = Opaque.new(true, 0x0a, '0a0000010064')
    assert_match(/bogus type/, assert_raise(RuntimeError) { ec.to_s }.message)
    assert_match(/bogus type/, assert_raise(RuntimeError) { ec.encode }.message)
  end

  def test_compare
    rt = Route_target.new(0xff,0xdeadbe)
    op = Opaque.new(ATTR::XTENDED_COMMUNITY::NON_TRANSITIVE, 10,"0a0000010064")
    assert( rt < op )
  end

  def test_opaque
    ec = Opaque.new(ATTR::XTENDED_COMMUNITY::NON_TRANSITIVE, 10,"0a0000010064")
    ec.instance_of?(Extended_community)
    assert_equal('430a0a0000010064', ec.to_shex)
    assert_equal('Opaque: 0a0000010064', ec.to_s)
    # From its wire bytes too. parse used to keep the Array unpack returns,
    # so to_s showed it and encode raised TypeError.
    wire = Opaque.new(['030a0a0000010064'].pack('H*'))
    assert_equal('Opaque: 0a0000010064', wire.to_s)
    assert_equal('030a0a0000010064', wire.to_shex)
  end

  def test_route_target
    assert_raise(ArgumentError) { Route_target.new }
    assert_raise(ArgumentError) { Route_target.new('172.21.0.0') }
    assert_equal("0102010101010064",Route_target.new('1.1.1.1', 100).to_shex)
    assert_equal("Route target: 2.2.2.2:333",Route_target.new('2.2.2.2', 333).to_s)
    assert_equal("Route target: 10:20",Route_target.new(10, 20).to_s)
    assert_equal("000200ff00deadbe",Route_target.new(0xff,0xdeadbe).to_shex)
  end

  def test_route_origin
    assert_raise(ArgumentError) { Route_origin.new }
    assert_raise(ArgumentError) { Route_origin.new('172.21.0.0') }
    assert_equal("0103010101010064",Route_origin.new('1.1.1.1', 100).to_shex)
    assert_equal("Route origin: 2.2.2.2:333",Route_origin.new('2.2.2.2', 333).to_s)
    assert_equal("Route origin: 10:20",Route_origin.new(10, 20).to_s)
    assert_equal("000300ff00deadbe",Route_origin.new(0xff,0xdeadbe).to_shex)
    
  end

  def test_ospf_domain_id
    did = Ospf_domain_id.new('1.1.1.1')
    assert_equal('Ospf domain id: 1.1.1.1:0', did.to_s)
    assert_equal("0105010203040000",Ospf_domain_id.new('1.2.3.4').to_shex)
    assert_equal("Ospf domain id: 1.2.3.4:0", Ospf_domain_id.new(['0105010203040000'].pack('H*')).to_s)
  end

  def test_ospf_router_id
    rid = Ospf_router_id.new('1.1.1.1')
    assert_equal('Ospf router id: 1.1.1.1:0', rid.to_s)
    assert_equal("0107010203040000",Ospf_router_id.new('1.2.3.4').to_shex)
    assert_equal("Ospf router id: 1.2.3.4:0", Ospf_router_id.new(['0105010203040000'].pack('H*')).to_s)
  end

  def test_bgp_data_collect
    assert_equal("0008006400000064",Bgp_data_collect.new(100,100).to_shex)
    assert_equal("Bgp data collect: 100:100",Bgp_data_collect.new(100,100).to_s)
    assert_equal("Bgp data collect: 100:100", Bgp_data_collect.new(['0008006400000064'].pack('H*')).to_s)
  end
  
  # to_s names the AS as well as the bandwidth, the AS:value form of
  # every other 2 octet AS specific community. It used to print the
  # bandwidth alone, which said nothing about an AS the community
  # carried.
  def test_link_bandwidth
    assert_equal('40040000461c4000', Link_bandwidth.new(10_000).to_shex)
    assert_equal('Link bandwidth: 0:10000.0', Link_bandwidth.new(10_000).to_s)
    assert_equal('Link bandwidth: 0:10000.0', Link_bandwidth.new(['04040000461c4000'].pack('H*')).to_s)
    assert_equal('400400004cbebc20', Link_bandwidth.new(99_999_999).to_shex)
    assert_equal('Link bandwidth: 0:100000000.0', Link_bandwidth.new(99_999_999).to_s)
    assert_equal('Link bandwidth: 0:100000000.0', Link_bandwidth.new(['040400004cbebc20'].pack('H*')).to_s)
    assert_equal('Link bandwidth: 65000:10000.0', Link_bandwidth.new(65_000, 10_000).to_s)
  end

  # RFC 10005 section 2, on RFC 4360 section 3.1: the 2 octet
  # global administrator is the advertising speaker's AS. It used to be
  # filled with 0 and dropped when parsing, so 40040064447a0000 came back
  # as 40040000447a0000 and the AS could neither be set nor read back.
  # Bytes in, different bytes out, by every route into the class.
  def test_link_bandwidth_carries_the_global_administrator
    # AS 100, 1000 bytes per second. The octets used to be fresh each
    # time because parse sliced the String it was given; it reads them
    # where they lie now, and test_parse_leaves_the_callers_string_alone
    # holds it to that.
    wire = ->{ ['40040064447a0000'].pack('H*') }
    assert_equal('40040064447a0000', Link_bandwidth.new(wire.call).to_shex)
    assert_equal('40040064447a0000', Extended_community.new(wire.call).to_shex)
    assert_equal('40040064447a0000', Extended_community.factory(wire.call).to_shex)
    assert_equal('40040064447a0000', Extended_community.new(0x40040064447a0000).to_shex)
    # From field values, and read back.
    lb = Link_bandwidth.new(100, 1000)
    assert_equal('40040064447a0000', lb.to_shex)
    assert_equal('Link bandwidth: 100:1000.0', lb.to_s)
    assert_equal({:link_bandwidth=>[100, 1000.0]}, lb.to_hash)
    # From that hash.
    assert_equal('40040064447a0000', Link_bandwidth.new(*lb.to_hash[:link_bandwidth]).to_shex)
    # The one argument form leaves the AS at 0, as before.
    assert_equal('40040000447a0000', Link_bandwidth.new(1000).to_shex)
    assert_equal([0, 1000.0], Link_bandwidth.new(1000).to_hash[:link_bandwidth])
    # An AS above 65535 has no 2 octet form. pack would send a different
    # one in silence.
    err = assert_raise(ArgumentError) { Link_bandwidth.new(70_000, 1000) }
    assert_equal('invalid AS 70000, expected 0 to 65535', err.message)
    err = assert_raise(ArgumentError) { Link_bandwidth.new('1.1.1.1', 1000) }
    assert_equal('invalid AS "1.1.1.1", expected 0 to 65535', err.message)
    err = assert_raise(ArgumentError) { Link_bandwidth.new(100, 'x') }
    assert_equal('invalid bandwidth "x", expected a number', err.message)
  end

  # RFC 10005 section 2: the link bandwidth community takes the
  # 2 octet AS specific type, but its value is an IEEE 754 single
  # precision number. That is the FLOAT structure, so is_two_octet_asn?
  # is false and is_float? is true. The predicates used to read the low 2
  # bits of the type octet on their own and answer true to both.
  def test_link_bandwidth_structure_predicates
    lb = Link_bandwidth.new(10_000)
    assert_equal('40040000461c4000', lb.to_shex)
    assert_equal([false, false, false, true],
                 [lb.is_two_octet_asn?, lb.is_ipv4_addr?, lb.is_opaque?, lb.is_float?])
    # From its wire bytes, with the transitive bit set, the same answers.
    wire = Link_bandwidth.new(['04040000461c4000'].pack('H*'))
    assert_equal([false, false, false, true],
                 [wire.is_two_octet_asn?, wire.is_ipv4_addr?, wire.is_opaque?, wire.is_float?])
    # A 2 octet AS specific community that is not a link bandwidth keeps
    # the answers it had.
    rt = Route_target.new(10, 20)
    assert_equal([true, false], [rt.is_two_octet_asn?, rt.is_float?])
    assert_equal([false, false], [Opaque.new(0, 10, '0a0000010064').is_float?,
                                  Route_target.new('1.1.1.1', 100).is_float?])
  end

  # One argument is the bandwidth, two are the AS and the bandwidth. Any
  # other count used to report the argument list Link_bandwidth builds
  # for its parent, which named nothing the caller had written.
  def test_link_bandwidth_argument_count
    message = 'invalid link bandwidth %s, expected one argument, the bandwidth, ' +
              'or two, the AS and the bandwidth'
    err = assert_raise(ArgumentError) { Link_bandwidth.new(100, 1000, 2000) }
    assert_equal(format(message, '[100, 1000, 2000]'), err.message)
    err = assert_raise(ArgumentError) { Link_bandwidth.new }
    assert_equal(format(message, '[]'), err.message)
    # The one argument form and the wire form are untouched, and two
    # arguments are now the AS and the bandwidth.
    assert_equal('40040000461c4000', Link_bandwidth.new(10_000).to_shex)
    assert_equal('04040000461c4000', Link_bandwidth.new(['04040000461c4000'].pack('H*')).to_shex)
    assert_equal('40040064461c4000', Link_bandwidth.new(100, 10_000).to_shex)
    # An assignment hands both over as one Array.
    assert_equal('40040064461c4000', Link_bandwidth.new([100, 10_000]).to_shex)
  end

  def test_color
    assert_equal('030b000000000000', Color.new.to_shex)
    assert_equal('030b000000000000', Color.new(0).to_shex)
    assert_equal('030b000000000064', Color.new(100).to_shex)
    assert_equal('Color: 100', Color.new(100).to_s)
    assert_equal('Color: 10000', Color.new(Color.new(10_000).encode).to_s)
    # RFC 9012 section 4.3: the color value is 4 octets.
    assert_equal('030b0000000186a0', Color.new(100_000).to_shex)
    assert_equal('Color: 100000', Color.new(Color.new(100_000).encode).to_s)
    assert_equal('Color: 4294967295', Extended_community.factory(0x030b0000ffffffff).to_s)
  end

  def test_origin_validation_state
    assert_equal(:valid, Origin_validation_state.new(0).validation_state)
    assert_equal(:not_found, Origin_validation_state.new(1).validation_state)
    assert_equal(:invalid, Origin_validation_state.new(2).validation_state)
    assert_equal(:valid, Origin_validation_state.new(:valid).validation_state)
    assert_equal(:not_found, Origin_validation_state.new(:not_found).validation_state)
    assert_equal(:invalid, Origin_validation_state.new(:invalid).validation_state)
    assert_equal('4300000000000000', Origin_validation_state.new(:valid).to_shex)
    assert_equal('4300000000000001', Origin_validation_state.new(:not_found).to_shex)
    assert_equal('4300000000000002', Origin_validation_state.new(:invalid).to_shex)
  end

  # RFC 8097 section 2 defines states 0, 1 and 2 only.
  def test_origin_validation_state_bogus_value
    e = assert_raise(RuntimeError) { Origin_validation_state.new(3).validation_state }
    assert_match(/3/, e.message)
  end
  
  # def test_encapsulation
  #   assert_equal('030c000000000000', Encapsulation.new.to_shex)
  #   assert_equal('030c000000000001', Encapsulation.new(1).to_shex)
  #   assert_equal('030c000000000002', Encapsulation.new(2).to_shex)
  #   assert_equal('030c000000000007', Encapsulation.new(7).to_shex)
  #   assert_equal('030c000000000001', Encapsulation.new(:l2tpv3).to_shex)
  #   assert_equal('030c000000000002', Encapsulation.new(:gre).to_shex)
  #   assert_equal('030c000000000007', Encapsulation.new(:ipip).to_shex)
  #   assert_equal('Encapsulation: 1', Encapsulation.new(:l2tpv3).to_s)
  #   assert_equal('Encapsulation: 7', Encapsulation.new(:ipip).to_s)
  #   assert_equal('Encapsulation: 2', Encapsulation.new(:gre).to_s)
  #   assert_equal('Encapsulation: 7', Encapsulation.new(Encapsulation.new(7).encode).to_s)    
  # end

  def test_factory
    s = '0102070001010008 010208000101000a 01020a000102000a 01020a0003020007 01020b000101000a 
         01030a0003020009 0105090100010000 0105140000010000 01070a0000010000 400400004e6e6b28 
         430b000000000064 4300000000000001'.split.join # 030c000000000007
    comms = []
    s.scan(/[0-9a-f]{16}/) { |comm| comms << Extended_community.factory([comm].pack('H*'))  }
    assert_equal BGP::Route_target, comms[0].class
    assert_equal BGP::Route_target, comms[1].class
    assert_equal BGP::Route_target, comms[2].class
    assert_equal BGP::Route_target, comms[3].class
    assert_equal BGP::Route_target, comms[4].class
    assert_equal BGP::Route_origin, comms[5].class
    assert_equal BGP::Ospf_domain_id, comms[6].class
    assert_equal BGP::Ospf_domain_id, comms[7].class
    assert_equal BGP::Ospf_router_id, comms[8].class
    assert_equal BGP::Link_bandwidth, comms[9].class
    assert_equal BGP::Color, comms[10].class
    assert_equal BGP::Origin_validation_state, comms[11].class
    # assert_equal BGP::Encapsulation, comms[11].class
  end

  def test_factory_unknown_subtype_is_kept_quietly
    out, $stdout = $stdout, StringIO.new
    ec = Extended_community.factory(['0099000000000000'].pack('H*'))
    assert_equal(Extended_community::Unknown, ec.class)
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end

  # RFC 4360 sections 2 and 4, RFC 7606 section 7.14: unknown types and
  # subtypes are kept and sent back byte for byte.
  def test_unknown_round_trip
    %w{
      0306000000000000
      0377000000000007
      8077000000000000
      8002000000000000
      0677000000000064
      0099000000000000
    }.each do |hex|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(Extended_community::Unknown, ec.class, hex)
      assert_equal(hex, ec.to_shex)
      assert_equal(hex.to_i(16), ec.to_i)
      assert_equal({:unknown=>hex}, ec.to_hash)
      assert_equal(hex, Extended_community::Unknown.new(ec.to_hash[:unknown]).to_shex)
      assert_equal(hex, Extended_community.factory(hex.to_i(16)).to_shex)
    end
  end

  def test_unknown_to_s
    # 0x8006 and 0x030c, used here before, are decoded now (Traffic_rate_bytes
    # and Encapsulation). These two are still unassigned.
    ec = Extended_community.factory(['8077000000000000'].pack('H*'))
    assert_equal('Unknown extended community: type 0x80, subtype 0x77, 8077000000000000', ec.to_s)
    ec = Extended_community.factory(['0377000000000007'].pack('H*'))
    assert_equal('Unknown extended community: type 0x03, subtype 0x77, 0377000000000007', ec.to_s)
  end

  # RFC 4360 section 2: dispatch on type and subtype, not subtype alone.
  def test_factory_uses_type_and_subtype
    # Subtype 0x02 under the IANA authority type 0x80 is not a route target.
    assert_equal(Extended_community::Unknown, Extended_community.factory(0x8002000000000000).class)
    # Subtype 0x0b under type 0x00 is not a color.
    assert_equal(Extended_community::Unknown, Extended_community.factory(0x000b000000000064).class)
    # The transitive bit is masked.
    assert_equal(Route_target, Extended_community.factory(0x4002000a00000014).class)
  end

  # RFC 5668 section 2: 4 octet AS specific, 4 octet global, 2 octet local.
  def test_four_octet_as_route_target
    rt = Route_target.new(4200000000, 1)
    assert_equal('0202fa56ea000001', rt.to_shex)
    assert_equal('Route target: 4200000000:1', rt.to_s)
    ec = Extended_community.factory(['0202fa56ea000001'].pack('H*'))
    assert_equal(Route_target, ec.class)
    assert_equal('Route target: 4200000000:1', ec.to_s)
    assert_equal('0202fa56ea000001', ec.to_shex)
    assert_equal({:route_target=>[4200000000, 1]}, ec.to_hash)
    assert_equal('Route target: 65538:3', Extended_community.factory(0x0202000100020003).to_s)
    assert_equal('0202000100020003', Extended_community.factory(0x0202000100020003).to_shex)
    assert_raise(ArgumentError) { Route_target.new(4200000000, 0x10000) }
  end

  def test_four_octet_as_route_origin
    ro = Route_origin.new(4200000000, 1)
    assert_equal('0203fa56ea000001', ro.to_shex)
    assert_equal('Route origin: 4200000000:1', ro.to_s)
    ec = Extended_community.factory(['0203000100020003'].pack('H*'))
    assert_equal(Route_origin, ec.class)
    assert_equal('Route origin: 65538:3', ec.to_s)
    assert_equal('0203000100020003', ec.to_shex)
  end

  # RFC 4360 section 2: the type octet is the first of the eight, and it
  # says things no value can say. A build from values hard codes it, so
  # the hash form carries it whenever the values alone would give a
  # different one. Two octets that get lost without it:
  #
  # The T bit of RFC 4360 section 2, the second bit of the high order
  # octet, which a community keeps whatever its value is. A route target
  # is transitive (section 4), so Route_target.new always clears it; an
  # origin validation state is non-transitive (RFC 8097 section 2, type
  # 0x43), so Origin_validation_state.new always sets it. A community
  # that arrives the other way round has nowhere to keep that bit.
  #
  # And the structure bits, the low two of the same octet, which a build
  # from values picks from the values: RFC 5668 section 2 gives the
  # 4 octet AS specific community the type octet 0x02, or 0x42 when it
  # is non-transitive, and its global administrator is 4 octets where
  # the 2 octet AS specific form of RFC 4360 section 2 has 2. An AS
  # below 65536 fits either form, so the pair [100, 1] cannot say which
  # one it came from.
  def test_to_hash_carries_a_type_octet_the_values_cannot_reproduce
    [['0202000000640001', {:route_target=>[100, 1], :type=>0x02}],
     ['4202000000640001', {:route_target=>[100, 1], :type=>0x42}],
     ['0203000000640001', {:route_origin=>[100, 1], :type=>0x02}],
     ['4203000000640001', {:route_origin=>[100, 1], :type=>0x42}],
     ['0300000000000001', {:origin_validation_state=>1, :type=>0x03}],
     ['4002000100000001', {:route_target=>[1, 1], :type=>0x40}],
     ['4102010101010064', {:route_target=>['1.1.1.1', 100], :type=>0x41}],
     ['4003000100000001', {:route_origin=>[1, 1], :type=>0x40}],
     ['00040064447a0000', {:link_bandwidth=>[100, 1000.0], :type=>0x00}],
     ['4105010203040000', {:ospf_domain_id=>'1.2.3.4', :type=>0x41}],
     ['4008006400000064', {:bgp_data_collect=>[100, 100], :type=>0x40}],
     ['430b000000000064', {:color=>100, :type=>0x43}],
     ['430c000000000008', {:encapsulation=>:vxlan, :type=>0x43}],
     ['c007000000000003', {:traffic_action=>{:sample=>true, :terminal=>true}, :type=>0xc0}],
     ['4600000000000005', {:mac_mobility=>[5, false], :type=>0x46}],
     ['4602aabbccddeeff', {:es_import=>'aa:bb:cc:dd:ee:ff', :type=>0x46}],
    ].each do |hex, hash|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(hash, ec.to_hash, hex)
      # The wire form is untouched, and so is the type reader.
      assert_equal(hex, ec.to_shex, hex)
      assert_equal(hash[:type], ec.type, hex)
    end
  end

  # And where the values do reproduce the type octet, the hash is the
  # plain one key hash it has always been. That is what callers write by
  # hand, so nothing here may gain a key: every structure of RFC 4360
  # section 2, the FLOAT one of RFC 10005, the
  # 4 octet AS specific form with an AS that needs 4 octets, and every
  # community whose type octet its own constructor already sets.
  def test_to_hash_keeps_the_plain_form_where_the_values_reproduce_the_type
    [['0002000100000001', {:route_target=>[1, 1]}],
     ['0102010101010064', {:route_target=>['1.1.1.1', 100]}],
     ['0202fa56ea010001', {:route_target=>[4200000001, 1]}],
     ['0003000100000001', {:route_origin=>[1, 1]}],
     ['0103010101010064', {:route_origin=>['1.1.1.1', 100]}],
     ['0203fa56ea010001', {:route_origin=>[4200000001, 1]}],
     ['40040064447a0000', {:link_bandwidth=>[100, 1000.0]}],
     ['0105010203040000', {:ospf_domain_id=>'1.2.3.4'}],
     ['0107010203040000', {:ospf_router_id=>'1.2.3.4'}],
     ['0008006400000064', {:bgp_data_collect=>[100, 100]}],
     ['030b000000000064', {:color=>100}],
     ['4300000000000001', {:origin_validation_state=>1}],
     ['030c000000000008', {:encapsulation=>:vxlan}],
     ['8006000a447a0000', {:traffic_rate_bytes=>[10, 1000.0]}],
     ['800c000a447a0000', {:traffic_rate_packets=>[10, 1000.0]}],
     ['8007000000000003', {:traffic_action=>{:sample=>true, :terminal=>true}}],
     ['8008000a00000064', {:redirect=>[10, 100]}],
     ['8108010101010064', {:redirect=>['1.1.1.1', 100]}],
     ['8208000100020003', {:redirect=>[65538, 3]}],
     ['8009000000000020', {:traffic_marking=>32}],
     ['0600000000000005', {:mac_mobility=>[5, false]}],
     ['0601000000000640', {:esi_label=>[100, false]}],
     ['0602aabbccddeeff', {:es_import=>'aa:bb:cc:dd:ee:ff'}],
     ['0603aabbccddeeff', {:router_mac=>'aa:bb:cc:dd:ee:ff'}],
     ['ffff000000000000', {:unknown=>'ffff000000000000'}],
    ].each do |hex, hash|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(hash, ec.to_hash, hex)
      assert_equal(hex, ec.to_shex, hex)
    end
  end

  # RFC 4577 section 4.2.6: the OSPF domain ID carries the Domain
  # Identifier in the six octet value field, and its type "is 0005, 0105,
  # or 0205". Those three type octets give that field the three
  # structures of RFC 4360 section 3.1, RFC 4360 section 3.2 and RFC 5668
  # section 2: a 2 octet administrator and a 4 octet one, a 4 octet
  # address and a 2 octet one, or a 4 octet AS and a 2 octet one.
  #
  # value2 read the first field as an address and dropped the second,
  # which is the 0105 form alone, so under 0005 both fields were lost:
  # 0005000100000001 hashed as '0.0.0.1' and came back as
  # 0005000100000000. RFC 4577 does not say the low 2 octets of the 0105
  # form are zero either, and section 4.2.8.1 reads the whole six as the
  # identifier, so a 0105 form that arrives with them set lost them too:
  # 0105010203040009 came back as 0105010203040000.
  #
  # The hash carries both fields, except where the second is 0 and the
  # structure is the IPv4 address specific one, which is every domain ID
  # bgp4r builds. There the hash is the plain address it has always been,
  # pinned above.
  def test_the_hash_of_an_ospf_id_keeps_every_octet_of_its_value
    [[Ospf_domain_id, '0005000100000001', {:ospf_domain_id=>[1, 1], :type=>0x00}],
     [Ospf_domain_id, '4005000100000001', {:ospf_domain_id=>[1, 1], :type=>0x40}],
     [Ospf_domain_id, '0205000100020003', {:ospf_domain_id=>[65538, 3], :type=>0x02}],
     [Ospf_domain_id, '0105010203040009', {:ospf_domain_id=>['1.2.3.4', 9]}],
     [Ospf_domain_id, '0105010203040000', {:ospf_domain_id=>'1.2.3.4'}],
     # Only 0107 is in Extended_community::FACTORY for the router ID,
     # since RFC 4577 section 4.2.6 gives it that type alone, but the
     # class takes any octets handed to it and hashes them the same way.
     [Ospf_router_id, '0007000100000001', {:ospf_router_id=>[1, 1], :type=>0x00}],
     [Ospf_router_id, '0107010203040009', {:ospf_router_id=>['1.2.3.4', 9]}],
     [Ospf_router_id, '0107010203040000', {:ospf_router_id=>'1.2.3.4'}],
    ].each do |klass, hex, hash|
      ec = klass.new([hex].pack('H*'))
      assert_equal(hash, ec.to_hash, hex)
      assert_equal(hex, ec.to_shex, hex)
      # The build path Extended_communities.communities_from_hash walks:
      # the value builds the community, then the type octet is written
      # over the one the value gave. That class is not loaded here, so
      # the two steps are taken by hand.
      value = hash.reject { |k,_| k == :type }.values.first
      rebuilt = klass.new(*Array(value))
      rebuilt.type = hash[:type] if hash.has_key?(:type)
      assert_equal(hex, rebuilt.to_shex, hex)
    end
  end

  # RFC 4577 section 4.2.6 names 0205 beside 0005 and 0105, so the
  # factory knows all three. Its structure is the 4 octet AS specific
  # one of RFC 5668 section 2, which parse and encode already read and
  # write, so the class needed nothing of its own.
  def test_the_factory_knows_all_three_ospf_domain_id_types
    ['0005000100000001', '0105010203040000', '0205000100020003'].each do |hex|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(Ospf_domain_id, ec.class, hex)
      assert_equal(hex, ec.to_shex, hex)
    end
    assert_equal('Ospf domain id: 65538:3',
                 Extended_community.factory(['0205000100020003'].pack('H*')).to_s)
  end

  # The domain ID takes both administrator fields, so the hash value it
  # carries builds back. One argument is the domain ID alone, the form
  # bgp4r has always built, and its local administrator is 0.
  def test_an_ospf_id_builds_from_one_field_or_two
    assert_equal('0105010203040000', Ospf_domain_id.new('1.2.3.4').to_shex)
    assert_equal('0105010203040009', Ospf_domain_id.new('1.2.3.4', 9).to_shex)
    assert_equal('0107010203040000', Ospf_router_id.new('1.2.3.4').to_shex)
    assert_equal('0107010203040009', Ospf_router_id.new('1.2.3.4', 9).to_shex)
    # An Integer first field keeps the type octet the constructor passes,
    # as it always did, and the 4 octet field it names.
    assert_equal('0105000000010000', Ospf_domain_id.new(1).to_shex)
    assert_equal('0105000000010001', Ospf_domain_id.new(1, 1).to_shex)
    # No argument is the all zero domain ID of RFC 4577 section 4.2.6,
    # the NULL one, which is what it built before.
    assert_equal('0105000000000000', Ospf_domain_id.new.to_shex)
    assert_raise(ArgumentError) { Ospf_domain_id.new(1, 2, 3) }
    assert_raise(ArgumentError) { Ospf_router_id.new(1, 2, 3) }
  end

  # The type octet is set from the hash form after the values have built
  # the community, so the writer has to be there and has to check
  # nothing: an octet no RFC asks for is one of the things this library
  # exists to put on the wire.
  def test_the_type_octet_can_be_written
    rt = Route_target.new(100, 1)
    assert_equal('0002006400000001', rt.to_shex)
    rt.type = 0x02
    assert_equal('0202000000640001', rt.to_shex)
    assert_equal(0x02, rt.type)
    # Nothing is checked. 0x82 sets the IANA authority bit of RFC 4360
    # section 2 on a route target, which no registry has.
    rt.type = 0x82
    assert_equal('8202000000640001', rt.to_shex)
  end


  # New sub-types: hex, factory, round trip.
  def check_sub_type(klass, hex, text)
    ec = Extended_community.factory([hex].pack('H*'))
    assert_equal(klass, ec.class, hex)
    assert_equal(hex, ec.to_shex, hex)
    assert_equal(text, ec.to_s, hex)
  end

  # RFC 9012 section 4.1
  def test_encapsulation
    assert_equal('030c000000000008', Encapsulation.new(:vxlan).to_shex)
    assert_equal('030c000000000002', Encapsulation.new(2).to_shex)
    assert_equal(:vxlan, Encapsulation.new(:vxlan).tunnel_name)
    assert_equal({:encapsulation=>:vxlan}, Encapsulation.new(8).to_hash)
    assert_equal({:encapsulation=>13}, Encapsulation.new(13).to_hash)
    check_sub_type(Encapsulation, '030c000000000009', 'Encapsulation: nvgre')
    check_sub_type(Encapsulation, '430c00000000000b', 'Encapsulation: mpls_in_gre')
    assert_raise(ArgumentError) { Encapsulation.new(:carrier_pigeon) }
    assert_raise(ArgumentError) { Encapsulation.new(65536) }
  end

  # RFC 8955 sections 7.1 and 7.2
  def test_traffic_rate
    assert_equal('80060000447a0000', Traffic_rate_bytes.new(0, 1000).to_shex)
    assert_equal('800cfde941280000', Traffic_rate_packets.new(65001, 10.5).to_shex)
    assert_equal({:traffic_rate_bytes=>[0, 0.0]}, Traffic_rate_bytes.new(0, 0).to_hash)
    check_sub_type(Traffic_rate_bytes, '8006000000000000', 'Traffic rate bytes: 0.0 (ID 0)')
    check_sub_type(Traffic_rate_packets, '800c0001447a0000', 'Traffic rate packets: 1000.0 (ID 1)')
    assert_raise(ArgumentError) { Traffic_rate_bytes.new(65536, 1) }
    assert_raise(ArgumentError) { Traffic_rate_bytes.new(0, 'fast') }
  end

  # RFC 8955 section 7.3: S is 0x02, T is 0x01 in the last octet.
  def test_traffic_action
    assert_equal('8007000000000002', Traffic_action.new(sample: true).to_shex)
    assert_equal('8007000000000001', Traffic_action.new(terminal: true).to_shex)
    assert_equal('8007000000000000', Traffic_action.new.to_shex)
    a = Traffic_action.new(['8007000000000003'].pack('H*').is_packed)
    assert(a.sample? && a.terminal?)
    assert_equal({:traffic_action=>{:sample=>true, :terminal=>true}}, a.to_hash)
    # Reserved bits round trip, and show up so a test can see them.
    check_sub_type(Traffic_action, '8007800000000001', 'Traffic action: terminal, bits 0x800000000001')
    assert_equal('8007800000000001', Traffic_action.new(Traffic_action.new(bits: 0x800000000001).to_hash[:traffic_action]).to_shex)
    assert_raise(ArgumentError) { Traffic_action.new(:drop) }
  end

  # RFC 8955 section 7.4: the three route target formats.
  def test_redirect
    assert_equal('8008fde900000064', Redirect.new(65001, 100).to_shex)
    assert_equal('81080a0000010007', Redirect.new('10.0.0.1', 7).to_shex)
    assert_equal('8208fa56ea010009', Redirect.new(4200000001, 9).to_shex)
    check_sub_type(Redirect, '8008fde900000064', 'Redirect: 65001:100')
    check_sub_type(Redirect, '81080a0000010007', 'Redirect: 10.0.0.1:7')
    check_sub_type(Redirect, '8208fa56ea010009', 'Redirect: 4200000001:9')
    assert_equal({:redirect=>['10.0.0.1', 7]}, Redirect.new('10.0.0.1', 7).to_hash)
    assert_raise(ArgumentError) { Redirect.new(4200000001, 65536) }
  end

  # RFC 8955 section 7.5: DSCP in the 6 low bits of the last octet.
  def test_traffic_marking
    assert_equal('800900000000002e', Traffic_marking.new(46).to_shex)
    check_sub_type(Traffic_marking, '800900000000002e', 'Traffic marking: DSCP 46')
    # Reserved bits are ignored on decode and kept on the wire. RFC 8955
    # section 7.5 asks for both: they "MUST be set to 0 on encoding and
    # MUST be ignored during decoding". to_s names them now, so what
    # encode would write is visible; it used to print the DSCP alone,
    # which read as though the two forms were the same community.
    check_sub_type(Traffic_marking, '80090000000000ee',
                   'Traffic marking: DSCP 46, bits 0x0000000000ee')
    assert_raise(ArgumentError) { Traffic_marking.new(64) }
  end

  # RFC 7432 section 7.7
  def test_mac_mobility
    assert_equal('0600000000000005', Mac_mobility.new(5).to_shex)
    assert_equal('0600010000000005', Mac_mobility.new(5, sticky: true).to_shex)
    check_sub_type(Mac_mobility, '0600010000000005', 'MAC Mobility: sequence 5, sticky')
    assert_equal({:mac_mobility=>[5, true]}, Mac_mobility.new(5, sticky: true).to_hash)
  end

  # RFC 7432 section 7.5: the MPLS label is the high 20 bits of 3 octets.
  def test_esi_label
    assert_equal('0601000000003e80', Esi_label.new(1000).to_shex)
    assert_equal('0601010000003e80', Esi_label.new(1000, single_active: true).to_shex)
    check_sub_type(Esi_label, '0601010000003e80', 'ESI Label: label 1000, single-active')
    assert_raise(ArgumentError) { Esi_label.new(0x100000) }
  end

  # The reserved fields of these four. encode always kept them, because a
  # Typed community parsed from the wire keeps its 6 value octets, but
  # hash_value carried only the fields each RFC defines, so a build from
  # the hash wrote them as 0 and the community came back different. They
  # carry a :bits entry now, all 48 bits of the value, which is what
  # Traffic_action has always done with the 46 above its own two.
  #
  # Which bits are reserved, each read in its RFC: RFC 9012 section 4.1
  # gives Encapsulation 4 reserved octets and a 2 octet tunnel type; RFC
  # 8955 section 7.5 puts the DSCP in "the 6 least significant bits of the
  # Extended Community value"; RFC 7432 section 7.7 gives MAC Mobility a
  # Flags octet whose "low-order bit ... is defined as the "Sticky/static"
  # flag", one reserved octet and a 4 octet sequence number; RFC 7432
  # section 7.5 gives ESI Label a Flags octet whose low-order bit is
  # Single-Active, two reserved octets and a 3 octet label field.
  def test_a_typed_community_keeps_its_reserved_bits_through_its_hash
    [['030cffffffff0008', Encapsulation,
      { :encapsulation=> { :tunnel_type=> :vxlan, :bits=> 0xffffffff0008 } },
      'Encapsulation: vxlan, bits 0xffffffff0008'],
     ['8009ffffffffffe0', Traffic_marking,
      { :traffic_marking=> { :dscp=> 32, :bits=> 0xffffffffffe0 } },
      'Traffic marking: DSCP 32, bits 0xffffffffffe0'],
     ['0600ffff00000005', Mac_mobility,
      { :mac_mobility=> { :sequence=> 5, :sticky=> true, :bits=> 0xffff00000005 } },
      'MAC Mobility: sequence 5, sticky, bits 0xffff00000005'],
     ['0601ffffff00064f', Esi_label,
      { :esi_label=> { :label=> 100, :single_active=> true, :bits=> 0xffffff00064f } },
      'ESI Label: label 100, single-active, bits 0xffffff00064f'],
     # The class the other four take the shape from.
     ['8007ffffffffffff', Traffic_action,
      { :traffic_action=> { :sample=> true, :terminal=> true, :bits=> 0xffffffffffff } },
      'Traffic action: sample, terminal, bits 0xffffffffffff'],
    ].each do |hex, klass, hash, text|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(klass, ec.class, hex)
      assert_equal(hash, ec.to_hash, hex)
      assert_equal(text, ec.to_s, hex)
      # The hash it gives back builds the same octets, which is what
      # to_hash owes. Through the list of communities is the other half of
      # this, and it is in extended_communities_test.rb, where the sweep
      # over every wire form the factory knows sets all of these bits.
      value = ec.to_hash.values.first
      assert_equal(hex, klass.new(**value).to_shex, hex)
      assert_equal(hex, klass.new(value).to_shex, hex)
      # And the bits on their own are enough, since the named fields are
      # read back out of them.
      assert_equal(hex, klass.new(:bits=> value[:bits]).to_shex, hex)
    end
  end

  # With the reserved bits clear, which is what every one of these RFCs
  # asks an encoder for, the hash is the plain shape it has always been:
  # no :bits entry, and no Hash where there was a value or a list.
  def test_a_typed_community_with_no_reserved_bits_hashes_as_it_always_did
    { '030c000000000008' => { :encapsulation=> :vxlan },
      '8009000000000020' => { :traffic_marking=> 32 },
      '0600010000000005' => { :mac_mobility=> [5, true] },
      '0601010000000640' => { :esi_label=> [100, true] },
      '8007000000000003' => { :traffic_action=> { :sample=> true, :terminal=> true } },
    }.each do |hex, hash|
      ec = Extended_community.factory([hex].pack('H*'))
      assert_equal(hash, ec.to_hash, hex)
    end
    # And a build from values writes the reserved fields as 0, as the RFCs
    # ask, so nothing here changes what bgp4r sends of its own accord.
    assert_equal('030c000000000008', Encapsulation.new(:vxlan).to_shex)
    assert_equal('8009000000000020', Traffic_marking.new(32).to_shex)
    assert_equal('0600010000000005', Mac_mobility.new(5, sticky: true).to_shex)
    assert_equal('0601010000000640', Esi_label.new(100, single_active: true).to_shex)
  end

  # 48 bits is the whole value field. More than that cannot be represented
  # at all, so it is refused rather than written as its low 6 octets.
  def test_a_bits_value_wider_than_the_value_field_is_refused
    # Every one of the 48 fits.
    assert_equal('0601ffffffffffff', Esi_label.new(:bits=> 0xffffffffffff).to_shex)
    [Encapsulation, Traffic_marking, Mac_mobility, Esi_label, Traffic_action].each do |klass|
      e = assert_raise(ArgumentError, klass.to_s) { klass.new(:bits=> 0x1000000000000) }
      assert_match(/bits/, e.message)
    end
  end

  # RFC 7432 section 7.6 and RFC 9135 section 8.1
  def test_mac_address_communities
    assert_equal('0602001122334455', Es_import.new('00:11:22:33:44:55').to_shex)
    assert_equal('0603aabbccddeeff', Router_mac.new('AA-BB-CC-DD-EE-FF').to_shex)
    check_sub_type(Es_import, '0602001122334455', 'ES-Import: 00:11:22:33:44:55')
    check_sub_type(Router_mac, '0603aabbccddeeff', "Router's MAC: aa:bb:cc:dd:ee:ff")
    assert_equal({:router_mac=>'aa:bb:cc:dd:ee:ff'}, Router_mac.new('aabbccddeeff').to_hash)
    assert_raise(ArgumentError) { Router_mac.new('aa:bb:cc') }
  end

  # The transitive bit is masked when dispatching (RFC 4360 section 2).
  def test_non_transitive_variants_keep_their_type
    check_sub_type(Mac_mobility, '4600000000000005', 'MAC Mobility: sequence 5')
  end

  # RFC 4360 section 2: the 8 octets are a type, a sub-type and 6 value
  # octets, and parse reads them where they lie. It used to start with
  # s.slice!(0,2), so the caller's String came back 2 octets shorter: the
  # same wire bytes built a community once and raised TypeError from
  # pack on every build after that. Wire bytes are one of the three build
  # paths every class owes, so build from one String twice and check the
  # String afterwards.
  def test_parse_leaves_the_callers_string_alone
    [[Extended_community, '0002000100000001'], # 2 octet AS specific
     [Route_target,       '0002000100000001'],
     [Route_target,       '0102010101010064'], # IPv4 address specific
     [Route_target,       '0202000000640001'], # 4 octet AS specific, RFC 5668
     [Route_origin,       '0003000100000001'],
     [Route_origin,       '0103010101010064'],
     [Route_origin,       '0203000000640001'],
     [Opaque,             '030a0a0000010064'],
     [Color,              '030b000000000064'],
     [Origin_validation_state, '03000000000000ff'],
     [Link_bandwidth,     '40040064447a0000'], # the FLOAT structure
     [Bgp_data_collect,   '0008006400000064'],
     [Ospf_domain_id,     '0105010203040000'],
     [Ospf_router_id,     '0107010203040000'],
     [Extended_community::Unknown, 'ffff000000000000'],
     [Encapsulation,      '030c000000000008'], # Typed, byteslices already
    ].each do |klass, hex|
      wire = [hex].pack('H*')
      first = klass.new(wire)
      assert_equal(hex, first.to_shex, hex)
      # The defect itself: the String the caller still holds.
      assert_equal(hex, wire.unpack1('H*'), hex)
      assert_equal(8, wire.size, hex)
      # And so the second build, and the third, give the same community.
      second = klass.new(wire)
      assert_equal(hex, second.to_shex, hex)
      assert_equal(first.to_s, second.to_s, hex)
      assert_equal(first.to_hash, second.to_hash, hex)
      assert_equal(hex, klass.new(wire).to_shex, hex)
      # The factory takes the same octets and must not eat them either.
      assert_equal(hex, Extended_community.factory(wire).to_shex, hex)
      assert_equal(hex, Extended_community.factory(wire).to_shex, hex)
      assert_equal(hex, wire.unpack1('H*'), hex)
    end
  end

  # Nothing is mutated, so wire bytes that cannot be written to parse
  # too. This used to raise FrozenError on the first build.
  def test_parse_takes_frozen_wire_bytes
    wire = ['0002000100000001'].pack('H*').freeze
    assert_equal('0002000100000001', Route_target.new(wire).to_shex)
    assert_equal('0002000100000001', Extended_community.factory(wire).to_shex)
  end

  # A truncated community is one of the things this library exists to
  # put on the wire, so fewer than 8 octets still build, with the fields
  # that are not there left nil. byteslice gives nil past the end of a
  # String shorter than the type and the sub-type, where slicing gave
  # '', which is why parse guards it. Nothing here is new behaviour: the
  # same objects came out before, only the octets did not survive the
  # build.
  def test_parse_keeps_taking_short_octets
    [[Extended_community, '00',           'Extended community: :'],
     [Route_target,       '0002',         'Route target: :'],
     [Route_target,       '000200',       'Route target: :'],
     [Route_target,       '00020001',     'Route target: 1:'],
     [Route_target,       '000200010000', 'Route target: 1:'],
     [Opaque,             '030a',         'Opaque: '],
    ].each do |klass, hex, text|
      wire = [hex].pack('H*')
      assert_equal(text, klass.new(wire).to_s, hex)
      # Built twice from the same octets, and the octets kept.
      assert_equal(text, klass.new(wire).to_s, hex)
      assert_equal(hex, wire.unpack1('H*'), hex)
    end
    # An opaque community pads its value, so short octets encode too.
    short = ['030a'].pack('H*')
    assert_equal('030a000000000000', Opaque.new(short).to_shex)
    assert_equal('030a000000000000', Opaque.new(short).to_shex)
    assert_equal('030a', short.unpack1('H*'))
    # Octets past the eighth are read no further, and left in place.
    long = ['0002000100000001ffff'].pack('H*')
    assert_equal('0002000100000001', Route_target.new(long).to_shex)
    assert_equal('0002000100000001', Route_target.new(long).to_shex)
    assert_equal('0002000100000001ffff', long.unpack1('H*'))
  end

  # to_hash nests the fields under the community's own key, which is the
  # form Extended_communities reads. Traffic_action's own new read only
  # the outer hash, found :sample, :terminal and :bits all nil, and built
  # a clean looking community encoding 8007000000000000, losing all 48
  # value bits with no error. It is the one community whose field
  # defaults pass their own check, so it is the one that was quiet where
  # the others raise. RFC 8955 section 7.3.
  def test_traffic_action_round_trips_through_its_own_new
    t = BGP::Traffic_action.new(['8007ffffffffffff'].pack('H*'))
    assert_equal({ :traffic_action => { :sample => true, :terminal => true,
                                        :bits => 0xffffffffffff } }, t.to_hash)
    assert_equal('8007ffffffffffff', t.to_shex)
    assert_equal(t.encode, BGP::Traffic_action.new(t.to_hash).encode)
    # And through the collection, which is the route that always worked.
    assert_equal(t.encode,
                 BGP::Extended_communities.new(:extended_communities => [t.to_hash]).encode[3..])
  end

end
