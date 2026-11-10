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
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon'
require 'test/helpers/fake_ospfd'

# Two bgp4rd on loopback, a BGP-LS Producer reading a fake ospfd and a
# collector: docs/design/bgp-ls-ospf.md, as link_state_daemon_test.rb
# does for isisd. The collector's `show.link_state` must equal the
# Producer's, apart from `peer` and `since`.
class BGP_LinkState_Ospf_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_918
  PRODUCER = '127.0.0.1'
  COLLECTOR = '127.0.0.2'
  CAPS = ['as4_byte', { 'mbgp' => 'bgp_ls' }].freeze

  O1 = '10.255.0.1'
  O2 = '10.255.0.2'
  O3 = '10.255.0.3'
  LAN = '10.255.0.2:10.0.23.1'

  def router(id, neighbors, prefixes, extra = {})
    { 'id' => id, 'kind' => 'router', 'reachable' => true, 'abr' => false, 'asbr' => false,
      'neighbors' => neighbors, 'prefixes' => prefixes }.merge(extra)
  end

  def pf(prefix, metric, type) ; { 'prefix' => prefix, 'metric' => metric, 'route_type' => type } ; end

  def setup
    @dir = Dir.mktmpdir
    @ospfd = BGP::TestHelpers::FakeOspfd.new(
      '0.0.0.0' => { 'area' => '0.0.0.0', 'nodes' => [
        router(O1, [{ 'id' => O2, 'type' => 'p2p', 'metric' => 10, 'address' => '10.0.12.1', 'remote_address' => '10.0.12.2' }],
               [pf('10.255.0.1/32', 0, 'intra')]),
        router(O2, [{ 'id' => O1, 'type' => 'p2p', 'metric' => 10, 'address' => '10.0.12.2', 'remote_address' => '10.0.12.1' }],
               [pf('10.255.0.2/32', 0, 'intra'), pf('10.0.23.0/24', 10, 'inter')], 'abr' => true)] },
      '0.0.0.1' => { 'area' => '0.0.0.1', 'nodes' => [
        router(O2, [{ 'id' => LAN, 'type' => 'transit', 'metric' => 10 }], [], 'abr' => true),
        router(O3, [{ 'id' => LAN, 'type' => 'transit', 'metric' => 10 }], [pf('10.255.0.3/32', 0, 'intra')], 'asbr' => true),
        { 'id' => LAN, 'kind' => 'network', 'reachable' => true, 'dr' => O2, 'address' => '10.0.23.1',
          'neighbors' => [{ 'id' => O2, 'metric' => 0 }, { 'id' => O3, 'metric' => 0 }],
          'prefixes' => [pf('10.0.23.0/24', 0, 'intra')] }] },
      'as' => { 'scope' => 'as', 'nodes' => [
        { 'id' => O3, 'kind' => 'router', 'reachable' => true,
          'prefixes' => [pf('192.0.2.0/24', 20, 'external_2').merge('forwarding' => '10.0.23.3', 'tag' => 0)] }] })
    @collector = daemon('collector', 65_002, COLLECTOR,
                        'listen_address' => COLLECTOR, 'port' => PORT,
                        'neighbors' => [{ 'address' => PRODUCER, 'as' => 65_001, 'capabilities' => CAPS }])
    @producer = daemon('producer', 65_001, PRODUCER,
                       'local_address' => PRODUCER,
                       'neighbors' => [{ 'address' => COLLECTOR, 'as' => 65_002, 'connect' => true,
                                         'port' => PORT, 'retry' => 1, 'capabilities' => CAPS }],
                       'link_state' => { 'ospfd' => @ospfd.path, 'areas' => ['0.0.0.0', '0.0.0.1'],
                                         'identifier' => 1, 'peers' => [COLLECTOR] })
  end

  def teardown
    [@producer, @collector].each { |d| d.stop if d }
    @ospfd.stop if @ospfd
    FileUtils.remove_entry(@dir) if @dir
  end

  def daemon(name, as, router_id, extra)
    err = StringIO.new
    server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      { 'as' => as, 'router_id' => router_id,
        'state_file' => File.join(@dir, "#{name}.json") }.merge(extra))
    assert_not_nil(server.build(config, :socket => File.join(@dir, "#{name}.sock")),
                   "#{name} did not start: #{err.string}")
    server
  end

  def show(server)
    c = BGP::Daemon::Client.new(server.api.path)
    c.call('show.link_state', 'limit' => 1000)
  ensure
    c.close if c
  end

  def wait_for(what, timeout = 10)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      sleep 0.05
    end
  end

  def routes(server)
    show(server)['rows'].collect { |r| r.reject { |k, _| %w[peer since].include?(k) } }
  end

  def same
    wait_for('the collector to hold what the Producer sent') do
      p = routes(@producer)
      !p.empty? && p == routes(@collector)
    end
  end

  def test_the_collector_holds_both_areas_and_the_externals
    same
    rows = show(@collector)['rows']
    assert_equal({ 'node' => 5, 'link' => 6, 'prefix' => 6 }, rows.collect { |r| r['type'] }.tally)
    assert_equal([3], rows.collect { |r| r['protocol_id'] }.uniq)
    o2 = rows.select { |r| r['type'] == 'node' && r['local'] == O2 }
    assert_equal([['0.0.0.0', ['abr']], ['0.0.0.1', ['abr']]], o2.collect { |r| r.values_at('area', 'flags') })
    lan = rows.find { |r| r['type'] == 'node' && r['local'] == LAN }
    assert_equal('0.0.0.1', lan['area'])
    ext = rows.find { |r| r['prefix'] == '192.0.2.0/24' }
    assert_equal([nil, O3, 'external_2', '10.0.23.3', 20], ext.values_at('area', 'local', 'route_type', 'forwarding', 'metric'))
  end

  def test_a_router_cut_off_is_withdrawn_at_the_collector
    same
    @ospfd.topology['0.0.0.0']['nodes'][0]['reachable'] = false
    @ospfd.changed('0.0.0.0')
    wait_for('o1 withdrawn') { show(@collector)['rows'].none? { |r| r['local'] == O1 } }
    same
    assert_equal(17 - 3, show(@collector)['total'])
  end
end
