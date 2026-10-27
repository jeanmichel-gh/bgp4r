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

require 'test/unit'
require 'bgp4r'

class Route_refresh_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = "ffffffffffffffffffffffffffffffff00170500010001"
    sbin = [s].pack('H*')
    assert_equal(BGP::Route_refresh, Message.factory(sbin).class)
    rr =  Message.factory(sbin)
    assert_equal(s, rr.to_shex)
    rr.afi, rr.safi=2,2
    assert_equal(2, rr.afi)
    assert_equal(2, rr.safi)
    assert_equal('ffffffffffffffffffffffffffffffff00170500020002', rr.to_shex)
    assert_raise(ArgumentError) { rr.safi=0x100 }
    assert_raise(ArgumentError) { rr.afi=-1 }
    assert_equal(s, BGP::Route_refresh.new(1,1).to_shex)
    assert_equal(s, BGP::Route_refresh.new(:afi=>1, :safi=>1).to_shex)
    assert_equal({:afi=>1, :safi=>1}, BGP::Route_refresh.new(:afi=>1, :safi=>1).to_hash)
    assert_equal(s, Message.route_refresh(1,1).unpack('H*')[0])
  end

  # RFC 2918 section 3: the message is one <AFI, Reserved, SAFI>.
  def test_defaults_to_ipv4_unicast
    assert_equal('00010001', Route_refresh.new.to_shex[-8..-1])
    assert_equal('ffffffffffffffffffffffffffffffff00170500010001', Route_refresh.new.to_shex)
  end

  # A Route_refresh built from another one copies it through its own octets.
  def test_built_from_another_route_refresh
    rr = Route_refresh.new(2, 128)
    copy = Route_refresh.new(rr)
    assert_equal(rr.to_shex, copy.to_shex)
    assert_equal(2, copy.afi)
    assert_equal(128, copy.safi)
    assert_equal({:afi=>2, :safi=>128}, copy.to_hash)
  end

  def test_to_s
    assert_equal("Route Refresh (5), length: 23\nAFI IPv4 (1), SAFI Unicast (1)",
                 Route_refresh.new(1,1).to_s)
    assert_equal("Route Refresh (5), length: 23\nAFI IPv6 (2), SAFI Labeled VPN Unicast (128)",
                 Route_refresh.new(2,128).to_s)
  end
end


class Orf_route_refresh_Test < Test::Unit::TestCase
  include BGP
  
  def test_1
    rr =  Orf_route_refresh.new
    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
    rr << orf
    rr.afi=1
    rr.safi=1
    # RFC 5291 section 4: AFI (2), Reserved (1), SAFI (1), When-to-refresh (1),
    # then the ORFs. The When-to-refresh octet is the 01 after the SAFI, and
    # the message is one octet longer than it is without it: 72, not 71.
    assert_equal('0048' + '05' + '0001' + '00' + '01' + '01' +
                 '40002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832',
                 rr.to_shex[32..-1])
    assert_equal('IPv4', rr.afi)
    assert_equal('Unicast', rr.safi)
    assert_equal(1, rr.orfs.size)
    assert_match(/RF Route Refresh \(5\), length: 72\nAFI IPv4 \(1\), SAFI Unicast \(1\)/, rr.to_s)
  end
  
  def test_2   
    s = "ffffffffffffffffffffffffffffffff004805000100010140002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832"
    sbin = [s].pack('H*')
    assert_equal(Orf_route_refresh, Message.factory(sbin).class)
    rr =  Message.factory(sbin)
    assert_equal(s, rr.to_shex)
    assert_equal(1, rr.orfs.size)
    assert_equal(Orf_route_refresh::IMMEDIATE, rr.when_to_i)
  end

  def test_afi_and_safi_accessors
    rr = Orf_route_refresh.new(1, 1)
    assert_equal([1, 1], [rr.afi_to_i, rr.safi_to_i])
    assert_equal(['IPv4', 'Unicast'], [rr.afi, rr.safi])
    rr.afi, rr.safi = 2, 128
    assert_equal([2, 128], [rr.afi_to_i, rr.safi_to_i])
    assert_equal(['IPv6', 'Labeled VPN Unicast'], [rr.afi, rr.safi])
    assert_raise(ArgumentError) { rr.afi = 0x10000 }
    assert_raise(ArgumentError) { rr.safi = -1 }
    assert_raise(ArgumentError) { rr.afi = '1' }
  end

  def test_built_from_a_hash
    rr = Orf_route_refresh.new(:afi=>2, :safi=>2)
    assert_equal([2, 2], [rr.afi_to_i, rr.safi_to_i])
    assert_equal({:afi=>2, :safi=>2}, rr.to_hash)
    assert_equal(Orf_route_refresh.new(2,2).encode, rr.encode)
    # the hash of a message with no ORF entries round trips through new
    assert_equal(rr.encode, Orf_route_refresh.new(rr.to_hash).encode)
  end

  def test_built_from_another_orf_route_refresh
    rr = Orf_route_refresh.new(1, 1)
    rr << Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')])
    copy = Orf_route_refresh.new(rr)
    assert_equal(rr.to_shex, copy.to_shex)
    assert_equal(1, copy.orfs.size)
    assert_equal(rr.orfs[0].encode, copy.orfs[0].encode)
  end

  # RFC 5291 section 4: the message carries a list of ORFs, each with its own
  # type and length, so more than one ORF rides in one ROUTE-REFRESH.
  def test_more_than_one_orf
    rr = Orf_route_refresh.new(1, 1)
    rr.add(Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')]),
           Prefix_orf.new([Prefix_entry.remove_and_deny(20, '20.0.0.0/8')]))
    assert_equal(2, rr.orfs.size)
    # RFC 5291 section 4: one When-to-refresh octet for the message, then an
    # ORF Type and Length of ORFs per ORF.
    s = 'ffffffffffffffffffffffffffffffff0030050001000101' +
        '400009000000000a0000080a' + '400009600000001400000814'
    assert_equal(s, rr.to_shex)
    back = Message.factory([s].pack('H*'))
    assert_equal(Orf_route_refresh, back.class)
    assert_equal(2, back.orfs.size)
    assert_equal(s, back.to_shex)
    assert_match(/seq  10    add 10.0.0.0\/8 permit/, back.to_s)
    assert_match(/seq  20 remove 20.0.0.0\/8 deny/, back.to_s)
  end

  def test_add_keeps_only_orfs
    rr = Orf_route_refresh.new(1, 1)
    rr.add('not an orf', 42, nil)
    assert_equal(0, rr.orfs.size)
    # RFC 5291 section 4: the When-to-refresh octet belongs to the message,
    # not to an ORF, so it is there even when no ORF is. That makes the
    # message 24 octets, one more than a plain ROUTE-REFRESH, which is how
    # the receiver tells the two apart.
    assert_equal('ffffffffffffffffffffffffffffffff0018050001000101', rr.to_shex)
  end

  # RFC 5291 section 4: the ORF Type octet. Only the Address Prefix ORF of
  # RFC 5292, type 64, is implemented, so any other type is refused on parse.
  def test_an_orf_type_that_is_not_implemented
    s = ('ff' * 16) + '001d' + '05' + '0001' + '00' + '01' + '01' + '41' + '0002' + 'aabb'
    err = assert_raise(RuntimeError) { Message.factory([s].pack('H*')) }
    assert_equal('orf type 65 not implemented', err.message)
  end

  # RFC 5291 section 4: the When-to-refresh octet sits between the SAFI and
  # the first ORF, and is IMMEDIATE (1) or DEFER (2).
  def test_when_to_refresh
    rr = Orf_route_refresh.new(1, 1)
    rr << Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')])
    # the fifth body octet is the When-to-refresh, and the ORF Type follows it
    afi, _, safi, w = rr.encode[19..-1].unpack('nCCC')
    assert_equal([1, 1, Orf_route_refresh::IMMEDIATE], [afi, safi, w])
    assert_equal(BGP::ORF::PREFIX, rr.encode[24..-1].unpack('C')[0])
    assert_equal(Orf_route_refresh::IMMEDIATE, rr.when_to_i)
    assert_equal('immediate (1)', rr.when_to_s)
    rr.when = :defer
    assert_equal([Orf_route_refresh::DEFER, 'defer (2)'], [rr.when_to_i, rr.when_to_s])
    assert_equal(2, rr.encode[19..-1].unpack('nCCC')[3])
    # what is set is what is read back
    assert_equal(Orf_route_refresh::DEFER, Orf_route_refresh.new(rr.encode).when_to_i)
    assert_equal(rr.to_shex, Orf_route_refresh.new(rr.encode).to_shex)
    rr.when = 1
    assert_equal('immediate (1)', rr.when_to_s)
    rr.when = :immediate
    assert_equal('immediate (1)', rr.when_to_s)
    assert_match(/when-to-refresh immediate \(1\)/, rr.to_s)
  end

  # Encoding is never validated: a When-to-refresh the RFC does not define
  # still goes on the wire, and comes back saying it is bogus.
  def test_a_when_to_refresh_value_the_rfc_does_not_define
    rr = Orf_route_refresh.new(1, 1)
    rr.when = 0x41
    assert_equal(0x41, rr.encode[19..-1].unpack('nCCC')[3])
    back = Orf_route_refresh.new(rr.encode)
    assert_equal(0x41, back.when_to_i)
    assert_equal('bogus (65)', back.when_to_s)
    assert_equal(rr.to_shex, back.to_shex)
  end

  # One octet, so a value it cannot hold is refused rather than truncated.
  def test_when_to_refresh_refuses_a_value_it_cannot_represent
    rr = Orf_route_refresh.new(1, 1)
    assert_raise(ArgumentError) { rr.when = 0x100 }
    assert_raise(ArgumentError) { rr.when = -1 }
    assert_raise(ArgumentError) { rr.when = 'defer' }
  end

  # RFC 5291 section 4: the ORFs ride in the message, so new takes them.
  def test_orfs_given_to_new
    orf = Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')])
    rr = Orf_route_refresh.new(1, 1, orf)
    assert_equal(1, rr.orfs.size)
    plain = Orf_route_refresh.new(1, 1)
    plain << Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')])
    assert_equal(plain.to_shex, rr.to_shex)
    # more than one, listed or in an Array
    two = Orf_route_refresh.new(1, 1,
                                Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')]),
                                Prefix_orf.new([Prefix_entry.remove_and_deny(20, '20.0.0.0/8')]))
    assert_equal(2, two.orfs.size)
    arr = Orf_route_refresh.new(1, 1,
                                [Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8')]),
                                 Prefix_orf.new([Prefix_entry.remove_and_deny(20, '20.0.0.0/8')])])
    assert_equal(2, arr.orfs.size)
    assert_equal(two.to_shex, arr.to_shex)
  end

  # to_hash round trips through new, so it has to carry the When-to-refresh
  # and the ORFs and not the AFI and SAFI alone.
  def test_to_hash_carries_the_when_to_refresh_and_the_orfs
    rr = Orf_route_refresh.new(1, 1)
    rr.when = :defer
    rr << Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8'),
                          Prefix_entry.remove_all])
    h = rr.to_hash
    assert_equal(2, h[:when])
    assert_equal(1, h[:orfs].size)
    assert_equal(BGP::ORF::PREFIX, h[:orfs][0][:type])
    assert_equal(2, h[:orfs][0][:entries].size)
    assert_equal(rr.to_shex, Orf_route_refresh.new(h).to_shex)
    # the ORF objects themselves are taken too
    assert_equal(rr.to_shex, Orf_route_refresh.new(:afi=>1, :safi=>1, :when=>:defer,
                                                   :orfs=>rr.orfs).to_shex)
    # @communities was never assigned, so the reader could only ever raise
    assert(!rr.respond_to?(:communities))
  end

  # RFC 5291 section 4: the AFI of the message is the address family the ORF
  # entries are read in, so an IPv6 ORF has to come back as IPv6.
  def test_an_ipv6_orf_reads_back_in_the_message_afi
    rr = Orf_route_refresh.new(2, 1)
    rr << Prefix_orf.new([Prefix_entry.new(0, 0, 10, 0, 0, '2011:1::/32')])
    back = Message.factory([rr.to_shex].pack('H*'))
    assert_equal(Orf_route_refresh, back.class)
    assert_equal(2, back.afi_to_i)
    assert_match(/seq  10    add 2011:1::\/32 permit/, back.to_s)
    assert_equal(rr.to_shex, back.to_shex)
    assert_equal(rr.to_hash, back.to_hash)
  end

  # A body too short to hold the When-to-refresh octet carries no ORF either,
  # so parsing a plain ROUTE-REFRESH as one of these answers rather than raises.
  def test_parsing_a_plain_route_refresh
    rr = Orf_route_refresh.new(Route_refresh.new(1, 1).encode)
    assert_equal([1, 1], [rr.afi_to_i, rr.safi_to_i])
    assert_equal(0, rr.orfs.size)
    assert_nil(rr.when_to_i)
    assert_equal('bogus ()', rr.when_to_s)
  end
end
