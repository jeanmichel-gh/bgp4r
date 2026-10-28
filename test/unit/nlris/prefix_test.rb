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
  # The twenty octets of an NSAP address, Length 160. The ceiling in
  # Nsap.new_nsap used to be 152, so this came back as twenty octets
  # total instead of twenty-one: the Length octet dropped to 152 and the
  # twentieth prefix octet went with it.
  def test_an_nsap_prefix_of_the_full_160_bits_round_trips
    wire = ['a0' + '49' + '00' * 19].pack('H*')
    pfx = BGP::Prefix.new_ntop(wire.dup, 3)
    assert_equal(160, pfx.mlen)
    assert_equal(wire.unpack1('H*'), pfx.to_shex)
    assert_equal(21, pfx.encode.bytesize, 'a Length octet and twenty prefix octets')
  end

  # A Length wider than the address keeps the octets past the twenty, the
  # way an over-wide IPv4 or IPv6 Length does, and reports the Length it
  # was given rather than a clamped one.
  def test_an_nsap_prefix_wider_than_its_address_keeps_the_rest
    wire = ['c8' + '49' + '01' * 24].pack('H*')   # Length 200, 25 octets
    pfx = BGP::Prefix.new_ntop(wire.dup, 3)
    assert_equal(200, pfx.mlen, 'the Length as it arrived')
    assert_equal(wire.unpack1('H*'), pfx.to_shex, 'byte for byte')
    assert_equal('0101010101', pfx.tail.unpack1('H*'), 'the five octets past the twenty')
  end

  # And the consumption stays right, so reading one prefix after another
  # still works when the first one is over-wide.
  def test_an_over_wide_nsap_prefix_consumes_its_own_octets
    s = ['c8' + '49' + '01' * 24].pack('H*') + ['2049000100'].pack('H*')
    first = BGP::Prefix.new_ntop(s, 3)
    assert_equal(200, first.mlen)
    second = BGP::Prefix.new_ntop(s, 3)
    assert_equal(32, second.mlen, 'the next prefix was read, not the first one again')
    assert_equal('', s, 'and both were consumed')
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
  def test_a_prefix_length_wider_than_the_family_is_kept_not_raised
    # RFC 4271 section 4.3: "The Length field indicates the length in bits
    # of the IP address prefix", and nothing caps it at the width of the
    # family. RFC 7606 section 5.3 calls a length over 32 a syntactically
    # incorrect NLRI field, and RFC 4271 section 6.3 answers one with the
    # Invalid Network Field subcode. So the fault is reported, the octets
    # are kept, and nothing raises.
    s = ['210102030405'].pack('H*')
    pfx = Prefix.new_ntop(s.dup)
    assert_equal(33, pfx.mlen)
    assert_equal('1.2.3.4/33', pfx.to_s)
    assert_equal(1, pfx.afi)
    assert_equal('210102030405', pfx.to_shex)
    assert_equal(false, pfx.syntactically_correct?)
    assert_equal('05', pfx.tail.unpack1('H*'))
    # The tuple is 1+(33+7)/8 octets, so a prefix behind it is untouched.
    left = ['2101020304050865'].pack('H*')
    Prefix.new_ntop(left)
    assert_equal('0865', left.unpack1('H*'))
  end

  def test_the_three_build_paths_agree_on_an_over_wide_prefix_length
    from_wire = Prefix.new_ntop(['210102030405'].pack('H*'))
    from_hash = Prefix.new(from_wire.to_hash)
    from_values = Prefix.new('1.2.3.4/33')
    assert_equal({:prefix=>'1.2.3.4/33', :tail=>'05'}, from_wire.to_hash)
    assert_equal(from_wire.to_shex, from_hash.to_shex)
    assert_equal(from_wire.to_hash, from_hash.to_hash)
    # Built from field values there is no leftover octet to carry, so the
    # one encode writes is zero. The length still arrives on the wire.
    assert_equal(33, from_values.mlen)
    assert_equal('210102030400', from_values.to_shex)
    assert_equal(false, from_values.syntactically_correct?)
    assert_equal({:prefix=>'1.2.3.4/33'}, from_values.to_hash)
    # A Path Identifier still goes in front of the whole tuple
    # (RFC 7911 section 3).
    ext = Prefix.new_ntop_extended(['00000064210102030405'].pack('H*'))
    assert_equal('00000064210102030405', ext.to_shex)
    assert_equal('ID=100, 1.2.3.4/33', ext.to_s)
    assert_equal(ext.to_shex, Prefix.new(ext.to_hash).to_shex)
  end

  def test_an_over_wide_prefix_length_in_inet6_and_at_the_ceiling
    s = ['8120010db8000000000000000000000000ff'].pack('H*')
    pfx = Prefix.new_ntop(s.dup, 2)
    assert_equal(129, pfx.mlen)
    assert_equal('2001:db8::/129', pfx.to_s)
    assert_equal(2, pfx.afi)
    assert_equal('8120010db8000000000000000000000000ff', pfx.to_shex)
    assert_equal(false, pfx.syntactically_correct?)
    # The widest a length octet can say is 255, which asks for 32 octets.
    wide = ['ff' + '0a' * 32].pack('H*')
    p255 = Prefix.new_ntop(wide.dup)
    assert_equal(255, p255.mlen)
    assert_equal(32, p255.nbytes)
    assert_equal('ff' + '0a' * 32, p255.to_shex)
    # A length that fits is untouched: no tail, no new hash key.
    ok = Prefix.new('10.255.255.255/17')
    assert_equal(true, ok.syntactically_correct?)
    assert_nil(ok.tail)
    assert_equal({:prefix=>'10.255.128.0/17'}, ok.to_hash)
  end

  def test_an_over_wide_prefix_length_in_a_truncated_field
    # A short field reads what arrived and zero fills the rest, the way an
    # ordinary truncated prefix already does.
    pfx = Prefix.new_ntop(['21'].pack('H*'))
    assert_equal('0.0.0.0/33', pfx.to_s)
    assert_equal('210000000000', pfx.to_shex)
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
