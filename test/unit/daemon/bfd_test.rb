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
require 'bgp/daemon'
require 'test/helpers/fake_bfd_client'

# bgp/daemon/bfd.rb: BFD for the neighbors with `bfd: true`, with a fake
# bfdd4r (test/helpers/fake_bfd_client.rb) and a fake `ip`. The commit of
# the key and the `bfd` column of show.peers are here too, because they
# are this file's behaviour seen from the two places that reach it.
class BGP_Daemon_Bfd_Test < Test::Unit::TestCase
  Result = BGP::Rib::Fib::IpRoute::Result

  # `ip -j route get` as the kernel answers it: one hop away by default,
  # through a gateway for the addresses in @via, no route for @none.
  def setup
    @via = {}
    @none = []
    @argvs = []
    @client = BGP::TestHelpers::FakeBfdClient.new
    @lines = []
    @runner = lambda do |argv|
      @argvs << argv
      a = argv.last
      next Result.new(argv, 2, 'RTNETLINK answers: Network is unreachable') if @none.include?(a)
      route = { 'dst' => a, 'dev' => 'eth1', 'prefsrc' => '10.0.12.1', 'flags' => [], 'uid' => 0 }
      route = route.merge('gateway' => @via[a], 'dev' => 'eth0', 'prefsrc' => '172.20.0.2') if @via[a]
      Result.new(argv, 0, JSON.generate([route]))
    end
  end

  def teardown
    @speaker&.stop
  end

  def config(neighbors)
    { 'as' => 65_001, 'router_id' => '10.0.0.1', 'neighbors' => neighbors }
  end

  def speaker(neighbors)
    @config = config(neighbors)
    @speaker = BGP::Daemon::Speaker.new(@config, :bfd_client => @client, :bfd_runner => @runner,
                                        :logger => ->(level, msg) { @lines << [level, msg] })
  end

  # A peer whose session is Established, as far as Bfd can tell, and
  # which records what it is asked to do.
  def established(peer, up = true)
    done = []
    peer.define_singleton_method(:established?) { up }
    peer.define_singleton_method(:cease) { |sub| done << [:cease, sub] ; up }
    peer.define_singleton_method(:clear) { done << [:clear] ; self }
    done
  end

  def failure(peer = '10.0.12.2')
    @client.push(type: :state, interface: 'eth1', peer: peer, from: :up, state: :down,
                 diag: :control_detection_time_expired)
  end

  # ---- one hop ----

  def test_one_hop_is_the_dev_and_prefsrc_of_route_get
    speaker([])
    h = @speaker.bfd.hop('10.0.12.2')
    assert_equal(['eth1', '10.0.12.1'], [h.interface, h.local])
    assert_equal(%w[ip -j route get 10.0.12.2], @argvs.last)
  end

  def test_a_neighbor_behind_a_gateway_is_refused
    @via['10.9.9.9'] = '172.20.0.1'
    speaker([])
    e = assert_raise(ArgumentError) { @speaker.bfd.hop('10.9.9.9') }
    assert_equal('neighbor 10.9.9.9: bfd needs a neighbor one hop away: it is reached via ' \
                 '172.20.0.1 dev eth0', e.message)
  end

  def test_no_route_is_refused_too
    @none << '10.9.9.9'
    speaker([])
    e = assert_raise(ArgumentError) { @speaker.bfd.hop('10.9.9.9') }
    assert_match(/\Aneighbor 10\.9\.9\.9: bfd needs a neighbor one hop away: .*unreachable/, e.message)
  end

  # ---- at start ----

  def test_the_speaker_will_not_start_on_a_neighbor_it_cannot_run_bfd_to
    @via['10.0.12.2'] = '172.20.0.1'
    e = assert_raise(ArgumentError) { speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }]) }
    assert_match(/neighbor 10\.0\.12\.2: bfd needs a neighbor one hop away/, e.message)
  end

  def test_bfd_is_true_or_false
    e = assert_raise(ArgumentError) { speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => 'yes' }]) }
    assert_equal('neighbor 10.0.12.2: bfd is true or false, got "yes"', e.message)
  end

  def test_no_bfd_neighbor_asks_nothing_of_the_kernel_or_of_bfdd4r
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002 }])
    @speaker.bfd.start
    assert_equal([], @argvs)
    assert_equal([], @client.calls)
  end

  def test_start_wants_a_session_per_bfd_neighbor_and_no_other
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true },
             { 'address' => '10.0.13.2', 'as' => 65_003 }])
    @speaker.bfd.start
    assert_equal([[:want, 'eth1', '10.0.12.2', '10.0.12.1']], @client.calls)
  end

  def test_the_client_name_is_bgp4rd
    assert_equal('bgp4rd', BGP::Daemon::Bfd::CLIENT)
  end

  def test_stop_lets_go_of_the_sessions
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    @speaker.bfd.stop
    assert_equal({ :release => true }, @client.closed)
    assert_nil(@speaker.bfd.state('10.0.12.2'))
  end

  # ---- what acts ----

  # RFC 5882 section 10.2 and RFC 9384 section 3.
  def test_a_failure_resets_an_established_session_with_cease_6_10
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'))
    failure
    @speaker.bfd.poll
    assert_equal([[:cease, 10], [:clear]], done)
    assert_equal(10, BGP::Daemon::Peer::BFD_DOWN)
    assert_match(/BFD Down/, @speaker.peer('10.0.12.2').recorder.snapshot.to_s)
    assert(@lines.any? { |l, m| l == :warn && m =~ /went down.*Cease 6\/10/ }, @lines.inspect)
  end

  def test_a_failure_on_a_session_that_is_not_established_does_nothing
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'), false)
    failure
    @speaker.bfd.poll
    assert_equal([], done)
  end

  # RFC 5882 section 4.2: an AdminDown at either end is not acted on.
  # BFD::Client reports the peer's AdminDown as the state :admin_down.
  def test_admin_down_never_acts
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'))
    @client.push(type: :state, interface: 'eth1', peer: '10.0.12.2', from: :up, state: :admin_down,
                 diag: :neighbor_signaled_session_down)
    @speaker.bfd.poll
    assert_equal([], done)
    assert_equal('admin_down', @speaker.bfd.state('10.0.12.2'))
  end

  def test_coming_up_does_nothing_to_bgp
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'))
    @client.push(type: :state, interface: 'eth1', peer: '10.0.12.2', from: :init, state: :up)
    @speaker.bfd.poll
    assert_equal([], done)
    assert_equal('up', @speaker.bfd.state('10.0.12.2'))
  end

  # bfdd4r going away keeps every BGP session: the local system then
  # does not run BFD, which RFC 5882 section 4.1 allows.
  def test_lost_keeps_the_session_and_logs
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'))
    @client.push(type: :lost, message: 'bfdd4r closed the connection')
    @speaker.bfd.poll
    assert_equal([], done)
    assert_equal(1, @lines.count { |l, m| l == :warn && m =~ /bfdd4r closed the connection.*kept/ })
  end

  def test_a_failure_of_a_session_nobody_asked_for_does_nothing
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002 }])
    @speaker.bfd.start
    done = established(@speaker.peer('10.0.12.2'))
    failure
    @speaker.bfd.poll
    assert_equal([], done)
  end

  # ---- commit: live, no BGP reset ----

  def commit(neighbors)
    candidate = BGP::Daemon::Candidate.new(@speaker, @config)
    lines = BGP::Daemon::Config.to_set(config(neighbors))
    candidate.replace('lines' => lines)
    candidate.commit({})
  end

  def test_adding_bfd_is_live_and_bounces_nothing
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002 }])
    @speaker.bfd.start
    bounced = []
    peer = @speaker.peer('10.0.12.2')
    peer.define_singleton_method(:admin_stop) { bounced << :stop ; self }
    r = commit([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    assert_equal(true, r[:ok], r.inspect)
    assert_equal([], bounced)
    assert_equal([[:want, 'eth1', '10.0.12.2', '10.0.12.1']], @client.calls)
    assert_equal(['a BFD session to 10.0.12.2 is wanted now'], r[:warnings])
    assert_equal(:live, BGP::Daemon::Candidate::Plan.effect(%w[neighbors 10.0.12.2 bfd]))
  end

  def test_removing_bfd_drops_the_session
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true }])
    @speaker.bfd.start
    r = commit([{ 'address' => '10.0.12.2', 'as' => 65_002 }])
    assert_equal(true, r[:ok], r.inspect)
    assert_equal([:drop, 'eth1', '10.0.12.2'], @client.calls.last)
    assert_equal(['the BFD session to 10.0.12.2 is no longer wanted'], r[:warnings])
  end

  def test_a_commit_refuses_bfd_to_a_neighbor_behind_a_gateway
    speaker([{ 'address' => '10.9.9.9', 'as' => 65_002 }])
    @via['10.9.9.9'] = '172.20.0.1'
    r = commit([{ 'address' => '10.9.9.9', 'as' => 65_002, 'bfd' => true }])
    assert_equal(false, r[:ok])
    assert_match(/neighbor 10\.9\.9\.9: bfd needs a neighbor one hop away/, r[:errors].join)
    assert_equal([], @client.calls)
  end

  def test_a_commit_refuses_a_bfd_that_is_not_a_boolean
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002 }])
    r = commit([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => 'on' }])
    assert_equal(false, r[:ok])
    assert_equal(['neighbor 10.0.12.2: bfd is true or false, got "on"'], r[:errors])
  end

  # ---- show.peers ----

  def test_show_peers_has_bfd_on_a_bfd_neighbor_only
    speaker([{ 'address' => '10.0.12.2', 'as' => 65_002, 'bfd' => true },
             { 'address' => '10.0.13.2', 'as' => 65_003 }])
    @speaker.bfd.start
    views = BGP::Daemon::Views.new(@speaker)
    rows = views.peers.to_h { |r| [r[:address], r] }
    assert_equal('unknown', rows['10.0.12.2'][:bfd])
    assert_equal(false, rows['10.0.13.2'].key?(:bfd))
    @client.push(type: :state, interface: 'eth1', peer: '10.0.12.2', from: nil, state: :up)
    @speaker.bfd.poll
    assert_equal('up', views.peers.find { |r| r[:address] == '10.0.12.2' }[:bfd])
  end

  # The key is listed, so a node file carrying it is taken.
  def test_bfd_is_a_neighbor_key
    assert_include(BGP::Daemon::Peer::KEYS, 'bfd')
  end
end
