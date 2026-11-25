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
require 'bgp/daemon/speaker'
require 'bgp/daemon/views'

# Answering a route refresh, RFC 2918 section 4 and RFC 7313 section 4,
# through a real Speaker over loopback. A library Neighbor from
# 127.0.0.2 asks, so our next hop, 127.0.0.1, is not its own address,
# and it keeps every UPDATE and ROUTE-REFRESH in the order it came.
class TestRouteRefresh < Test::Unit::TestCase

  class Catcher
    attr_reader :messages
    def initialize ; @messages = Queue.new ; end
    def update(msg)
      @messages << msg if msg.is_a?(BGP::Update) || msg.is_a?(BGP::Route_refresh)
    end
  end

  V4 = %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16].freeze
  V6 = %w[2001:db8:1::/48].freeze

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def speaker(caps, extra = {})
    @port = free_port
    @sp = BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1',
                                     'listen_address' => '127.0.0.1', 'port' => @port,
                                     'log_level' => 'error',
                                     'export' => { 'next_hops' => { 1 => '192.0.2.1', 2 => '2001:db8::1' } },
                                     'originate' => [{ 'prefixes' => V4 + V6 }],
                                     'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001,
                                                       'capabilities' => caps }] }.merge(extra)).start
  end

  def client(caps)
    @catcher = Catcher.new
    @n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    caps.each { |c| @n.capability c }
    @n.add_observer(@catcher)
    sock = Socket.tcp('127.0.0.1', @port, '127.0.0.2')
    Thread.new { @n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { @n.is_established? }, 'the session came up')
    received # the first table, out of the way
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # What came within `seconds`, as [:route, prefixes] or [:borr | :eorr |
  # :normal, afi, safi], in order.
  def received(seconds = 2)
    sleep seconds
    out = []
    until @catcher.messages.empty?
      m = @catcher.messages.pop
      if m.is_a?(BGP::Route_refresh)
        out << [BGP::Daemon::Refresh::SUBTYPES.fetch(m.subtype || 0).to_sym, m.afi, m.safi]
      else
        pa = m.path_attribute
        v6 = pa && pa.has?(BGP::Mp_reach) ? pa[:mp_reach].nlris.collect { |n| n.to_s } : []
        out << [:route, (m.nlri ? m.nlri.to_ary : []) + v6]
      end
    end
    out
  end

  def routes(got) ; got.select { |g| g.first == :route }.flat_map(&:last) ; end

  def row ; BGP::Daemon::Views.new(@sp).peers.first ; end

  def teardown
    @n&.stop
    @sp&.stop
  end

  # RFC 2918 section 4: every route of the family again, and nothing of
  # another.
  def test_a_refresh_is_answered_with_the_family
    speaker(%w[route_refresh mbgp_ipv4_unicast mbgp_ipv6_unicast])
    client(%i[route_refresh mbgp_ipv4_unicast mbgp_ipv6_unicast])
    @n.send_message(BGP::Route_refresh.new(1, 1))
    got = received
    assert_equal(V4, routes(got).sort)
    assert_equal([], got.reject { |g| g.first == :route }, 'no BoRR or EoRR to a peer without capability 70')
    @n.send_message(BGP::Route_refresh.new(2, 1))
    assert_equal(V6, routes(received).collect { |p| p.sub(/\/48.*/, '/48') })
    r = row[:refresh]
    assert_equal({ :normal => 2 }, r[:received])
    assert_equal([2, 0], [r[:answered], r[:ignored]])
  end

  # RFC 7313 section 4: with capability 70 from the peer, BoRR first and
  # EoRR last.
  def test_an_enhanced_peer_gets_borr_and_eorr_around_it
    speaker(%w[route_refresh enhanced_route_refresh])
    client(%i[route_refresh enhanced_route_refresh])
    @n.send_message(BGP::Route_refresh.new(1, 1))
    got = received
    assert_equal([:borr, 1, 1], got.first)
    assert_equal([:eorr, 1, 1], got.last)
    assert_equal(V4, routes(got).sort)
    assert_equal({ :borr => 1, :eorr => 1 }, row[:refresh][:sent])
  end

  # RFC 2918 section 4: a family we did not advertise is ignored.
  def test_a_family_we_did_not_advertise_is_ignored
    speaker(%w[route_refresh])
    client(%i[route_refresh mbgp_ipv6_unicast])
    @n.send_message(BGP::Route_refresh.new(2, 1))
    assert_equal([], received)
    assert_equal([0, 1], row[:refresh].values_at(:answered, :ignored))
  end

  # Without the capability in our OPEN, nothing changes: ignored, as
  # bgp4rd ignored every request before.
  def test_without_the_capability_it_is_ignored
    speaker(%w[as4_byte])
    client(%i[route_refresh])
    @n.send_message(BGP::Route_refresh.new(1, 1))
    assert_equal([], received)
    assert_equal(1, row[:refresh][:ignored])
  end

  # A new session starts the counts again, as FRR's do.
  def test_a_new_session_starts_the_counts_again
    speaker(%w[route_refresh])
    client(%i[route_refresh])
    @n.send_message(BGP::Route_refresh.new(1, 1))
    received
    assert_equal(1, row[:refresh][:answered])
    @n.stop
    assert_equal(true, wait_until { !@sp.peer('127.0.0.2').established? })
    client(%i[route_refresh])
    assert_equal(false, row.key?(:refresh))
  end

  # Each message and each answer is a `refresh` event.
  def test_the_events
    speaker(%w[route_refresh enhanced_route_refresh])
    sub = @sp.events.subscribe(:kinds => [:refresh])
    client(%i[route_refresh enhanced_route_refresh])
    @n.send_message(BGP::Route_refresh.new(1, 1))
    received
    events = []
    while (ev = sub.pop(:timeout => 1))
      events << ev
    end
    assert_equal([{ :direction => 'receive', :afi => 1, :safi => 1, :subtype => 'normal' },
                  { :direction => 'send', :afi => 1, :safi => 1, :subtype => 'borr' },
                  { :direction => 'send', :afi => 1, :safi => 1, :subtype => 'eorr' },
                  { :answered => { :afi => 1, :safi => 1 }, :enhanced => true }],
                 events.collect(&:data))
  end
end
