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

# End-of-RIB, RFC 4724 section 2, through a real Speaker over loopback:
# what bgp4rd sends after a session's first table, and what it makes of
# a marker it receives. A library Neighbor from 127.0.0.2 is the other
# end, so our next hop, 127.0.0.1, is not its own address, and it keeps
# every message in the order it came.
class TestEndOfRib < Test::Unit::TestCase

  # Every message the client reads, in order.
  class Catcher
    attr_reader :messages
    def initialize ; @messages = Queue.new ; end
    def update(msg) ; @messages << msg if msg.is_a?(BGP::Update) ; end
  end

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    s.addr[1]
  ensure
    s&.close
  end

  def speaker(neighbor, extra = {})
    @port = free_port
    BGP::Daemon::Speaker.new({ 'as' => 65_000, 'router_id' => '10.0.0.1',
                               'listen_address' => '127.0.0.1', 'port' => @port,
                               'log_level' => 'error',
                               'neighbors' => [{ 'address' => '127.0.0.2', 'as' => 65_001 }.merge(neighbor)] }.merge(extra)).start
  end

  # A session from a library Neighbor, which advertises `caps`.
  def client(caps = [])
    @catcher = Catcher.new
    @n = BGP::Neighbor.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    caps.each { |c| @n.capability c }
    @n.add_observer(@catcher)
    sock = Socket.tcp('127.0.0.1', @port, '127.0.0.2')
    Thread.new { @n.start(:session => sock, :timeout => 5) rescue nil }
    assert_equal(true, wait_until { @n.is_established? }, 'the session came up')
    @n
  end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  # The UPDATEs read within `seconds`, as [:route, prefixes] or
  # [:eor, afi, safi], in order.
  def received(seconds = 2)
    sleep seconds
    out = []
    until @catcher.messages.empty?
      u = @catcher.messages.pop
      eor = u.end_of_rib
      out << (eor ? [:eor, *eor] : [:route, u.nlri ? u.nlri.to_ary : []])
    end
    out
  end

  def teardown
    @n&.stop
    @sp&.stop
  end

  # One marker per negotiated family, after the last route of the first
  # table, in the order of our OPEN.
  def test_the_markers_follow_the_first_table
    @sp = speaker({ 'end_of_rib' => true, 'capabilities' => %w[mbgp_ipv4_unicast mbgp_ipv6_unicast] },
                  'originate' => [{ 'prefixes' => %w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16] }], 'export' => {})
    # The Router sends the table on the RIB feed's thread, and over
    # loopback it wins the race to the wire every time, so a marker sent
    # without waiting for it would pass here too. Holding it back a second
    # makes the wait the only thing that keeps the order: without the
    # drain in Speaker#send_end_of_rib, the markers come first.
    @sp.router.singleton_class.prepend(Module.new { def session_up(a) ; sleep 1 ; super ; end })
    client(%i[mbgp_ipv4_unicast mbgp_ipv6_unicast])
    got = received(3)
    routes = got.select { |g| g.first == :route }.flat_map(&:last)
    assert_equal(%w[10.1.0.0/16 10.2.0.0/16 10.3.0.0/16], routes.sort)
    assert_equal([[:eor, 1, 1], [:eor, 2, 1]], got.last(2), got.inspect)
    assert_equal(2, got.count { |g| g.first == :eor })
  end

  # RFC 4724 section 4, "including the case when there is no update to
  # send": with no table at all, the marker still goes.
  def test_the_marker_goes_with_nothing_to_send
    @sp = speaker('end_of_rib' => true)
    client
    assert_equal([[:eor, 1, 1]], received)
  end

  # Only families both OPENs list: IPv6 is ours alone, so it gets none.
  def test_only_negotiated_families_get_one
    @sp = speaker('end_of_rib' => true, 'capabilities' => %w[mbgp_ipv4_unicast mbgp_ipv6_unicast])
    client(%i[mbgp_ipv4_unicast])
    assert_equal([[:eor, 1, 1]], received)
  end

  # The control: off unless asked, so the wire is what it always was.
  def test_no_marker_without_end_of_rib
    @sp = speaker({}, 'originate' => [{ 'prefixes' => %w[10.1.0.0/16] }], 'export' => {})
    client
    got = received
    assert_equal([], got.select { |g| g.first == :eor })
    assert_equal([[:route, %w[10.1.0.0/16]]], got)
  end

  # Receipt: whatever the neighbor's own key, a marker is an event and
  # goes on the peer's row, per family, and a new session forgets it.
  def test_a_received_marker_is_an_event_and_on_the_row
    @sp = speaker('capabilities' => %w[mbgp_ipv4_unicast mbgp_ipv6_unicast])
    sub = @sp.events.subscribe
    client(%i[mbgp_ipv4_unicast mbgp_ipv6_unicast])
    @n.send_message(BGP::Update.end_of_rib_marker(:afi => 2, :safi => 1))
    @n.send_message(BGP::Update.end_of_rib_marker)
    peer = @sp.peer('127.0.0.2')
    assert_equal(true, wait_until { peer.recorder.data['end_of_rib_received'].size == 2 })
    assert_equal([{ 'afi' => 2, 'safi' => 1 }, { 'afi' => 1, 'safi' => 1 }], peer.recorder.data['end_of_rib_received'])
    events = []
    while (ev = sub.pop(:timeout => 1))
      events << ev
    end
    eor = events.select { |e| e.data.key?(:end_of_rib) }
    assert_equal([{ :afi => 2, :safi => 1 }, { :afi => 1, :safi => 1 }], eor.collect { |e| e.data[:end_of_rib] })
    assert_equal([:session], eor.collect(&:kind).uniq)
    assert_equal(['127.0.0.2'], eor.collect(&:peer).uniq)
    @n.stop
    assert_equal(true, wait_until { !peer.established? })
    assert_equal([], peer.recorder.data['end_of_rib_received'], 'a session that ends forgets them')
  end
end
