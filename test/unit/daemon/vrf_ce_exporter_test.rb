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
require 'bgp/daemon'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
# What a PE in AS 65000 sends its CEs: docs/design/l3vpn-pe.md, pull
# request 7, "The design", step 5.
class TestBgpDaemonVrfCeExporter < Test::Unit::TestCase

  Installed = BGP::Rib::L3vpn::Installed

  # A CE neighbor, as the exporter sees one.
  class Ce
    attr_reader :address, :vrf, :remote_as, :sent
    attr_accessor :up, :as_override, :soo

    def initialize(address, vrf, remote_as, as_override: false, soo: nil)
      @address, @vrf, @remote_as, @as_override, @soo = address, vrf, remote_as, as_override, soo
      @up = true
      @sent = []
    end

    def established? ; @up ; end
    def local_ip ; '192.168.1.1' ; end
    def send_message(m) ; @sent << BGP::Update.new(m.encode) ; end

    # [:announce, prefix, as path, origin, next hop] and [:withdraw, prefix].
    def read
      @sent.flat_map do |u|
        w = u.withdrawn ? u.withdrawn.nlris.collect { |n| [:withdraw, n.to_hash[:prefix]] } : []
        pa = u.path_attribute
        a = u.nlri ? u.nlri.nlris.collect do |n|
          [:announce, n.to_hash[:prefix], pa[BGP::As_path].as_path.to_s, pa[BGP::Origin].to_i, pa[BGP::Next_hop].next_hop]
        end : []
        w + a
      end
    end
  end

  # L3vpn#installed, answered from a list.
  class Vrfs
    attr_accessor :routes
    def initialize ; @routes = Hash.new { |h, k| h[k] = [] } ; end
    def installed(vrf) ; @routes[vrf] ; end
  end

  Speaker = Struct.new(:peers, :my_as)

  def route(prefix, path, origin: 0)
    pa = BGP::Path_attribute.new(BGP::Origin.new(origin), BGP::As_path.new(*path), BGP::Next_hop.new('10.255.0.3'))
    BGP::Rib::Route.new(prefix, pa, BGP::Rib::Peer.new(:address => '10.255.0.3', :remote_as => 65000,
                                                       :router_id => '10.255.0.3', :local_as => 65000))
  end

  def setup
    @vrfs = Vrfs.new
    @ce1 = Ce.new('192.168.1.2', 'A', 65101, as_override: true, soo: '65000:11')
    @global = Ce.new('10.255.0.3', nil, 65000)
    @speaker = Speaker.new([@ce1, @global], 65000)
    @exporter = BGP::Daemon::VrfCeExporter.new(@speaker, @vrfs)
    # A VPN route from the far site, a CE route from ce1 itself, and one
    # from another CE of the VRF.
    @far = Installed.new('172.16.2.0/24', route('172.16.2.0/24', [65101]), nil, '65000:22')
    @own = Installed.new('172.16.1.0/24', route('172.16.1.0/24', [65101]), '192.168.1.2', '65000:11')
    @other = Installed.new('172.16.3.0/24', route('172.16.3.0/24', [65103], origin: 2), '192.168.3.2', nil)
    @v6 = Installed.new('2001:db8:2::/64', route('2001:db8:2::/64', []), nil, nil)
    @vrfs.routes['A'] = [@far, @own, @other, @v6]
  end

  # Our AS first (RFC 4271 section 5.1.2); with as_override the CE's own
  # AS becomes ours (RFC 4364 section 7). Not its own route, not IPv6.
  def test_a_ce_gets_its_vrf_with_our_as_and_as_override
    @exporter.refresh
    assert_equal([[:announce, '172.16.2.0/24', '65000 65000', 0, '192.168.1.1'],
                  [:announce, '172.16.3.0/24', '65000 65103', 2, '192.168.1.1']],
                 @ce1.read.sort_by { |o| o[1] })
    assert_equal([], @global.sent, 'a neighbor in the global table gets none of it')
  end

  def test_without_as_override_the_path_is_kept
    @ce1.as_override = false
    assert_equal('65000 65101'.split.collect(&:to_i), @exporter.routes_for(@ce1)['172.16.2.0/24'].as_path)
  end

  # RFC 4364 section 7: the Site of Origin stops a route going back into
  # its own site.
  def test_a_route_from_its_own_site_is_not_sent
    @far.soo = '65000:11'
    assert_equal(['172.16.3.0/24'], @exporter.routes_for(@ce1).keys)
  end

  def test_a_refresh_sends_the_difference_and_withdraws
    @exporter.refresh
    @ce1.sent.clear
    @exporter.refresh
    assert_equal([], @ce1.sent, 'nothing changed')
    @vrfs.routes['A'] = [@far, @own]
    @exporter.refresh
    assert_equal([[:withdraw, '172.16.3.0/24']], @ce1.read)
  end

  # A CE that went down forgets what it was sent, so it gets all of it
  # when it is back.
  def test_a_ce_that_comes_back_gets_everything
    @exporter.refresh
    @ce1.up = false
    @exporter.refresh
    @ce1.up = true
    @ce1.sent.clear
    @exporter.session_up(@ce1)
    assert_equal(%w[172.16.2.0/24 172.16.3.0/24], @ce1.read.collect { |o| o[1] }.sort)
  end
end
