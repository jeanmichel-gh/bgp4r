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
require 'test/helpers/fake_isisd'

# Two bgp4rd on loopback, a BGP-LS Producer and a collector, with a fake
# isisd under the Producer: docs/design/bgp-ls-producer.md's gate. The
# collector's `show.link_state` must equal the Producer's, apart from
# `peer` and `since`, after the first read, after a change and after
# the session comes back.
class BGP_LinkState_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_917
  PRODUCER = '127.0.0.1'
  COLLECTOR = '127.0.0.2'
  CAPS = ['as4_byte', { 'mbgp' => 'bgp_ls' }].freeze

  R1 = '0000.0001.0101.00'
  R2 = '0000.0001.0102.00'
  R3 = '0000.0001.0103.00'

  def node(id, name, neighbors, prefix)
    { 'id' => id, 'hostname' => name, 'areas' => ['49.0001'], 'overload' => false,
      'attached' => false, 'reachable' => true,
      'neighbors' => neighbors.collect { |n| { 'id' => n, 'metric' => 10, 'style' => 'wide' } },
      'prefixes' => [{ 'prefix' => prefix, 'metric' => 0, 'up_down' => false, 'style' => 'wide' }] }
  end

  def setup
    @dir = Dir.mktmpdir
    @isisd = BGP::TestHelpers::FakeIsisd.new(
      1 => { 'level' => 1, 'run' => 1,
             'nodes' => [node(R1, 'r1', [R2], '10.200.0.1/32'),
                         node(R2, 'r2', [R1, R3], '10.200.0.2/32'),
                         node(R3, 'r3', [R2], '10.200.0.3/32')] })
    @collector = daemon('collector', 65_002, COLLECTOR,
                        'listen_address' => COLLECTOR, 'port' => PORT,
                        'neighbors' => [{ 'address' => PRODUCER, 'as' => 65_001, 'capabilities' => CAPS }])
    @producer = daemon('producer', 65_001, PRODUCER,
                       'local_address' => PRODUCER,
                       'neighbors' => [{ 'address' => COLLECTOR, 'as' => 65_002, 'connect' => true,
                                         'port' => PORT, 'retry' => 1, 'capabilities' => CAPS }],
                       'link_state' => { 'isisd' => @isisd.path, 'levels' => [1], 'peers' => [COLLECTOR] })
  end

  def teardown
    [@producer, @collector].each { |d| d.stop if d }
    @isisd.stop if @isisd
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

  # The rows without the two columns that differ by design: `peer` is
  # null on the Producer, and `since` is when each side saw the route.
  def routes(server)
    show(server)['rows'].collect { |r| r.reject { |k, _| %w[peer since].include?(k) } }
  end

  def same
    wait_for('the collector to hold what the Producer sent') do
      p = routes(@producer)
      !p.empty? && p == routes(@collector)
    end
  end

  def test_the_collector_holds_what_the_producer_sent
    same
    rows = show(@collector)['rows']
    assert_equal(10, rows.size)
    assert_equal([PRODUCER], rows.collect { |r| r['peer'] }.uniq)
    assert_equal([nil], show(@producer)['rows'].collect { |r| r['peer'] }.uniq)
    assert_equal({ 'node' => 3, 'link' => 4, 'prefix' => 3 }, rows.collect { |r| r['type'] }.tally)
    r1 = rows.find { |r| r['type'] == 'node' && r['name'] == 'r1' }
    assert_equal([R1, ['49.0001'], []], [r1['local'], r1['areas'], r1['flags']])
  end

  def test_a_change_in_the_igp_reaches_the_collector
    same
    nodes = @isisd.topology[1]['nodes']
    nodes[0]['neighbors'].clear
    nodes[1]['neighbors'].reject! { |n| n['id'] == R1 }
    nodes[2]['overload'] = true
    @isisd.spf(1)
    wait_for('two links fewer') { show(@collector)['total'] == 8 }
    same
    r3 = show(@collector)['rows'].find { |r| r['name'] == 'r3' }
    assert_equal(['overload'], r3['flags'])
  end

  def test_a_session_that_comes_back_gets_the_whole_set
    same
    @producer.speaker.peer(COLLECTOR).clear
    wait_for('the session to come back and the set to be sent again') do
      @collector.speaker.peer(PRODUCER).recorder.data['established_count'] >= 2 &&
        show(@collector)['total'] == 10
    end
    same
  end
end
