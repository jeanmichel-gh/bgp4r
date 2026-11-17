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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
#
# The ip answers are recorded, 2026-11-17: `ip -j route get` on pe1 of
# routescope's l3vpn-demo-isis (isisd with SR) and on f1 of isis's
# isis4r-sr (FRR 10.2.1), `ip -j link show` on a GRE device in a
# network namespace, iproute2 6.19.
class TestBgpRibVpnTransport < Test::Unit::TestCase

  ISISD_SR = '[{"dst":"10.255.0.3","encap":{"encap_type":"mpls","dst":"17003"},"gateway":"10.0.12.2","dev":"eth2","prefsrc":"10.0.12.1","flags":[],"uid":0,"cache":[]}]'
  ISISD_PHP = '[{"dst":"10.255.0.2","gateway":"10.0.12.2","dev":"eth2","prefsrc":"10.0.12.1","flags":[],"uid":0,"cache":[]}]'
  FRR_SR = '[{"dst":"10.255.0.4","encap":{"encap_type":"mpls","dst":"17004"},"gateway":"10.0.12.1","dev":"eth1","prefsrc":"10.0.12.2","flags":[],"uid":0,"cache":[]}]'
  CONNECTED = '[{"dst":"10.0.12.2","dev":"eth2","prefsrc":"10.0.12.1","flags":[],"uid":0,"cache":[]}]'
  TWO_LABELS = '[{"dst":"10.255.0.9","encap":{"encap_type":"mpls","dst":"17009/16101"},"gateway":"10.0.12.2","dev":"eth2","flags":[]}]'
  UNREACHABLE = "RTNETLINK answers: Network is unreachable\n"
  GRE_UP = '[{"ifindex":5,"ifname":"gre-pe2","flags":["POINTOPOINT","NOARP","UP","LOWER_UP"],"mtu":1476,"operstate":"UNKNOWN"}]'
  GRE_DOWN = '[{"ifindex":5,"ifname":"gre-pe2","flags":["POINTOPOINT","NOARP"],"mtu":1476,"operstate":"DOWN"}]'
  NO_DEVICE = "Device \"gre-pe9\" does not exist.\n"

  # A runner answering recorded output by command line.
  def runner(answers)
    @calls = []
    lambda do |argv|
      @calls << argv
      out, status = answers.fetch(argv.join(' ')) { ["no answer recorded for #{argv.join(' ')}", 1] }
      BGP::Rib::Fib::IpRoute::Result.new(argv, status, out)
    end
  end

  def transport(answers, **opts)
    BGP::Rib::VpnTransport.new(runner: runner(answers), **opts)
  end

  def test_mpls_takes_isisds_sr_label_and_its_gateway
    hop = transport({ 'ip -j route get 10.255.0.3' => [ISISD_SR, 0] }).resolve('10.255.0.3')
    assert(hop.ok?)
    assert_equal(['mpls', [17003], '10.0.12.2', 'eth2'], hop.to_a[0, 4])
  end

  def test_mpls_takes_frrs_too
    hop = transport({ 'ip -j route get 10.255.0.4' => [FRR_SR, 0] }).resolve('10.255.0.4')
    assert_equal([[17004], '10.0.12.1', 'eth1'], [hop.labels, hop.gateway, hop.dev])
  end

  # PHP: the far PE is the next router, so no transport label.
  def test_a_neighbors_loopback_has_no_label
    hop = transport({ 'ip -j route get 10.255.0.2' => [ISISD_PHP, 0] }).resolve('10.255.0.2')
    assert_equal([[], '10.0.12.2', 'eth2'], [hop.labels, hop.gateway, hop.dev])
  end

  # A next hop on a connected subnet: no gateway, so it is its own via.
  def test_a_connected_next_hop_is_its_own_via
    hop = transport({ 'ip -j route get 10.0.12.2' => [CONNECTED, 0] }).resolve('10.0.12.2')
    assert_equal([[], '10.0.12.2', 'eth2'], [hop.labels, hop.gateway, hop.dev])
  end

  def test_a_stack_of_labels_is_kept_top_first
    hop = transport({ 'ip -j route get 10.255.0.9' => [TWO_LABELS, 0] }).resolve('10.255.0.9')
    assert_equal([17009, 16101], hop.labels)
  end

  def test_no_route_is_an_unusable_next_hop
    hop = transport({ 'ip -j route get 10.255.0.99' => [UNREACHABLE, 2] }).resolve('10.255.0.99')
    assert(!hop.ok?)
    assert_equal('no route to 10.255.0.99: RTNETLINK answers: Network is unreachable', hop.error)
  end

  def test_a_tunnel_named_for_a_next_hop_is_used_whatever_the_default
    t = transport({ 'ip -j link show dev gre-pe2' => [GRE_UP, 0] }, tunnels: { '10.255.0.3' => 'gre-pe2' })
    hop = t.resolve('10.255.0.3')
    assert_equal(['gre', [], nil, 'gre-pe2'], hop.to_a[0, 4])
    assert(hop.ok?)
    assert_equal([%w[ip -j link show dev gre-pe2]], @calls, 'no route lookup for a tunnelled next hop')
  end

  def test_a_tunnel_that_is_down_or_missing_is_unusable
    t = transport({ 'ip -j link show dev gre-pe2' => [GRE_DOWN, 0], 'ip -j link show dev gre-pe9' => [NO_DEVICE, 1] },
                  tunnels: { '10.255.0.3' => 'gre-pe2', '10.255.0.9' => 'gre-pe9' })
    assert_equal('GRE tunnel gre-pe2 is down', t.resolve('10.255.0.3').error)
    assert_equal('GRE tunnel gre-pe9: Device "gre-pe9" does not exist.', t.resolve('10.255.0.9').error)
  end

  def test_gre_by_default_needs_a_tunnel_for_every_next_hop
    hop = transport({}, default: 'gre').resolve('10.255.0.3')
    assert_equal('no GRE tunnel is configured toward 10.255.0.3', hop.error)
  end

  # With no runner a real process runs: \`false\` exits 1, so the next
  # hop is unreachable, and an \`ip\` that is not there says so.
  def test_with_no_runner_the_command_runs
    assert_equal('no route to 10.255.0.3: ', BGP::Rib::VpnTransport.new(bin: 'false').resolve('10.255.0.3').error)
    assert_match(/\Ano route to 10.255.0.3: No such file or directory/,
                 BGP::Rib::VpnTransport.new(bin: '/nonexistent/ip').resolve('10.255.0.3').error)
  end

  def test_the_config_block
    t = BGP::Rib::VpnTransport.from_config({ 'transport' => 'gre', 'tunnels' => { '10.255.0.3' => { 'gre' => 'gre-pe2' } } })
    assert_equal(['gre', { '10.255.0.3' => 'gre-pe2' }], [t.default, t.tunnels])
    assert_equal('mpls', BGP::Rib::VpnTransport.from_config(nil).default)
    e = assert_raise(ArgumentError) { BGP::Rib::VpnTransport.from_config({ 'transport' => 'ldp' }) }
    assert_equal('l3vpn: transport is mpls or gre, not "ldp"', e.message)
    e = assert_raise(ArgumentError) { BGP::Rib::VpnTransport.from_config({ 'tunnels' => { '10.255.0.3' => 'gre-pe2' } }) }
    assert_equal('l3vpn: tunnels: 10.255.0.3: name the device, { gre: DEVICE }', e.message)
  end

  # --- IPv6, pull request 5: decision 6 -----------------------------------

  def test_a_mapped_next_hop_is_its_ipv4_address
    assert_equal('10.255.0.3', BGP::Rib::VpnTransport.unmap('::ffff:10.255.0.3'))
    assert_equal('10.255.0.3', BGP::Rib::VpnTransport.unmap('10.255.0.3'))
    assert_nil(BGP::Rib::VpnTransport.unmap('2001:db8::3'))
  end

  # Measured on l3vpn-lab: p1's eth1 and p2's eth1, MAC to link-local.
  def test_eui_64_from_a_mac
    assert_equal('fe80::a8c1:abff:fef2:d683', BGP::Rib::VpnTransport.eui64('aa:c1:ab:f2:d6:83'))
    assert_equal('fe80::a8c1:abff:fec6:25b7', BGP::Rib::VpnTransport.eui64('aa:c1:ab:c6:25:b7'))
    assert_equal('fe80::ff:fe00:1', BGP::Rib::VpnTransport.eui64('02:00:00:00:00:01'), 'the bit flipped back to 0')
  end
end
