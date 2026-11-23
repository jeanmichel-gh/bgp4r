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

require 'test/unit'
require 'rbconfig'
require 'bgp/daemon/community_keys'

# The file has to stand on its own, which is why it exists: bgp/gen
# requires it and must not load a session loop. So this file requires
# nothing else, and a run of it alone is the check.
class TestBgpDaemonCommunityKeys < Test::Unit::TestCase
  K = BGP::Daemon::CommunityKeys

  # In a fresh process, since in the suite another file has loaded the
  # speaker long before this runs, which would make the check say
  # nothing either way.
  def test_it_loads_without_the_speaker
    ruby = File.join(RbConfig::CONFIG['bindir'], RbConfig::CONFIG['ruby_install_name'])
    root = File.expand_path('../../..', __dir__)
    out = IO.popen([ruby, '-I', root, '-e',
                    'require "bgp/daemon/community_keys"; ' \
                    'p [BGP::Daemon.const_defined?(:CommunityKeys, false), BGP::Daemon.const_defined?(:Speaker, false)]'],
                   &:read)
    assert_equal("[true, false]\n", out, 'requiring the keys pulled in the session loop')
  end

  def test_no_key_no_attribute
    assert_equal([], K.community_attributes({}))
  end

  def test_each_key_builds_its_attribute
    a = K.community_attributes('communities' => ['65000:1', 'no_export'],
                               'extended_communities' => ['route_target:65000:7'],
                               'large_communities' => ['65000:1:1'])
    assert_equal([BGP::Communities, BGP::Extended_communities, BGP::Large_communities],
                 a.collect(&:class))
    assert_equal('65000:1 65535:65281', a[0].communities, 'no_export is RFC 1997 0xFFFFFF01')
    assert_equal({:route_target => [65000, 7]}, a[1].to_hash[:extended_communities].first)
    assert_equal('65000:1:1', a[2].large_communities)
  end

  def test_a_single_string_is_a_list_of_one
    assert_equal('65000:1', K.community_attributes('communities' => '65000:1').first.communities)
  end

  def test_the_extended_text_round_trips
    ['route_target:65000:7', 'route_origin:10.0.0.1:3'].each do |t|
      assert_equal(t, K.extended_community_text(K.extended_community_hash(t)))
    end
  end

  def test_an_extended_community_without_a_value_is_refused
    assert_raise(ArgumentError) { K.extended_community_hash('65001') }
  end

  # The text form a spec, a node file and the injector's API take. Each
  # kind is built, written as text, read back and compared octet for
  # octet. Before, the reader split every value on ':' and kept what was
  # not an integer as a String: a one-value kind got a list and was
  # refused (encapsulation, origin_validation_state), a MAC was cut in
  # six, a float was refused, and "false" was a true sticky flag.
  # routescope's evpn-vxlan-frr lab met the first (routescope #299).
  ROUND_TRIPS = { color: 100, route_target: [65000, 7], route_origin: ['10.0.1.2', 10], source_as: 65000,
                  link_bandwidth: 999_999_999, ospf_domain_id: '1.2.3.4', ospf_router_id: '1.2.3.4',
                  bgp_data_collect: [100, 100], origin_validation_state: 1, encapsulation: 8,
                  traffic_rate_bytes: [10, 1000.0], traffic_rate_packets: [10, 1000.0], redirect: [10, 100],
                  mac_mobility: [5, false], es_import: 'aa:bb:cc:dd:ee:ff', router_mac: 'aa:bb:cc:dd:ee:ff' }.freeze

  def test_each_kind_round_trips_through_its_text
    ROUND_TRIPS.each do |kind, value|
      ec = BGP::Extended_communities.new(:extended_communities => [{ kind => value }])
      text = K.extended_community_text(ec.to_hash[:extended_communities].first)
      back = BGP::Extended_communities.new(:extended_communities => [K.extended_community_hash(text)])
      assert_equal ec.to_shex, back.to_shex, "#{kind}: #{text}"
    end
  end

  def test_an_encapsulation_by_number_or_by_name
    [8, 'vxlan'].each do |v|
      a = K.community_attributes('extended_communities' => ["encapsulation:#{v}"]).first
      assert_equal({ :encapsulation => :vxlan }, a.to_hash[:extended_communities].first, "encapsulation:#{v}")
    end
  end

  def test_false_is_false
    assert_equal({ :mac_mobility => [5, false] }, K.extended_community_hash('mac_mobility:5:false'))
    assert_equal({ :mac_mobility => [5, true] }, K.extended_community_hash('mac_mobility:5:true'))
  end

  def test_a_mac_stays_whole
    assert_equal({ :router_mac => 'aa:bb:cc:dd:ee:ff' }, K.extended_community_hash('router_mac:aa:bb:cc:dd:ee:ff'))
  end

end
