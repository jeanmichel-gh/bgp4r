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


$LOAD_PATH.unshift File.expand_path('../..', __dir__)
require 'test/unit'
require 'socket'
require 'stringio'
require 'tempfile'
require 'json'
require 'bgp/daemon'
begin
  require 'bfd4r'
  require 'bfd/client'
  require 'bfd/daemon/server'
  require 'bfd/daemon/client'
rescue LoadError => e
  # A failure and not an omission: a test of BFD that cannot load bfd4r
  # has measured nothing, and saying so is the point.
  raise LoadError, "#{e.message}: bfd4r is not on the load path. It is a path gem, " \
                   'Gemfile\'s ../bfd4r, so run this with bundle exec, or with ' \
                   'RUBYLIB pointing at a bfd4r checkout'
end

# bgp4rd's `bfd: true` against two real bfdd4r, over UDP on 127.0.0.1 and
# 127.0.0.2, in real time and with no root, as bfd4r's own
# test/functional/client_test.rb runs them. Ours is a Speaker on
# 127.0.0.1 with the real BFD::Client and the real `ip -j route get`; the
# far side is a BGP::Neighbor on 127.0.0.2 that records every
# NOTIFICATION it reads, and a bfdd4r of its own with the session in its
# file.
#
# **This is the only test that holds test/helpers/fake_bfd_client.rb to
# the real client**: every unit test in test/unit/daemon/bfd_test.rb
# reads events a fake made.
class BGP_Bfd_Functional_Test < Test::Unit::TestCase
  A = '127.0.0.1'
  B = '127.0.0.2'

  # The far BGP speaker: every connection it accepts is a session, and
  # every NOTIFICATION any of them reads is kept.
  class Far < BGP::Neighbor
    def initialize(log, *a)
      @log = log
      super(*a)
    end

    def rcv_notification(m)
      @log << m
      super
    end
  end

  def setup
    @tag = "bgp4r-bfd-#{Process.pid}-#{rand(1 << 30)}"
    @bfdd = {}
    @notifications = Queue.new
    @lines = Queue.new
    @server = TCPServer.new(B, 0)
    @port = @server.addr[1]
    @far = []
    @accept = Thread.new do
      loop do
        sock = @server.accept
        n = Far.new(@notifications, :my_as => 65_002, :id => '10.0.0.2',
                    :remote_addr => A, :local_addr => B, :holdtime => 9)
        n.capability :as4_byte
        @far << n
        Thread.new { n.start(:session => sock, :timeout => 10) rescue nil }
      end
    rescue IOError, SystemCallError
    end
  end

  def teardown
    @speaker&.stop
    @server.close rescue nil
    @accept.join(2)
    @far.each { |n| n.stop rescue nil }
    @bfdd.each_key { |name| stop_bfdd(name) }
  end

  def start_bfdd(name, sessions = [])
    file = Tempfile.create(%w[bfdd4r .yml])
    file.write(JSON.generate('socket' => "@#{@tag}-#{name}", 'sessions' => sessions))
    file.close
    stop = Thread::Queue.new
    thread = Thread.new do
      BFD::Daemon::Server.new(StringIO.new, StringIO.new).start(['-f', file.path, '--log', File::NULL], {}, stop: stop)
    end
    @bfdd[name] = [stop, thread]
    control = BFD::Daemon::Client.new("@#{@tag}-#{name}")
    assert(wait_until { control.call('api.info') rescue nil }, "bfdd4r #{name} answers")
    control
  ensure
    File.delete(file.path) if file
  end

  def stop_bfdd(name)
    stop, thread = @bfdd.delete(name)
    return unless stop
    stop.push(:stop)
    thread.join(5)
  end

  # Ours: one neighbor, the far side, active, with bfd: true.
  def start_speaker
    config = { 'as' => 65_001, 'router_id' => '10.0.0.1', 'local_address' => A,
               'neighbors' => [{ 'address' => B, 'as' => 65_002, 'connect' => true,
                                 'port' => @port, 'retry' => 1, 'hold_time' => 9, 'bfd' => true }] }
    client = BFD::Client.new('bgp4rd', socket: "@#{@tag}-a", retry_after: 0.1)
    @speaker = BGP::Daemon::Speaker.new(config, :bfd_client => client,
                                        :logger => ->(level, m) { @lines << [level, m] })
    @speaker.start
    @peer = @speaker.peer(B)
  end

  def bfd ; @speaker.bfd.state(B) ; end

  def both_up
    start_bfdd('b', [{ 'interface' => 'lo', 'peer' => A, 'local' => B }])
    start_bfdd('a')
    start_speaker
    assert(wait_until { @peer.established? }, 'the BGP session came up')
    assert(wait_until { bfd == 'up' }, "the BFD session came up, it is #{bfd}")
  end

  def wait_until(timeout = 10)
    deadline = Time.now + timeout
    sleep 0.02 until (v = yield) || Time.now > deadline
    v || yield
  end

  def lines
    out = []
    out << @lines.pop until @lines.empty?
    out
  end

  # The interface and local address came from the kernel's own answer,
  # and the session was asked for under bgp4rd's name.
  def test_the_session_is_asked_for_from_the_kernels_hop
    both_up
    rows = BFD::Daemon::Client.new("@#{@tag}-a").call('show.sessions')
    row = Array(rows).find { |r| r['peer'] == B }
    assert_not_nil(row, rows.inspect)
    assert_equal(['lo', A], [row['interface'], row['local']])
    assert_include(Array(row['clients']).map(&:to_s), 'bgp4rd') if row.key?('clients')
  end

  # The peer goes silent: its bfdd4r stops without a word, the Detection
  # Time expires, and the BGP session is reset with Cease 6/10 (RFC 9384
  # section 3) well before the 9 second hold time. BGP then comes back
  # without BFD, because it never waits for it.
  def test_a_failure_resets_the_session_with_cease_6_10
    both_up
    t0 = Time.now
    stop_bfdd('b')
    n = wait_until(5) { @notifications.empty? ? nil : @notifications.pop }
    took = Time.now - t0
    assert_not_nil(n, "no NOTIFICATION reached the peer; log: #{lines.inspect}")
    assert_equal([6, 10], n.to_hash.values_at(:code, :subcode))
    assert_operator(took, :<, 3, 'reset by BFD and not by the hold timer')
    assert_equal('down', bfd)
    assert_match(/BFD Down/, @peer.recorder.snapshot.to_s)
    assert(wait_until { @peer.established? }, 'BGP came back with BFD down: it never waits for BFD')
  end

  # RFC 5882 section 4.2: the peer's AdminDown is not acted on.
  def test_the_peers_admin_down_keeps_the_session
    b = nil
    both_up
    b = BFD::Daemon::Client.new("@#{@tag}-b")
    b.call('session.admin', 'interface' => 'lo', 'peer' => A, 'down' => true)
    assert(wait_until { bfd == 'admin_down' }, "it is #{bfd}")
    sleep 1.5
    assert(@notifications.empty?, 'no NOTIFICATION')
    # A cleared session redials within the second above and sends no
    # NOTIFICATION, so established? alone cannot see it: the flap count
    # can. Proved by sabotage, which passed before this line.
    assert_equal(0, @peer.recorder.flaps, 'the BGP session did not flap')
    assert_equal(true, @peer.established?)
  end

  # bfdd4r goes away: the BGP session stays, and the loss is logged.
  def test_losing_bfdd4r_keeps_the_session
    both_up
    stop_bfdd('a')
    assert(wait_until { lines.any? { |l, m| l == :warn && m =~ /bfd: .*kept/ } }, 'the loss is logged')
    sleep 1.5
    assert(@notifications.empty?, 'no NOTIFICATION')
    # A cleared session redials within the second above and sends no
    # NOTIFICATION, so established? alone cannot see it: the flap count
    # can. Proved by sabotage, which passed before this line.
    assert_equal(0, @peer.recorder.flaps, 'the BGP session did not flap')
    assert_equal(true, @peer.established?)
  end
end
