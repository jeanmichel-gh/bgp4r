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

# What a receiver finds wrong in one RTR PDU, as RFC 8210 section 12's
# Error Code.
class TestRtrValidation < Test::Unit::TestCase
  include BGP::Rtr

  def codes(octets, **opts) ; Validation.check(octets, **opts).collect(&:code) ; end

  def with_length(octets, length) ; octets.byteslice(0, 4) + [length].pack('N') + octets.byteslice(8..) ; end

  def test_every_pdu_built_here_is_clean
    [Serial_notify.new(1, 2), Serial_query.new, Reset_query.new, Cache_response.new, Ipv4_prefix.new('10.0.0.0/8', 24, 1),
     Ipv6_prefix.new('2001:db8::/32', 48, 1), End_of_data.new, Cache_reset.new, Router_key.new("\0" * 20, 1, "\x30\x00"),
     Error_report.new(0, Reset_query.new, 'x'), Error_report.new(1)].each do |p|
      assert_equal([], Validation.check(p.encode), p.class.name)
    end
    eod = End_of_data.new(:version => 0)
    assert_equal([], codes(eod.encode, :negotiated => 0), 'version 0 is 12 octets')
  end

  # Section 7: a version neither 0 nor 1, then one other than agreed.
  def test_versions
    p = Cache_response.new(1)
    p.version = 9
    f = Validation.check(p.encode)
    assert_equal([4, 'Unsupported Protocol Version', true], [f.first.code, f.first.name, f.first.fatal?])
    p.version = 0
    assert_equal([8], codes(p.encode, :negotiated => 1))
    assert_equal([], codes(p.encode), 'before negotiation, 0 is fine')
    p.version = 9
    assert_equal([8], codes(p.encode, :negotiated => 1), 'after negotiation, any other version is 8')
  end

  def test_an_unknown_type
    assert_equal([5], codes(Unknown.new(99).encode))
  end

  # Section 5: each PDU's Length, and the Length against the octets.
  def test_lengths
    v4 = Ipv4_prefix.new('10.0.0.0/8', 8, 1).encode
    assert_equal([0], codes(with_length(v4 + "\0\0\0\0", 24)), 'a type 4 PDU is 20')
    assert_equal([0, 0], codes(with_length(v4, 24)), 'the Length overruns the octets, and is not 20')
    assert_equal([0], codes("\x01\x02\x00"), 'shorter than a header')
    eod = End_of_data.new.encode
    assert_equal([0], codes(with_length(eod.byteslice(0, 12), 12)), 'version 1 End of Data is 24')
    assert_equal([0], codes(with_length("\x01\x09\x01\x00\x00\x00\x00\x00" + "\0" * 20, 28)), 'a Router Key is at least 32')
    key = Router_key.new("\0" * 20, 1, '').encode
    key.setbyte(0, 0)
    assert_equal([5], codes(key), 'version 0 has no Router Key')
  end

  # Section 5.1: "This MUST NOT be less than the Prefix Length element",
  # and neither is more than the address's bits.
  def test_prefix_lengths
    assert_equal([0], codes(Ipv4_prefix.new('10.0.0.0/24', 16, 1).encode))
    assert_equal([0, 0], codes(Ipv4_prefix.new(:prefix => '10.0.0.0/33', :max_length => 33).encode))
    assert_equal([0], codes(Ipv6_prefix.new('2001:db8::/32', 129, 1).encode))
  end

  # Section 5.11: the two inner lengths fit the PDU.
  def test_error_report_lengths
    e = Error_report.new(0, 'abcd', 'xy').encode
    assert_equal([], codes(e))
    over = e.dup
    over[11] = "\x09"
    assert_equal([0], codes(over), 'Length of Encapsulated PDU overruns')
    text = e.dup
    text[19] = "\x05"
    assert_equal([0], codes(text), 'Length of Error Text overruns')
    assert_equal([0], codes([1, 10, 0, 8].pack('CCnN')), 'no Length of Encapsulated PDU at all')
  end

  def test_a_finding_reads
    f = Validation.check(Unknown.new(99).encode).first
    assert_equal('Unsupported PDU Type (5): PDU type 99', f.to_s)
    assert_equal(false, Validation.finding(2, 'x').fatal?)
  end
end
