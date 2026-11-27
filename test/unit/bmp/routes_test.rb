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
require 'bgp/bmp/routes'

# Bmp::Routes: an UPDATE as routes, and each route back as an UPDATE of
# its own, as bgp4rd sends a station its dump. docs/design/bgp-operations.md 8c.
class TestBmpRoutes < Test::Unit::TestCase
  R = BGP::Bmp::Routes

  def pa(*more) ; BGP::Path_attribute.new(BGP::Origin.new, BGP::As_path.new(65_001), *more) ; end

  # Each route of an UPDATE, rebuilt alone, and the UPDATE that has only
  # that route.
  def each_back(update, alone)
    reach = R.mp(update, BGP::Mp_reach)
    mp = reach && reach.to_hash[:mp_reach].reject { |k, _| k == :nlris }
    R.announced(update).zip(alone).each do |(afi, safi, n), want|
      back = R.update(afi, safi, n, R.attributes(update), [afi, safi] == [1, 1] && !reach ? nil : mp)
      assert_equal(want.encode, back.encode, n.to_s)
    end
  end

  def test_ipv4_unicast
    u = BGP::Update.new(pa(BGP::Next_hop.new('192.0.2.9')), BGP::Nlri.new('10.0.0.0/8', '10.1.0.0/16'))
    assert_equal([[1, 1, '10.0.0.0/8', nil], [1, 1, '10.1.0.0/16', nil]], R.announced(u).collect { |a, s, n, h| [a, s, n.to_s, h] })
    each_back(u, %w[10.0.0.0/8 10.1.0.0/16].collect { |p| BGP::Update.new(pa(BGP::Next_hop.new('192.0.2.9')), BGP::Nlri.new(p)) })
  end

  def test_a_path_id
    n = BGP::Nlri.new({ :path_id => 3, :nlri => '10.0.0.0/8' })
    u = BGP::Update.new(pa, n)
    assert_equal({ :prefix => '10.0.0.0/8', :path_id => 3 }, R.announced(u).first[2].to_hash)
    each_back(u, [u])
  end

  def test_ipv6_and_vpn
    v6 = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => ['2001:db8:1::/48', '2001:db8:2::/48'])
    u = BGP::Update.new(pa(v6))
    assert_equal('2001:db8::1', R.announced(u).first[3])
    each_back(u, %w[2001:db8:1::/48 2001:db8:2::/48].collect do |p|
      BGP::Update.new(pa(BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => [p])))
    end)
    vpn = BGP::Mp_reach.new(:afi => 1, :safi => 128, :nexthop => ['192.0.2.9'],
                            :nlris => [{ :rd => [100, 1], :prefix => '10.1.0.0/16', :label => 100 }])
    each_back(BGP::Update.new(pa(vpn)), [BGP::Update.new(pa(vpn))])
    v6pid = BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :path_id => 5, :nlris => ['2001:db8:1::/48'])
    each_back(BGP::Update.new(pa(v6pid)), [BGP::Update.new(pa(v6pid))])
  end

  def test_withdrawn
    u = BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8'),
                        BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8:1::/48'])))
    assert_equal([[1, 1, '10.0.0.0/8'], [2, 1, '2001:db8:1::/48']], R.withdrawn(u).collect { |a, s, n| [a, s, n.to_s] })
  end

  def test_the_key_leaves_the_labels_out
    a = BGP::Mp_reach.new(:afi => 1, :safi => 128, :nexthop => ['192.0.2.9'],
                          :nlris => [{ :rd => [100, 1], :prefix => '10.1.0.0/16', :label => 100 }]).nlris.first
    w = BGP::Mp_unreach.new(:afi => 1, :safi => 128, :nlris => [{ :rd => [100, 1], :prefix => '10.1.0.0/16', :label => 0x800000 }])
    w = BGP::Attr.factory(w.encode.is_packed).nlris.first
    assert_equal(R.key(1, 128, a), R.key(1, 128, w))
    assert_equal([1, 128, { :rd => [100, 1], :prefix => '10.1.0.0/16' }], R.key(1, 128, a))
  end

  def test_end_of_rib
    assert_equal([1, 1], R.end_of_rib(BGP::Update.new))
    assert_equal([2, 1], R.end_of_rib(BGP::Update.end_of_rib_marker(:afi => 2, :safi => 1)))
    assert_nil(R.end_of_rib(BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8'))))
    assert_nil(R.end_of_rib(BGP::Update.new(BGP::Path_attribute.new(BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2001:db8::/32'])))))
  end

  def test_attributes
    assert_nil(R.attributes(BGP::Update.new))
    u = BGP::Update.new(pa(BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'], :nlris => ['2001:db8:1::/48'])))
    assert_equal({ :origin => :igp, :as_path => { :sequence => [65_001] } }, R.attributes(u).to_hash)
  end
end
