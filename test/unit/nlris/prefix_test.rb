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
require 'bgp/nlris/prefix'

class Prefix_Test < Test::Unit::TestCase
  include BGP
  def test_inet
    pfx =  Prefix.new('10.0.0.0')
    assert_equal('10.0.0.0/32', pfx.to_s)
    assert_equal('200a000000', pfx.to_shex)
    pfx =  Prefix.new('10.1.1.1/16')
    assert_equal('10.1.0.0/16', pfx.to_s)
    assert_equal('100a01', pfx.to_shex)
    pfx =  Prefix.new('10.255.255.255/17')
    assert_equal(17, pfx.mlen)
    assert_equal('10.255.128.0/17', pfx.to_s)
    assert_equal('110aff80', pfx.to_shex)
    assert   pfx.ipv4?
    assert ! pfx.ipv6?
    assert ! pfx.iso?
    assert_equal(1, pfx.afi)
    assert ! pfx.extended?
    assert_equal('IPv4=10.255.128.0/17', pfx.to_s_with_afi)
    assert_equal({:prefix=>"10.255.128.0/17"}, pfx.to_hash)
    assert_equal(pfx.to_hash, Prefix.new(pfx.to_hash).to_hash)
  end
  def test_extended
    pfx = Prefix.new(100, '10.0.0.0')
    assert pfx.extended?
    assert_equal('00000064200a000000', pfx.to_shex)
    assert_equal('ID=100, 10.0.0.0/32', pfx.to_s)
    pfx1 = Prefix.new_ntop_extended(pfx.encode)
    assert_equal(pfx.to_shex, pfx1.to_shex)
    pfx = Prefix.new(100, '2011:13:11::0/64')
    assert pfx.extended?
    assert_equal('ID=100, 2011:13:11::/64', pfx.to_s)
    assert_equal('00000064402011001300110000', pfx.to_shex)
    assert_equal('ID=100, IPv6=2011:13:11::/64', pfx.to_s_with_afi)
    assert_equal({:path_id=>100, :prefix=>"2011:13:11::/64"}, pfx.to_hash)
    assert_equal(pfx.to_hash, Prefix.new(pfx.to_hash).to_hash)
  end
  def test_inet6
    pfx =  Prefix.new('2011:13:11::0/64')
    assert_equal('2011:13:11::/64', pfx.to_s)
    assert_equal(64, pfx.mlen)
    assert_equal('402011001300110000', pfx.to_shex)
    pfx =  Prefix.new('2011:13:11::0')
    assert_equal('2011:13:11::/128', pfx.to_s)
    assert_equal('8020110013001100000000000000000000', pfx.to_shex)
    assert ! pfx.ipv4?
    assert   pfx.ipv6?
    assert ! pfx.iso?
    assert_equal(2, pfx.afi)
    assert_equal('IPv6=2011:13:11::/128', pfx.to_s_with_afi)
  end
  def test_nsap
    pfx =  Prefix.new('49.0001.0002.0003')
    assert_equal('9849000100020003000000000000000000000000', pfx.to_shex )
    assert_equal('49.0001.0002.0003.0000.0000.0000.0000.0000.0000.00/152', pfx.to_s)
    
    pfx =  Prefix.new('49.0001.0002.0003/32')
    assert_equal('2049000100', pfx.to_shex )
    assert_equal('49.0001.0000.0000.0000.0000.0000.0000.0000.0000.00/32', pfx.to_s)

    pfx =  Prefix.new('49.0001.0002.0003/48')
    assert_equal('30490001000200', pfx.to_shex )
    assert_equal('49.0001.0002.0000.0000.0000.0000.0000.0000.0000.00/48', pfx.to_s)

    pfx =  Prefix.new('49.0001.0002.0003/55')
    assert_equal('3749000100020002', pfx.to_shex )
    assert_equal('49.0001.0002.0002.0000.0000.0000.0000.0000.0000.00/55', pfx.to_s)

    pfx =  Prefix.new('49.0001.0002.0003/56')
    assert_equal('3849000100020003', pfx.to_shex )
    assert_equal('49.0001.0002.0003.0000.0000.0000.0000.0000.0000.00/56', pfx.to_s)

    assert ! pfx.ipv4?
    assert ! pfx.ipv6?
    assert   pfx.iso?
    assert_equal(3, pfx.afi)
    assert_equal('NSAP=49.0001.0002.0003.0000.0000.0000.0000.0000.0000.00/56', pfx.to_s_with_afi)
    assert_equal(pfx.to_hash, Prefix.new(pfx.to_hash).to_hash)
  end
  def test_new_ntop_inet
    s = '110aff80'
    pfx = Prefix.new_ntop([s].pack('H*'))
    assert_equal(s, pfx.to_shex)
    assert_equal('10.255.128.0/17', pfx.to_s)
  end
  def test_new_ntop_inet6
    s = '402011001300110000'
    pfx = Prefix.new_ntop([s].pack('H*'),:ipv6)
    assert_equal(s, pfx.to_shex)
    assert_equal('2011:13:11::/64', pfx.to_s)
    s = '402011001300110000'
    pfx = Prefix.new_ntop([s].pack('H*'),2)
    assert_equal(s, pfx.to_shex)
    assert_equal('2011:13:11::/64', pfx.to_s)
    assert_equal(2, pfx.afi)
  end
  def test_new_ntop_inet_extended
    s = '00000064402011001300110000'
    pfx = Prefix.new_ntop_extended([s].pack('H*'),2)
    assert_equal(s, pfx.to_shex)
    assert_equal('ID=100, 2011:13:11::/64', pfx.to_s)
  end
  def test_new_ntop_nsap
    s = '30490001000200'
    pfx = Prefix.new_ntop([s].pack('H*'),3)
    assert_equal(s, pfx.to_shex)
    assert_equal('49.0001.0002.0000.0000.0000.0000.0000.0000.0000.00/48', pfx.to_s)
  end
  def test_new_ntop_nsap_extended
    s = '000000652049000100'
    pfx = Prefix.new_ntop_extended([s].pack('H*'),:nsap)
    assert_equal(s, pfx.to_shex)
    assert_equal('ID=101, 49.0001.0000.0000.0000.0000.0000.0000.0000.0000.00/32', pfx.to_s)
  end
  def test_afi_predicates_return_false_not_nil
    # An IPAddr has no iso?, an Nsap has no ipv4? or ipv6?. Answer false.
    assert_equal(false, Prefix.new('10.0.0.0/8').iso?)
    assert_equal(false, Prefix.new('2011:13:11::/48').iso?)
    assert_equal(false, Prefix.new('49.0001.0002.0003/56').ipv4?)
    assert_equal(false, Prefix.new('49.0001.0002.0003/56').ipv6?)
  end
  def test_afi_predicates_do_not_hide_errors
    pfx = Prefix.new('10.0.0.0/8')
    broken = Object.new
    def broken.ipv4? ; raise ArgumentError, 'broken' ; end
    pfx.instance_variable_set(:@pfx, broken)
    assert_raise(ArgumentError) { pfx.ipv4? }
  end

  # Prefix#mlen used to never return for a /0, because IPAddr#mlen shifted
  # an all zero mask looking for a set bit, so a plain call wedged the whole
  # suite rather than failing one test. Build, encode and parse inside a
  # thread this can give up on, and touch mlen on each object there so it is
  # memoized. The assertions below then run on warm objects and cannot hang,
  # and the bug coming back reads as a failure here.
  def default_route(arg, afi, seconds = 10)
    built = nil
    t = Thread.new do
      pfx = Prefix.new(arg)
      pfx.mlen
      back = Prefix.new_ntop(pfx.encode, afi)
      back.mlen
      rebuilt = Prefix.new(pfx.to_hash)
      rebuilt.mlen
      built = [pfx, back, rebuilt]
    end
    assert(t.join(seconds), "Prefix#mlen did not return within #{seconds}s for #{arg}")
    built
  ensure
    t.kill if t
  end
  def test_default_route_round_trips
    # RFC 4271 section 4.3: a prefix is a length octet followed by only the
    # octets that length needs, so a default route is one zero octet.
    pfx, back, rebuilt = default_route('0.0.0.0/0', 1)
    assert_equal(0, pfx.mlen)
    assert_equal(0, pfx.nbytes)
    assert_equal('0.0.0.0/0', pfx.to_s)
    assert_equal('IPv4=0.0.0.0/0', pfx.to_s_with_afi)
    assert_equal(1, pfx.afi)
    assert_equal('00', pfx.to_shex)
    assert_equal('0.0.0.0/0', back.to_s)
    assert_equal(pfx.to_shex, back.to_shex)
    assert_equal({:prefix=>'0.0.0.0/0'}, pfx.to_hash)
    assert_equal(pfx.to_hash, rebuilt.to_hash)
  end
  def test_default_route_round_trips_inet6
    pfx, back, rebuilt = default_route('::/0', 2)
    assert_equal(0, pfx.mlen)
    assert_equal(0, pfx.nbytes)
    assert_equal('::/0', pfx.to_s)
    assert_equal('IPv6=::/0', pfx.to_s_with_afi)
    assert_equal(2, pfx.afi)
    assert_equal('00', pfx.to_shex)
    assert_equal('::/0', back.to_s)
    assert_equal(pfx.to_shex, back.to_shex)
    assert_equal({:prefix=>'::/0'}, pfx.to_hash)
    assert_equal(pfx.to_hash, rebuilt.to_hash)
  end
  def test_new_ntop_consumes_only_the_length_octet_of_a_default_route
    # new_ntop slices what it read off the caller's String, so a default
    # route in a run of prefixes leaves the next one in place.
    s = ['00080a'].pack('H*')
    first, second = nil, nil
    t = Thread.new { first = Prefix.new_ntop(s, 1) ; first.mlen ; second = Prefix.new_ntop(s, 1) }
    assert(t.join(10), 'Prefix.new_ntop did not return within 10s for a default route')
    assert_equal('0.0.0.0/0', first.to_s)
    assert_equal('10.0.0.0/8', second.to_s)
    assert_equal('', s)
  ensure
    t.kill if t
  end
  def test_new_ntop_unknown_afi_says_so
    s = ['0a0a'].pack('H*')
    [[:new_ntop, 25], [:new_ntop, :ipx], [:new_ntop_extended, 25]].each do |meth, afi|
      e = assert_raise(ArgumentError) { Prefix.send(meth, ['00000001'].pack('H*') + s, afi) }
      assert_match(/unknown AFI #{Regexp.escape(afi.inspect)}/, e.message)
      assert_match(/:ipv4.*:ipv6.*:nsap/, e.message)
    end
  end
end
