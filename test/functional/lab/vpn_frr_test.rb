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
require 'bgp4r'
require 'bgp/daemon'
require 'test/functional/lab/lab_helper'

# VPN-IPv4, AFI 1 SAFI 128, both ways against FRR's bgpd:
# docs/design/l3vpn-pe.md, pull request 4, "Interop".
#
# **What bgp4r sends is built by bgp4rd's own exporter**,
# Daemon::VpnExporter#updates, so FRR reads the UPDATEs a PE sends and
# not ones written for the test. **What FRR sends is read by bgp4rd's own
# VPN table**, Rib::VpnTable#attach, the path a PE's session takes.
#
# One iBGP session, AS 65000 both ends, as between two PEs. No Docker and
# no zebra, so no VRF on FRR's side: it sends VPN routes from its static
# `network ... rd ... label` form (LabHelper::Frr's vpn_networks). The
# full PE, VRFs and the kernel, is `routescope/labs/l3vpn-lab`.
class VpnFrrTest < Test::Unit::TestCase
  AS = 65000

  F = LabHelper::Frr
  Export = BGP::Rib::L3vpn::Export

  # Measured against 10.5.1 on the owner's VM on 2026-11-17, the version
  # ubuntu-latest installs in CI. 8.4.4 was not measured.
  MEASURED = (10..10).freeze

  # The exporter's view of the session: iBGP, so LOCAL_PREF and an
  # empty AS_PATH.
  Session = Struct.new(:address) do
    def ebgp? ; false ; end
    def local_ip ; '127.0.0.1' ; end
  end
  Speaker = Struct.new(:peers, :my_as, :local_address)

  def setup
    unless F.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    major = F.major
    unless F.measured?(MEASURED, major)
      omit("measured against FRR #{MEASURED}, found #{major.inspect}: re-measure before asserting")
    end
    @listeners = []
    @routers = []
    # The next hop FRR keeps: see F::NEXT_HOP. A PE's would be its loopback.
    @exporter = BGP::Daemon::VpnExporter.new(Speaker.new([], AS, F::NEXT_HOP))
  end

  def teardown
    @routers.each(&:down)
    puts "\n== bgpd\n#{@routers.collect(&:log).join}" unless passed?
    @listeners.each do |server, neighbor, thread|
      thread.kill if thread
      neighbor.close
      server.close unless server.closed?
    end
  rescue IOError, SystemCallError
  end

  # A library Neighbor offering AFI 1 / SAFI 128, a VpnTable reading it,
  # and FRR dialling in.
  def session(vpn_networks: [])
    server = TCPServer.new('127.0.0.1', 0)
    n = BGP::Neighbor.new(4, AS, 180, '0.0.0.1', '127.0.0.2', '127.0.0.1')
    n.add_cap BGP::OPT_PARM::CAP::Mbgp.new(1, 128)
    @table = BGP::Rib::VpnTable.new(local_as: AS, router_id: '0.0.0.1')
    @table.attach(n)
    thread = Thread.new do
      begin
        while (s = server.accept)
          n.start_session(s)
        end
      rescue IOError, SystemCallError
      end
    end
    @listeners << [server, n, thread]
    router = F.new(:local => '127.0.0.2', :as => AS, :router_id => '10.0.0.2', :peer => '127.0.0.1',
                   :peer_as => AS, :port => server.addr[1], :families => [F::VPN],
                   :vpn_networks => vpn_networks)
    @routers << router
    router.up
    assert(wait_for { n.is_established? }, "the session came up\n#{router.log}")
    [n, router]
  end

  def wait_for(timeout = 30)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.2
    end
  end

  def send_vpn(n, announced, withdrawn = [])
    @exporter.updates(Session.new('127.0.0.2'), announced, withdrawn).each { |u| n.send_message(u) }
  end

  A = Export.new('A', '65000:1', '192.168.1.0/24', 24000, ['65000:100'])
  B = Export.new('B', '65000:2', '192.168.1.0/24', 24001, ['65000:200'])

  # RFC 4364 section 4.1: one prefix under two RDs is two routes. Section
  # 4.3.2: the label and the Route Targets ride with each.
  def test_frr_reads_what_a_pe_sends
    n, router = session
    send_vpn(n, [A, B])
    keys = nil
    assert(wait_for { (keys = router.vpn_keys) && keys.size == 2 }, "FRR holds #{keys.inspect}\n#{router.log}")
    assert_equal([['65000:1', '192.168.1.0/24'], ['65000:2', '192.168.1.0/24']], keys)
    a, b = router.vpn_path('65000:1', '192.168.1.0/24'), router.vpn_path('65000:2', '192.168.1.0/24')
    assert_equal([24000, 'RT:65000:100', F::NEXT_HOP, 100, true],
                 [a['remoteLabel'], a['extendedCommunity']['string'], a['nexthops'].first['ip'], a['locPrf'], a['valid']])
    assert_equal([24001, 'RT:65000:200'], [b['remoteLabel'], b['extendedCommunity']['string']])
  end

  # RFC 8277 section 2.4: the withdrawal's label field is 0x800000, and
  # FRR withdraws the route under that RD alone.
  def test_a_withdrawal_removes_that_rd_only
    n, router = session
    send_vpn(n, [A, B])
    assert(wait_for { router.vpn_keys&.size == 2 }, router.log)
    send_vpn(n, [], [A])
    assert(wait_for { router.vpn_keys == [['65000:2', '192.168.1.0/24']] },
           "FRR holds #{router.vpn_keys.inspect}\n#{router.log}")
  end

  # The other way: FRR's VPN route, read by bgp4rd's VPN table.
  def test_bgp4r_reads_what_frr_sends
    _, router = session(vpn_networks: [{ :prefix => '10.9.0.0/16', :rd => '65000:9', :label => 3001, :rt => '65000:300' },
                                       { :prefix => '10.9.0.0/16', :rd => '10.0.0.2:7', :label => 3002, :rt => '65000:301' }])
    assert(wait_for { @table.size == 2 }, "bgp4r holds #{@table.size}\n#{router.log}")
    rows = @table.rows.collect { |r| r.values_at('rd', 'prefix', 'labels', 'route_targets', 'next_hop', 'local_pref', 'best') }
    assert_equal([['10.0.0.2:7', '10.9.0.0/16', [3002], ['65000:301'], '127.0.0.2', 100, true],
                  ['65000:9', '10.9.0.0/16', [3001], ['65000:300'], '127.0.0.2', 100, true]], rows)
  end
end
