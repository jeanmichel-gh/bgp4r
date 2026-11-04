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
end
