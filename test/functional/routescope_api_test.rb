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
require 'json'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon'
require 'test/helpers/fake_isisd'
require 'test/functional/lab/routescope_vocabulary'

# bgp4rd's API holds what routescope reads from it:
# RoutescopeVocabulary::BGP4RD, copied from routescope's `rake
# vocabulary` (routescope docs/design/api-contract.md, part 3). So a
# change here that removes or renames a key routescope reads fails this
# test, before it merges, rather than a routescope panel after.
#
# Two bgp4rd on loopback, so every answer has rows: `r1` is the router
# under test, a BGP-LS Producer over a fake isisd, with a Loc-RIB, an
# Adj-RIB-Out and a forwarding table; `r2` sends it routes and collects
# its BGP-LS. The forwarding table has a fake backend that refuses one
# prefix, so `failed` has a row, and an originated prefix gives
# `skipped` one: an empty array would pass every key under it without
# reading one.
class BGP_Routescope_Api_Functional_Test < Test::Unit::TestCase

  PORT = 17_931
  R1 = '127.0.0.1'
  R2 = '127.0.0.2'
  CAPS = ['as4_byte', 'mbgp_ipv4_unicast', { 'mbgp' => 'bgp_ls' }].freeze
  REFUSED = '10.2.1.0/24'

  # The forwarding table's backend: every command works but REFUSED's.
  class Backend
    def run(op)
      ok = op.prefix.to_s != REFUSED
      BGP::Rib::Fib::IpRoute::Result.new(['ip', op.prefix.to_s], ok ? 0 : 2, ok ? '' : 'RTNETLINK answers: no')
    end

    def flush(ipv6: false)
      BGP::Rib::Fib::IpRoute::Result.new(['ip', 'flush', ipv6.to_s], 0, '')
    end

    def to_s ; 'fake backend' ; end
  end

  def ls_node(id, name, neighbors, prefix)
    { 'id' => id, 'hostname' => name, 'areas' => ['49.0001'], 'overload' => false,
      'attached' => false, 'reachable' => true,
      'neighbors' => neighbors.collect { |n| { 'id' => n, 'metric' => 10, 'style' => 'wide' } },
      'prefixes' => [{ 'prefix' => prefix, 'metric' => 0, 'up_down' => false, 'style' => 'wide' }] }
  end

  def setup
    @dir = Dir.mktmpdir
    a = '0000.0001.0101.00'
    b = '0000.0001.0102.00'
    @isisd = BGP::TestHelpers::FakeIsisd.new(
      1 => { 'level' => 1, 'run' => 1,
             'nodes' => [ls_node(a, 'a', [b], '10.200.0.1/32'), ls_node(b, 'b', [a], '10.200.0.2/32')] })
    @r1 = daemon('r1', 65_001, R1,
                 'listen_address' => R1, 'port' => PORT, 'export' => {},
                 'originate' => [{ 'prefixes' => ['10.1.0.0/24'] }],
                 'neighbors' => [{ 'address' => R2, 'as' => 65_002, 'description' => 'r2', 'capabilities' => CAPS }],
                 'link_state' => { 'isisd' => @isisd.path, 'levels' => [1], 'peers' => [R2] })
    @r2 = daemon('r2', 65_002, R2,
                 'local_address' => R2, 'export' => {},
                 'originate' => [{ 'prefixes' => ['10.2.0.0/24', REFUSED], 'med' => 5 }],
                 'neighbors' => [{ 'address' => R1, 'as' => 65_001, 'connect' => true, 'port' => PORT,
                                   'retry' => 1, 'capabilities' => CAPS }])
    @r1.speaker.rib.install(:backend => Backend.new)
    wait_for('r1 to learn both of r2\'s routes, install one and fail the other') do
      fib = call('show.fib')
      fib['total'].to_i >= 1 && !fib['fib']['failed'].empty? && !fib['fib']['skipped'].empty?
    end
    wait_for('r2 to hold r1\'s BGP-LS') { !call('show.link_state', {}, @r2)['rows'].empty? }
  end

  def teardown
    [@r2, @r1].each { |d| d.stop if d }
    @isisd.stop if @isisd
    FileUtils.remove_entry(@dir) if @dir
  end

  def daemon(name, as, router_id, extra)
    err = StringIO.new
    server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      { 'as' => as, 'router_id' => router_id, 'state_file' => File.join(@dir, "#{name}.json") }.merge(extra))
    assert_not_nil(server.build(config, :socket => File.join(@dir, "#{name}.sock")), "#{name} did not start: #{err.string}")
    server
  end

  # Through the socket, as routescope reads it, so the answer is JSON
  # with string keys and not the Ruby the views build.
  def call(method, params = {}, server = @r1)
    c = BGP::Daemon::Client.new(server.api.path)
    c.call(method, params)
  ensure
    c.close if c
  end

  def wait_for(what, timeout = 15)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      sleep 0.05
    end
  end

  # What each method takes, here, so it answers with rows.
  PARAMS = { 'show.adj_in' => { 'peer' => R2 }, 'show.adj_out' => { 'peer' => R2 } }.freeze

  # Where each key path is missing in +answer+, as messages. "a.b" is a
  # key under a key, "[]" every element of an array, and an array that is
  # empty where a path goes through it is itself a miss.
  def misses(answer, path, at = '')
    return [] if path.empty?
    head, rest = path.first, path.drop(1)
    if head == '[]'
      return ["#{at}: an array expected, #{answer.class} answered"] unless answer.is_a?(Array)
      return ["#{at}[]: empty, so nothing under it is shown"] if answer.empty? && !rest.empty?
      answer.each_with_index.flat_map { |e, i| misses(e, rest, "#{at}[#{i}]") }
    else
      return ["#{at}: an object expected, #{answer.class} answered"] unless answer.is_a?(Hash)
      return ["#{at}.#{head}: missing"] unless answer.key?(head)
      misses(answer[head], rest, "#{at}.#{head}")
    end
  end

  def split(path) = path.split('.').flat_map { |p| p.end_with?('[]') ? [p.chomp('[]'), '[]'].reject(&:empty?) : [p] }

  # Every read routescope makes answers, and every key it reads is there.
  #
  # routescope reads show.link_state in two shapes, a page ({rows: [...]})
  # and a bare array, from before bgp4rd paged it. Its copy lists the keys
  # of both, so the paths of the shape this bgp4rd answers are the ones
  # checked, and they must all be there.
  def test_every_read_routescope_makes_answers_with_the_keys_it_reads
    reads = RoutescopeVocabulary::BGP4RD.select { |m, _| m.start_with?('show.') }
    assert_equal(%w[show.adj_in show.adj_out show.fib show.link_state show.peers show.rib show.routes show.status],
                 reads.keys.sort)
    reads.each do |method, paths|
      answer = call(method, PARAMS.fetch(method, {}))
      shape = answer.is_a?(Array) ? paths.select { |p| p.start_with?('[]') } : paths.reject { |p| p.start_with?('[]') }
      assert(!shape.empty?, "#{method}: routescope reads none of the keys of the #{answer.class} it answers")
      shape.each { |p| assert_equal([], misses(answer, split(p)), "#{method} #{p}") }
    end
  end

  # The actions routescope sends, each with what a scenario or the panel
  # sends, answer rather than refuse. Their answers are not read.
  def test_every_action_routescope_sends_answers
    actions = RoutescopeVocabulary::BGP4RD.keys.reject { |m| m.start_with?('show.', 'events.') }
    sent = { 'route.originate' => { 'prefix' => '10.9.0.0/24' }, 'route.withdraw' => { 'prefix' => '10.9.0.0/24' },
             'peer.refresh' => { 'peer' => R2 }, 'peer.clear' => { 'peer' => R2 }, 'peer.stop' => { 'peer' => R2 },
             'peer.start' => { 'peer' => R2 }, 'link_state.unreachable' => { 'unreachable' => 'keep' } }
    assert_equal(sent.keys.sort, actions.sort, 'an action routescope sends that this test does not')
    sent.each do |method, params|
      assert_nothing_raised("#{method} #{params}") { call(method, params) }
    end
  end

  def test_api_info_lists_every_method_routescope_uses
    listed = call('api.info')['methods']
    assert_equal([], RoutescopeVocabulary::BGP4RD.keys - listed)
  end
end
