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
require 'socket'
require 'stringio'
require 'bgp/sim'
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# The graceful restart matrix against bgp4rd: the eleven `gr_`
# behaviours of `BGP::Fault::BEHAVIOURS` and the two `BGP::Fault::GR`
# cases, each run by a real bgp4r-sim on a session of its own, and what
# bgp4rd did beside what the RFC expects. A library Neighbor from
# 127.0.0.3 watches what bgp4rd sends on: a route kept stale is not
# withdrawn from it. docs/design/bgp-operations.md section 3, pull
# request 3c.
class TestGrFaultMatrix < Test::Unit::TestCase

  class Catcher
    attr_reader :withdrawn
    def initialize ; @withdrawn = Queue.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      msg.withdrawn.to_ary.each { |p| @withdrawn << p.to_s } if msg.withdrawn
    end
  end

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16].freeze
  # What the sim does not send again after it comes back.
  DROP = '10.2.0.0/16'

  # What bgp4rd did with each behaviour, from what the watcher saw
  # withdrawn: :kept when only DROP went (kept stale, then purged as
  # the case says), :flushed when both did.
  BGP4RD_DID = {
    :gr_restart                => :kept,
    :gr_restart_no_f           => :flushed,
    :gr_restart_family_missing => :flushed,
    :gr_never_back             => :flushed,
    :gr_no_eor                 => :kept,
    :gr_new_connection         => :kept,
    :gr_consecutive            => :flushed,
    :gr_consecutive_n          => :kept,
    :gr_graceful_cease         => :kept,
    :gr_hard_reset             => :flushed,
    :gr_notification_no_n      => :flushed,
  }.freeze

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
  end

  def teardown
    @watcher&.stop rescue nil
    @sim&.stop
    @sp&.stop
    @watcher = @sim = @sp = @seen = nil
  end

  # bgp4rd helping 127.0.0.2, with N when n; bgp4r-sim there with a GR
  # capability for IPv4 unicast, N in it when sim_n, its Restart Time
  # restart_time; the watcher at 127.0.0.3.
  # sim: more of the sim's config, such as `announce` blocks or
  # neighbor keys under 'neighbor'.
  def start(n: false, sim_n: n, restart_time: 120, stale_time: 180, sim: {})
    port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => port, 'log_level' => 'error',
                                   'export' => { 'next_hops' => { 1 => '192.0.2.1' } },
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                     'graceful_restart' => { 'restart_time' => 0, 'stale_time' => stale_time,
                                                                             'notification' => n } },
                                                   { 'address' => '127.0.0.3', 'as' => 65_003 }]).start
    @notified = Queue.new
    @sp.events.on_event { |e| @notified << e.data if e.kind == :notification && e.data[:direction] == 'send' }
    @watcher = BGP::Neighbor.new(:my_as => 65_003, :remote_addr => '127.0.0.1', :id => '127.0.0.3')
    @watcher.capability :as4_byte
    @catcher = Catcher.new
    @watcher.add_observer(@catcher)
    sock = Socket.tcp('127.0.0.1', port, '127.0.0.3')
    Thread.new { @watcher.start(:session => sock, :timeout => 5) rescue nil }
    flags = sim_n ? BGP::Sim::GracefulRestartBehaviour::N_BIT : 0
    neighbor = { 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true, 'port' => port, 'retry' => 0.2,
                 'capabilities' => ['as4_byte', { 'graceful_restart' => [flags, restart_time, [1, 1, 0x80]] }] }
    @sim = BGP::Sim::Injector.new({ 'router_id' => '10.0.0.2', 'as' => 65_001, 'local_address' => '127.0.0.2',
                                    'neighbors' => [neighbor.merge(sim.delete('neighbor') || {})] }.merge(sim))
    @done = Queue.new
    @sim.speaker.events.on_event { |e| @done << e.data['behaviour'] if e.kind == :log && e.message.to_s.include?('done on') }
    @sim.start
    assert_equal(true, wait_until(10) { @sim.speaker.peers.first.established? && @watcher.is_established? }, 'both up')
    @sim.act('announce', 'prefixes' => ROUTES, 'next_hop' => '127.0.0.2')
    want = ROUTES.size + Array(sim['announce']).sum { |a| a['prefixes'].size }
    assert_equal(true, wait_until(5) { adj_in.size == want }, 'the routes came')
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # The peer's Adj-RIB-In as { prefix => stale reason or nil }.
  def adj_in
    BGP::Daemon::Views.new(@sp).adj_in('peer' => '127.0.0.2')[:rows].to_h { |r| [r[:prefix], r[:stale]] }
  end

  # Everything withdrawn from the watcher so far.
  def withdrawn
    @seen ||= []
    @seen << @catcher.withdrawn.pop until @catcher.withdrawn.empty?
    @seen.uniq.sort
  end

  def outcome(list)
    return :kept if list == [DROP]
    return :flushed if list == ROUTES
    list
  end

  # Runs one behaviour and waits for its thread, then for settle.
  def behave(name, settle: 0.5, **body)
    @sim.act('behaviour', { 'name' => name.to_s, 'drop' => [DROP], 'away' => 0.5 }.merge(body.transform_keys(&:to_s)))
    assert_equal(name.to_s, @done.pop(:timeout => 30), "#{name} ran to its end")
    sleep settle
  end

  def needs(name) ; BGP::Fault.behaviour_catalog.find { |b| b[:name] == name }[:needs] ; end

  # Each behaviour that comes back, with the N bit as it needs. Each
  # ends with the session up, its routes there and DROP gone.
  def test_every_behaviour_that_comes_back
    got = {}
    (BGP4RD_DID.keys - %i[gr_never_back gr_no_eor]).each do |name|
      n = needs(name) == :n
      start(n: n)
      behave(name)
      wait_until(2) { outcome(withdrawn) == BGP4RD_DID[name] }
      got[name] = outcome(withdrawn)
      assert_equal({ '10.1.0.0/16' => nil }, adj_in, "#{name}: back, fresh, and #{DROP} gone")
      assert_nil(@notified.pop(:timeout => 0), "#{name}: bgp4rd sent no NOTIFICATION")
      assert_nil(@sim.speaker.peers.first.instance_variable_get(:@next_session), "#{name}: the change was for one session")
      teardown
    end
    assert_equal(BGP4RD_DID.reject { |k, _| %i[gr_never_back gr_no_eor].include?(k) }, got)
  end

  # RFC 4724 section 4.2: the Restart Time, here the sim's 2 s, and the
  # stale routes go.
  def test_gr_never_back
    start(restart_time: 2)
    t0 = Time.now
    behave(:gr_never_back, settle: 0)
    kept = { '10.1.0.0/16' => 'restart', '10.2.0.0/16' => 'restart' }
    assert_equal(true, wait_until(1) { adj_in == kept }, "kept stale while away: #{adj_in}")
    assert_equal([], withdrawn)
    assert_equal(true, wait_until(5) { adj_in.empty? }, 'removed')
    assert_operator(Time.now - t0, :>=, 2, 'at the Restart Time')
    assert_equal(true, wait_until(2) { outcome(withdrawn) == :flushed }, "withdrawn: #{withdrawn}")
  end

  # RFC 8538 section 4.1: back, no End-of-RIB; what was not sent again
  # stays stale until the stale timer, here 2 s.
  def test_gr_no_eor
    start(stale_time: 2)
    behave(:gr_no_eor, settle: 0)
    assert_equal(true, wait_until(3) { adj_in == { '10.1.0.0/16' => nil, DROP => 'restart' } }, "#{DROP} still stale: #{adj_in}")
    assert_equal([], withdrawn)
    assert_equal(true, wait_until(4) { adj_in == { '10.1.0.0/16' => nil } }, 'removed at the stale timer')
    assert_equal(true, wait_until(2) { outcome(withdrawn) == :kept }, "withdrawn: #{withdrawn}")
  end

  # The first time back is quiet, so the routes are still stale when it
  # drops again: without N they go at that second drop (RFC 4724
  # section 4.2), with N they stay (RFC 8538 section 4.1).
  def test_consecutive_restarts_with_and_without_n
    { false => 'gone', true => 'kept' }.each do |n, word|
      # A node file's own route too, which a quiet session holds back
      # as well.
      start(n: n, sim: { 'announce' => [{ 'prefixes' => ['10.3.0.0/16'], 'next_hop' => '127.0.0.2' }] })
      name = n ? 'gr_consecutive_n' : 'gr_consecutive'
      @sim.act('behaviour', 'name' => name, 'away' => 1)
      assert_equal(true, wait_until(5) { @sim.speaker.peers.first.quiet? && @sim.speaker.peers.first.established? },
                   'back quiet the first time')
      sleep 0.3
      assert_equal(%w[restart] * 3, adj_in.values, 'nothing sent again, so all three still stale')
      assert_equal(true, wait_until(5) { !@sim.speaker.peers.first.established? }, 'and down again')
      sleep 0.3
      assert_equal(n ? 3 : 0, adj_in.size, "stale routes #{word} at the second drop")
      assert_equal(name, @done.pop(:timeout => 10))
      teardown
    end
  end

  # RFC 4724 section 4.2's second connection: bgp4rd closes the old one
  # with no NOTIFICATION. The sim's peer counts two sessions.
  def test_gr_new_connection_closes_the_old_session
    start
    peer = @sim.speaker.peers.first
    first = peer.neighbor
    count = peer.recorder.snapshot['established_count']
    behave(:gr_new_connection, 'drop' => [])
    refute(peer.neighbor.equal?(first), 'a new session')
    sleep 1
    assert_equal(count + 1, peer.recorder.snapshot['established_count'], 'one, and no third connection after it')
    assert_equal('established', BGP::Daemon::Views.new(@sp).peers.first[:state].to_s)
    assert_equal({ '10.1.0.0/16' => nil, DROP => nil }, adj_in)
    assert_equal([], withdrawn, 'nothing withdrawn')
  end

  # A peer that keeps its old session, as bgp4rd does when it does not
  # help: redial gives the new connection up after open_timeout, and the
  # old session goes on.
  def test_redial_gives_up_when_the_old_session_stays
    port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'listen_address' => '127.0.0.1',
                                   'port' => port, 'log_level' => 'error',
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001 }]).start
    @sim = BGP::Sim::Injector.new('router_id' => '10.0.0.2', 'as' => 65_001, 'local_address' => '127.0.0.2',
                                  'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65_000, 'connect' => true,
                                                    'port' => port, 'retry' => 0.2, 'open_timeout' => 1 }])
    @sim.start
    peer = @sim.speaker.peers.first
    assert_equal(true, wait_until(10) { peer.established? }, 'up')
    first = peer.neighbor
    peer.redial.join(5)
    assert_equal('redial: the old session was not closed by the peer', peer.recorder.snapshot['last_error'])
    assert_equal(true, peer.neighbor.equal?(first) && peer.established?, 'the old session goes on')
  end

  # RFC 8538 section 3.2: a Hard Reset bgp4rd cannot read inside still
  # ends the session, routes and all.
  def test_every_gr_case
    got = {}
    BGP::Fault.gr_catalog.each do |c|
      start(n: c[:n])
      @sim.act('fault', 'case' => c[:name].to_s)
      assert_equal(true, wait_until(3) { adj_in.empty? }, "#{c[:name]}: flushed")
      wait_until(2) { outcome(withdrawn) == :flushed }
      got[c[:name]] = outcome(withdrawn)
      teardown
    end
    assert_equal({ :hard_reset_empty => :flushed, :hard_reset_unknown_inner => :flushed }, got)
  end
end
