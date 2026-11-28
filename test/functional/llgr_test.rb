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
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# Long-lived graceful restart, RFC 9494, through a real Speaker over
# loopback. A library Neighbor from 127.0.0.2 is the peer that restarts,
# with GR and LLGR for IPv4 unicast; a stop of its own is a TCP close,
# which is a restart to bgp4rd. Three more watch what bgp4rd sends: an
# external peer without LLGR (127.0.0.3), an external one with it
# (127.0.0.4) and an internal one without it (127.0.0.5).
# docs/design/bgp-operations.md section 4, pull request 4a.
class TestLlgr < Test::Unit::TestCase

  # What one watcher received, per prefix: the last announcement's
  # communities, or :withdrawn.
  class Catcher
    def initialize ; @last = {} ; @lock = Mutex.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update)
      @lock.synchronize do
        msg.withdrawn.to_ary.each { |p| @last[p] = :withdrawn } if msg.withdrawn
        pa = msg.path_attribute
        names = pa && pa.has?(BGP::Communities) ? pa[BGP::Communities].communities.split : []
        nexp = pa && pa.has?(BGP::Local_pref) ? pa[BGP::Local_pref].to_i : nil
        msg.nlri.to_ary.each { |p| @last[p] = [names, nexp] } if msg.nlri
      end
    end
    def [](prefix) ; @lock.synchronize { @last[prefix] } ; end
  end

  ROUTES = %w[10.1.0.0/16 10.2.0.0/16].freeze
  STALE = '65535:6'.freeze

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
    [@peer, *@watchers&.values].each { |n| n&.stop rescue nil }
    @sp&.stop
  end

  def speaker(llgr = {})
    @port = free_port
    @sp = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                   'listen_address' => '127.0.0.1', 'port' => @port, 'log_level' => 'error',
                                   'export' => { 'next_hops' => { 1 => '192.0.2.1' } },
                                   'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                     'graceful_restart' => { 'restart_time' => 0 },
                                                     'long_lived_graceful_restart' => llgr },
                                                   { 'address' => '127.0.0.3', 'as' => 65_003 },
                                                   { 'address' => '127.0.0.4', 'as' => 65_004 },
                                                   { 'address' => '127.0.0.5', 'as' => 65_000 }]).start
    @watchers = {}
    @catchers = {}
    { '127.0.0.3' => [65_003, false], '127.0.0.4' => [65_004, true], '127.0.0.5' => [65_000, false] }.each do |a, (as, llgr_cap)|
      @catchers[a] = Catcher.new
      @watchers[a] = dial(a, as, gr: llgr_cap ? 0 : nil, llgr: llgr_cap ? [1, 1, false, 0] : nil)
      @watchers[a].add_observer(@catchers[a])
    end
  end

  # A Neighbor from address. gr: a Restart Time, with IPv4 unicast and F
  # set, or nil for no GR; llgr: [afi, safi, F, LLST], or nil.
  def dial(address, as, gr: nil, llgr: nil)
    n = BGP::Neighbor.new(:my_as => as, :remote_addr => '127.0.0.1', :id => address)
    n.capability :as4_byte
    unless gr.nil?
      c = BGP::OPT_PARM::CAP::Graceful_restart.new(0, gr)
      c.add(1, 1, 0x80)
      n.capability c
    end
    if llgr
      afi, safi, f, llst = llgr
      n.capability BGP::OPT_PARM::CAP::Long_lived_graceful_restart.new(afi, safi, f ? 0x80 : 0, llst)
    end
    sock = Socket.tcp('127.0.0.1', @port, address)
    Thread.new { n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { n.is_established? }, "#{address} came up")
    n
  end

  def announce(n, prefixes, *more)
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001), BGP::Next_hop.new('127.0.0.2'), *more)
    n.send_message(BGP::Update.new(pa, BGP::Nlri.new(*prefixes)))
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def views ; BGP::Daemon::Views.new(@sp) ; end
  def adj_in ; views.adj_in('peer' => '127.0.0.2')[:rows].to_h { |r| [r[:prefix], r.values_at(:stale, :llgr_stale)] } ; end
  def gr_row ; views.peers.find { |r| r[:address] == '127.0.0.2' }[:graceful_restart] ; end
  def seen(watcher, prefix) ; @catchers[watcher][prefix] ; end
  def best_from(prefix) ; @sp.rib.best(prefix)&.peer&.address ; end

  def restarting(llst: 3)
    @peer = dial('127.0.0.2', 65_001, gr: 0, llgr: [1, 1, true, llst])
    announce(@peer, ROUTES)
    assert(wait_until { ROUTES.all? { |p| seen('127.0.0.3', p) && seen('127.0.0.4', p) && seen('127.0.0.5', p) } }, 'sent on to all three')
    @peer.stop
  end

  # Section 4.2 and 4.3: the LLGR period begins after a Restart Time of
  # 0; the routes carry LLGR_STALE; a peer without LLGR sees them
  # withdrawn, internal or external; the one with LLGR sees them again
  # with LLGR_STALE. At the LLST they go from it too.
  def test_the_llgr_period
    speaker
    # A second path to 10.1.0.0/16, from 127.0.0.3, with a longer
    # AS_PATH: it loses until the first is least preferred (section 4.4).
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_003, 65_009), BGP::Next_hop.new('127.0.0.3'))
    @watchers['127.0.0.3'].send_message(BGP::Update.new(pa, BGP::Nlri.new('10.1.0.0/16')))
    restarting
    assert_equal('127.0.0.2', best_from('10.1.0.0/16'))
    assert(wait_until { adj_in.values.uniq == [['long_lived', true]] }, adj_in.inspect)
    assert_equal('long_lived', gr_row[:state])
    assert_equal([{ :afi => 1, :safi => 1 }], gr_row[:long_lived].collect { |f| f.slice(:afi, :safi) })
    # 10.2.0.0/16 has no other path: withdrawn from both peers without
    # LLGR. 10.1.0.0/16 has the fresh one, which the internal peer gets,
    # and which 127.0.0.3, whose path it is, is not sent.
    assert(wait_until { seen('127.0.0.3', '10.2.0.0/16') == :withdrawn && seen('127.0.0.5', '10.2.0.0/16') == :withdrawn },
           [seen('127.0.0.3', '10.2.0.0/16'), seen('127.0.0.5', '10.2.0.0/16')].inspect)
    assert(wait_until { seen('127.0.0.3', '10.1.0.0/16') == :withdrawn && seen('127.0.0.5', '10.1.0.0/16') == [[], 100] })
    assert(wait_until { seen('127.0.0.4', '10.2.0.0/16')&.first&.include?(STALE) }, seen('127.0.0.4', '10.2.0.0/16').inspect)
    assert(wait_until { best_from('10.1.0.0/16') == '127.0.0.3' }, 'the fresh path is best now')
    assert(wait_until { seen('127.0.0.4', '10.1.0.0/16') == [[], nil] }, "and goes out: #{seen('127.0.0.4', '10.1.0.0/16')}")
    # Section 4.6 is not built: no NO_EXPORT and no LOCAL_PREF 0.
    assert_equal([[STALE], nil], seen('127.0.0.4', '10.2.0.0/16'))
    assert(wait_until(6) { adj_in.empty? }, 'gone at the Long-Lived Stale Time')
    assert(wait_until { seen('127.0.0.4', '10.2.0.0/16') == :withdrawn })
    assert_nil(gr_row[:state])
  end

  # Back during the LLGR period with F set: what is sent again is fresh,
  # and End-of-RIB removes the rest.
  def test_back_in_the_llgr_period
    speaker
    restarting(llst: 30)
    assert(wait_until { adj_in.values.uniq == [['long_lived', true]] })
    @peer = dial('127.0.0.2', 65_001, gr: 0, llgr: [1, 1, true, 30])
    announce(@peer, ['10.1.0.0/16'])
    assert(wait_until { adj_in['10.1.0.0/16'] == [nil, nil] }, adj_in.inspect)
    assert(wait_until { seen('127.0.0.3', '10.1.0.0/16').is_a?(Array) }, 'sent again to the peer without LLGR')
    assert_equal('long_lived', gr_row[:state], 'until End-of-RIB')
    @peer.send_message(BGP::Update.end_of_rib_marker)
    assert(wait_until { adj_in.keys == ['10.1.0.0/16'] }, adj_in.inspect)
    assert(wait_until { seen('127.0.0.4', '10.2.0.0/16') == :withdrawn })
    assert_nil(gr_row[:state])
  end

  # Section 4.2: a route with NO_LLGR "MUST NOT be retained".
  def test_no_llgr
    speaker
    @peer = dial('127.0.0.2', 65_001, gr: 0, llgr: [1, 1, true, 30])
    announce(@peer, ['10.1.0.0/16'])
    announce(@peer, ['10.2.0.0/16'], BGP::Communities.new(:no_llgr))
    assert(wait_until { adj_in.size == 2 })
    @peer.stop
    assert(wait_until { adj_in.keys == ['10.1.0.0/16'] }, adj_in.inspect)
    assert(wait_until { seen('127.0.0.4', '10.2.0.0/16') == :withdrawn })
  end

  # max_stale_time reduces the peer's LLST (section 4.2).
  def test_max_stale_time
    speaker('max_stale_time' => 1)
    restarting(llst: 600)
    assert(wait_until { adj_in.values.uniq == [['long_lived', true]] })
    assert(wait_until(4) { adj_in.empty? }, 'gone after a second, not ten minutes')
  end

  # Section 4.5: LLGR with no GR is ignored, so the routes go at once.
  def test_llgr_without_gr
    speaker
    @peer = dial('127.0.0.2', 65_001, llgr: [1, 1, true, 30])
    announce(@peer, ROUTES)
    assert(wait_until { adj_in.size == 2 })
    @peer.stop
    assert(wait_until { adj_in.empty? })
  end

  def test_bgp4rd_advertises_llst_zero
    speaker
    open = @watchers['127.0.0.4'].session_info.peer
    cap = BGP::Daemon::GracefulRestart.received_llgr(open)
    assert_nil(cap, 'not to a peer without long_lived_graceful_restart')
    @peer = dial('127.0.0.2', 65_001, gr: 0, llgr: [1, 1, true, 30])
    assert_equal({ [1, 1] => [0, 0], [2, 1] => [0, 0] }, BGP::Daemon::GracefulRestart.received_llgr(@peer.session_info.peer))
  end
end
