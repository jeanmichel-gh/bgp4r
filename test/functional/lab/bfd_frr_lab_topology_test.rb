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
require 'yaml'
require 'json'
require 'stringio'
require 'bgp4r'
require 'bgp/daemon'

# routescope/labs/bfd-frr-lab read out of its own files, with no Docker,
# no router and no socket, so it runs anywhere and in the `local` group.
# CI deploys the lab and runs its gate.sh (.github/workflows/capture.yml);
# this is the cover its files have on every pull request.
class LabBfdFrrLabTopologyTest < Test::Unit::TestCase

  ROOT = File.expand_path('../../..', __dir__)
  DIR = File.join(ROOT, 'routescope/labs/bfd-frr-lab')
  Result = BGP::Rib::Fib::IpRoute::Result

  def read(rel, dir = DIR) ; File.read(File.join(dir, rel), :encoding => 'UTF-8') ; end
  def clab ; @clab ||= YAML.safe_load(read('bfd-frr-lab.clab.yml')) ; end
  def nodes ; clab['topology']['nodes'] ; end

  def node_file
    err = StringIO.new
    c = BGP::Daemon::Server.new(StringIO.new, err).load_config(:config => File.join(DIR, 'bgp', 'bgp4rd.yml'))
    assert_not_nil(c, err.string)
    BGP::Daemon::Server.with_defaults(c)
  end

  # `ip -j route get` as the bgp node answers it, once eth1 has its
  # address, and before, through the management network's gateway.
  def runner(one_hop)
    lambda do |argv|
      route = { 'dst' => argv.last, 'dev' => 'eth1', 'prefsrc' => '10.0.12.1' }
      route = route.merge('gateway' => '172.20.20.1', 'dev' => 'eth0') unless one_hop
      Result.new(argv, 0, JSON.generate([route]))
    end
  end

  def test_two_nodes_one_link
    assert_equal(%w[bgp frr], nodes.keys.sort)
    assert_equal([%w[bgp:eth1 frr:eth1]], clab['topology']['links'].map { |l| l['endpoints'] })
    assert_equal('bgp4r-lab:latest', nodes['bgp']['image'])
    assert_equal('quay.io/frrouting/frr:10.2.1', nodes['frr']['image'])
    assert_equal('bgp4r', nodes['bgp']['labels']['routescope.kind'])
    assert_equal('frr', nodes['frr']['labels']['routescope.kind'])
  end

  # bfdd4r runs beside bgp4rd because the entrypoint is with-bfdd4r, which
  # the image sets and this node repeats because its cmd is a shell.
  def test_bgp_runs_with_bfdd4r_and_starts_once_eth1_has_its_address
    bgp = nodes['bgp']
    assert_equal('with-bfdd4r', bgp['entrypoint'])
    assert_equal(['ip addr add 10.0.12.1/30 dev eth1'], bgp['exec'])
    assert_match(%r{until ip -4 -o addr show dev eth1 2>/dev/null \| grep -q 10\.0\.12\.1/30}, bgp['cmd'])
    assert_match(%r{exec ruby -I/app /app/exe/bgp4rd -f /etc/bgp4r/bgp4rd.yml -s /run/bgp4r/bgp4rd.sock}, bgp['cmd'])
    lab_node = read('Dockerfile', ROOT)[/^FROM speaker AS lab-node$.*?^FROM /m]
    assert_match(/^ENTRYPOINT \["with-bfdd4r", "ruby", "-I\/app"\]$/, lab_node)
    assert_match(/^COPY --from=bfd4r bfd\/ \/bfd4r\/bfd\/$/, lab_node)
    assert_match(/^COPY --from=bfd4r exe\/ \/bfd4r\/exe\/$/, lab_node)
  end

  # The node file builds a Speaker once the neighbor is one hop away, and
  # is refused before: which is why the cmd waits for the address.
  def test_the_node_file_wants_bfd_and_needs_the_wait
    c = node_file
    n = c['neighbors'].find { |x| x['address'] == '10.0.12.2' }
    assert_equal([65_002, true, true], n.values_at('as', 'bfd', 'connect'))
    s = BGP::Daemon::Speaker.new(c, :bfd_runner => runner(true), :bfd_client => Object.new)
    assert_equal(true, s.peer('10.0.12.2').bfd?)
    e = assert_raise(ArgumentError) { BGP::Daemon::Speaker.new(c, :bfd_runner => runner(false)) }
    assert_match(/bfd needs a neighbor one hop away/, e.message)
  end

  def test_frr_runs_bfdd_and_asks_for_bfd_toward_bgp
    assert_match(/^bfdd=yes$/, read('frr/daemons'))
    conf = read('frr/frr.conf')
    assert_match(/^router bgp 65002$/, conf)
    assert_match(/^ neighbor 10\.0\.12\.1 remote-as 65001$/, conf)
    assert_match(/^ neighbor 10\.0\.12\.1 bfd$/, conf)
    assert_equal(65_001, node_file['as'])
    assert_match(/^ ip address 10\.0\.12\.2\/30$/, conf)
  end

  # The gate checks what the design asks: Up on both, then a reset in
  # under a second with 6/10 sent, and it fails the run when it does not.
  def test_the_gate_checks_the_reset_and_exits_on_a_failure
    gate = read('gate.sh')
    assert_match(/grep -m1 'Cease 6\/10 BFD Down sent'/, gate)
    assert_match(/to_f < 1\.0/, gate)
    assert_match(/check "bgp4rd: reset within 100 ms of bfdd4r's detection/, gate)
    assert_match(/tc qdisc replace dev eth1 root netem loss 100%/, gate)
    assert_match(/^exit "\$FAILED"$/, gate)
    # And that line is the one bgp/daemon/bfd.rb writes.
    assert_match(/Cease 6\/10 BFD Down sent/, read('bgp/daemon/bfd.rb', ROOT))
  end

  def test_ci_deploys_it_and_runs_its_gate
    wf = read('.github/workflows/capture.yml', ROOT)
    job = wf[/^  bfd-frr-lab:$.*\z/m]
    assert_not_nil(job, 'capture.yml has a bfd-frr-lab job')
    assert_match(/--build-context bfd4r=\.\.\/bfd4r/, job)
    assert_match(%r{bash routescope/labs/bfd-frr-lab/gate\.sh}, job)
  end

  def test_about_says_it_is_the_interop_check
    about = read('ABOUT.md')
    front = YAML.safe_load(about[/\A---\n(.*?)\n---\n/m, 1])
    assert_equal('interop', front['role'])
    assert_include(front['tags'], 'bfd')
    %w[bgp frr].each { |n| assert_match(/`#{n}`/, about) }
  end
end
