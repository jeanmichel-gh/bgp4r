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
require 'bgp/rtr'

# Each PDU of RFC 8210 section 5 against its diagram, octet by octet,
# and built the four ways. docs/design/bgp-operations.md 7a.
class TestRtrPdus < Test::Unit::TestCase
  include BGP::Rtr

  def hex(s) ; [s.delete(' ')].pack('H*') ; end

  # Each PDU, its octets written by hand from its diagram (version,
  # type, the 16-bit field, Length, then the body), and its hash.
  CASES = {
    # 5.2: Session ID 0x1234, Length 12, Serial Number 7.
    'Serial_notify' => [-> { Serial_notify.new(0x1234, 7) }, '01 00 1234 0000000c 00000007',
                        { :session_id => 0x1234, :serial => 7 }],
    # 5.3: the same with type 1.
    'Serial_query' => [-> { Serial_query.new(0x1234, 7) }, '01 01 1234 0000000c 00000007',
                       { :session_id => 0x1234, :serial => 7 }],
    # 5.4: zero, Length 8.
    'Reset_query' => [-> { Reset_query.new }, '01 02 0000 00000008', {}],
    # 5.5: Session ID, Length 8.
    'Cache_response' => [-> { Cache_response.new(0x1234) }, '01 03 1234 00000008', { :session_id => 0x1234 }],
    # 5.6: zero, Length 20; Flags 1, Prefix Length 24, Max Length 28,
    # zero; 192.0.2.0; AS 65001.
    'Ipv4_prefix' => [-> { Ipv4_prefix.new('192.0.2.0/24', 28, 65_001) },
                      '01 04 0000 00000014 01 18 1c 00 c0000200 0000fde9',
                      { :flags => 1, :prefix => '192.0.2.0/24', :max_length => 28, :asn => 65_001 }],
    # 5.7: Length 32, a withdrawal (Flags 0) of 2001:db8::/32 to 48.
    'Ipv6_prefix' => [-> { Ipv6_prefix.new('2001:db8::/32', 48, 65_001, false) },
                      '01 06 0000 00000020 00 20 30 00 20010db8000000000000000000000000 0000fde9',
                      { :flags => 0, :prefix => '2001:db8::/32', :max_length => 48, :asn => 65_001 }],
    # 5.8: Length 24, Serial 7, then Refresh, Retry, Expire at section
    # 6's defaults, 3600, 600 and 7200.
    'End_of_data' => [-> { End_of_data.new(0x1234, 7) },
                      '01 07 1234 00000018 00000007 00000e10 00000258 00001c20',
                      { :session_id => 0x1234, :serial => 7, :refresh => 3600, :retry => 600, :expire => 7200 }],
    # 5.9: zero, Length 8.
    'Cache_reset' => [-> { Cache_reset.new }, '01 08 0000 00000008', {}],
    # 5.10: Flags 1 then zero; Length 34; a 20-octet SKI; AS; a 2-octet
    # Subject Public Key Info.
    'Router_key' => [-> { Router_key.new("\x11" * 20, 65_001, "\x30\x00") },
                     "01 09 0100 00000022 #{'11' * 20} 0000fde9 3000",
                     { :flags => 1, :ski => '11' * 20, :asn => 65_001, :spki => '3000' }],
    # 5.11: Error Code 5; Length 31; the 8-octet PDU it is about; 7
    # octets of text.
    'Error_report' => [-> { Error_report.new(5, Unknown.new(99), 'type 99') },
                       '01 0a 0005 0000001f 00000008 0163000000000008 00000007 74797065203939',
                       { :code => 5, :pdu => '0163000000000008', :text => 'type 99' }],
  }.freeze

  def test_each_pdu_against_its_diagram
    CASES.each do |name, (build, octets, fields)|
      pdu = build.call
      assert_equal(hex(octets), pdu.encode, name)
      assert_equal({ pdu.hash_key => { :version => 1 }.merge(fields) }, pdu.to_hash, name)
    end
  end

  # The four ways, each giving the same octets, and the factory picking
  # the class from the type.
  def test_each_pdu_is_built_four_ways
    CASES.each do |name, (build, octets, _)|
      pdu = build.call
      klass = BGP::Rtr.const_get(name)
      [klass.new(hex(octets)), klass.new(pdu), klass.new(pdu.to_hash), Pdu.factory(hex(octets))].each do |other|
        assert_equal(klass, other.class, name)
        assert_equal(pdu.encode, other.encode, name)
      end
    end
  end

  # The hash without its name works too, as a node file would write it.
  def test_the_inner_hash_builds_one
    assert_equal(Ipv4_prefix.new('10.0.0.0/8', 8, 1).encode, Ipv4_prefix.new(:prefix => '10.0.0.0/8', :asn => 1).encode,
                 'Max Length defaults to the Prefix Length')
    assert_equal(0, Ipv4_prefix.new(:prefix => '10.0.0.0/8', :flags => 0).flags)
  end

  # RFC 6810 section 5.7: version 0's End of Data stops at the Serial
  # Number, Length 12.
  def test_end_of_data_in_version_0
    eod = End_of_data.new(:version => 0, :session_id => 1, :serial => 2)
    assert_equal(hex('00 07 0001 0000000c 00000002'), eod.encode)
    back = End_of_data.new(eod.encode)
    assert_equal({ :end_of_data => { :version => 0, :session_id => 1, :serial => 2 } }, back.to_hash)
    assert_nil(back.refresh)
  end

  # A type this code does not know is kept whole and goes out unchanged.
  def test_an_unknown_type_is_kept
    octets = hex('01 63 abcd 0000000a 0102')
    pdu = Pdu.factory(octets)
    assert_instance_of(Unknown, pdu)
    assert_equal([99, octets], [pdu.type, pdu.encode])
    assert_equal(octets, Unknown.new(99, 1, 0xabcd, "\x01\x02").encode)
    assert_equal(octets, Unknown.new(pdu.to_hash).encode)
  end

  # Whole PDUs off the front of a stream, and what is left.
  def test_pdus_off_a_stream
    a, b = Serial_notify.new(1, 2).encode, Cache_reset.new.encode
    list, rest = BGP::Rtr.pdus(b + a + b + a.byteslice(0, 10))
    assert_equal([Cache_reset, Serial_notify, Cache_reset], list.collect(&:class))
    assert_equal(a.byteslice(0, 10), rest, 'a PDU whose header is there and body not yet waits')
    assert_equal([[], b.byteslice(0, 5)], BGP::Rtr.pdus(b.byteslice(0, 5)), 'so does a header not all there')
    list, rest = BGP::Rtr.pdus(hex('01 02 0000 00000004 ffff'))
    assert_equal([[Unknown], ''], [list.collect(&:class), rest], 'a Length below 8 cannot be stepped over')
  end

  def test_readers
    v = Ipv4_prefix.new('192.0.2.0/24', 28, 65_001)
    assert_equal([true, ['192.0.2.0', 24, 28, 65_001]], [v.announce?, v.key])
    assert_equal(false, Router_key.new("\0" * 20, 1, '', false).announce?)
    e = Error_report.new(2)
    assert_equal(['No Data Available', false], [e.name, e.fatal?])
    assert_equal(['Unsupported PDU Type', true], [Error_report.new(5).name, Error_report.new(5).fatal?])
    assert_equal('code 42', BGP::Rtr.error_name(42))
    assert_match(/RTR Ipv4 prefix \(4\), version 1, length 20: flags 1, prefix 192.0.2.0\/24/, v.to_s)
  end
end
