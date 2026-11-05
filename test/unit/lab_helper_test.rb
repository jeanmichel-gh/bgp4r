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
require './test/functional/lab/lab_helper'

# The parts of the lab harness that need no router binary, no socket and
# no Docker, so they can be pinned from the unit suite and run
# everywhere. `lab_helper.rb` loads on stdlib alone, which is what makes
# this possible, and `test/unit/lab_groups_test.rb` is the precedent for
# a unit test over the lab arrangement rather than over `bgp/`.
#
# **What is here is the half that decides whether a daemon that did not
# come up is retried or reported.** `Gobgpd#up` retries a lost port race
# and raises on everything else, and the two look nothing alike to a
# reader of the log while being one string comparison in the code. CI
# failing on 2026-10-31 is what asked for it: a port race that had been
# latent since the harness was written, surfaced by the number of
# daemons in one group going from 3 to 12.
class LabHelperTest < Test::Unit::TestCase

  G = LabHelper::Gobgpd

  # gobgpd's own words when something already holds a port it tried to
  # bind, copied from the CI log that failed. It says the same for the
  # BGP port as for the gRPC one, which is why the match is on the
  # kernel's message and not on "grpc".
  CONFLICT = <<~'LOG'
    {"level":"info","msg":"gobgpd started","time":"2026-10-31T17:54:05Z"}
    {"Error":"listen tcp 127.0.0.2:37903: bind: address already in use","Key":"127.0.0.2:37903","Topic":"grpc","level":"warning","msg":"listen failed","time":"2026-10-31T17:54:05Z"}
    {"Err":"listen tcp 127.0.0.2:37903: bind: address already in use","level":"fatal","msg":"failed to listen grpc port","time":"2026-10-31T17:54:05Z"}
  LOG

  # And its words for a config it rejected, which must **not** be
  # retried: three attempts at a key gobgpd will never accept is three
  # times the wait and the same answer.
  BAD_FAMILY = <<~'LOG'
    {"level":"info","msg":"gobgpd started","time":"2026-10-31T18:02:11Z"}
    {"Topic":"Config","level":"fatal","msg":"no-such-family isn't a valid route family name","time":"2026-10-31T18:02:11Z"}
  LOG

  def test_a_port_conflict_is_recognised
    assert(G.port_conflict?(CONFLICT),
           "gobgpd's own EADDRINUSE log has to read as a port conflict")
  end

  def test_a_rejected_config_is_not_a_port_conflict
    assert(!G.port_conflict?(BAD_FAMILY),
           'a config gobgpd rejected must not be retried')
    assert(!G.port_conflict?(''), 'and neither must an empty log')
    assert(!G.port_conflict?(nil), 'nor a nil one, which log returns on no file')
  end

  # The retry exists because this cannot be made airtight: the socket has
  # to be closed before the port can be handed to a child process. So
  # the contract is only that the port is free at the moment it is
  # answered, and a caller that spawns a daemon has to survive losing it.
  def test_free_port_answers_a_port_nothing_holds_right_now
    port = LabHelper::Local.free_port
    assert(port.between?(1024, 65_535), "#{port} is not an ephemeral port")
    # Bindable, which is what "free" means and all it means.
    s = TCPServer.new('127.0.0.1', port)
    assert_equal(port, s.addr[1])
  ensure
    s.close if s
  end

  # **The host argument is the fix for half the CI failure**, so it is
  # pinned: the probe has to ask about the address the caller will bind.
  # Asking 127.0.0.1 for a port that gobgpd then binds on 127.0.0.2 is a
  # different question, and the harness asked the wrong one for as long
  # as it existed.
  #
  # **The obvious assertion here is a weak one and was written first**:
  # ask for a port on 127.0.0.2 and bind it there. It passes against a
  # hardcoded 127.0.0.1 too, because a port free on one loopback address
  # is almost always free on the other, so the sabotage missed rather
  # than the code being right. Measured, by trying it.
  #
  # TEST-NET-1 is the assertion that cannot pass by luck: 192.0.2.1 is
  # not an address of this machine, so a probe that really binds what it
  # was given cannot succeed, and one that ignores its argument cannot
  # fail. The errno is the kernel's, not Ruby's choice.
  def test_free_port_binds_the_address_it_is_given
    assert_raise(Errno::EADDRNOTAVAIL) do
      LabHelper::Local.free_port('192.0.2.1')
    end
  end

  def test_free_port_answers_for_the_second_loopback_address
    port = LabHelper::Local.free_port('127.0.0.2')
    s = TCPServer.new('127.0.0.2', port)
    assert_equal(port, s.addr[1], 'free on 127.0.0.2, where it was asked about')
  ensure
    s.close if s
  end

  def test_free_port_defaults_to_loopback
    port = LabHelper::Local.free_port
    s = TCPServer.new('127.0.0.1', port)
    assert_equal(port, s.addr[1])
  ensure
    s.close if s
  end

  # The client and config family names, which have disagreed twice and
  # agreed once. Cheap to pin and it is the kind of table that goes
  # quietly wrong: a wrong name here does not fail, it makes a lab test
  # read an empty RIB and conclude the router dropped the route.
  def test_the_families_the_client_and_the_config_spell_differently
    assert_equal('ipv4-l3vpn-flowspec', G.client_family(G::FS_VPN))
    assert_equal('evpn', G.client_family(G::EVPN))
    assert_equal('ipv4-mpls', G.client_family(G::LABELLED_IPV4))
    assert_equal('ipv6-mpls', G.client_family(G::LABELLED_IPV6))
    assert_equal('vpnv4', G.client_family(G::VPN_IPV4))
    assert_equal('vpnv6', G.client_family(G::VPN_IPV6))
  end

  # The generated gobgpd config. `peer2` was added so one daemon can sit
  # between two bgp4r speakers, which `attr_set_gobgp_test.rb` needs
  # because an optional transitive attribute's whole point is surviving
  # transit. Ten lab tests share this helper, so **the config a caller
  # without peer2 gets has to be what it always was**, and that was
  # checked by diffing five option sets before and after the refactor.
  # These two tests are that check moved into the suite, since a claim
  # nothing runs reads as verified.
  #
  # Every port is fixed, because the real ones come from free_port and
  # would differ per run.
  def fixed_config(**kw)
    g = G.new(**kw)
    g.instance_variable_set(:@port, 1111)
    g.instance_variable_set(:@listen_port, 2222)
    g.instance_variable_set(:@api_port, 3333)
    g.config
  end

  def test_one_neighbor_without_peer2_whatever_else_is_asked_for
    [{}, { :ipv6 => false }, { :families => ['rtc'] },
     { :add_path => { :receive => true, :send_max => 8 } }].each do |kw|
      cfg = fixed_config(**kw)
      assert_equal(1, cfg.scan('[[neighbors]]').size, kw.inspect)
      assert_equal(1, cfg.scan('neighbor-address').size, kw.inspect)
    end
  end

  # And with one, a second whole element rather than a second copy of
  # the first: its own address, its own AS, its own remote port, and the
  # afi-safis every neighbor here gets.
  def test_peer2_adds_a_second_neighbor_element
    cfg = fixed_config(:ipv6 => false,
                       :peer2 => { :address => '127.0.0.3', :as => 65003,
                                   :port => 9999 })
    assert_equal(2, cfg.scan('[[neighbors]]').size)
    assert_match(/neighbor-address = "127\.0\.0\.1"/, cfg)
    assert_match(/neighbor-address = "127\.0\.0\.3"/, cfg)
    assert_match(/peer-as = 65003/, cfg)
    assert_match(/remote-port = 9999/, cfg)
    assert_equal(2, cfg.scan('afi-safi-name').size, 'one family each')
    # The first element is unchanged by the second's presence, which is
    # what keeps the single-peer callers safe.
    one = fixed_config(:ipv6 => false)
    assert(cfg.start_with?(one.sub(/\s+\z/, '')),
           'the first neighbor block is still byte for byte the old one')
  end

  def test_the_families_spelled_alike_on_both_sides
    [G::FS_IPV4, G::FS_IPV6, G::RTC, 'ipv4-unicast'].each do |name|
      assert_equal(name, G.client_family(name),
                   "#{name} is spelled alike on both sides")
    end
  end

  # ---- phase 6: a bgp/gen spec against a router -----------------------

  # A router that holds whatever the peer sent it, counted by prefix, so
  # LabHelper#spec_crosses can be run with no daemon at all.
  class FakeRouter
    attr_reader :asked
    def initialize ; @held = {} ; @asked = [] ; end
    def take(update)
      info = BGP::Update::Info.new(true)
      u = BGP::Update.new(update.encode(info).is_packed, info)
      Array(u.nlri && u.nlri.to_ary).each { |p| @held[p] = true }
      Array(u.withdrawn && u.withdrawn.to_ary).each { |p| @held.delete(p) }
    end
    def path_count(family) ; @asked << family ; @held.size ; end
  end

  class FakePeer
    attr_reader :sent
    def initialize(router) ; @router = router ; @sent = 0 ; end
    def send_message(u) ; @sent += 1 ; @router.take(u) ; end
  end

  # Runs spec_crosses with wait_for answering at once, so a router that
  # never reaches the count fails rather than waiting 60 seconds.
  class Driver
    include LabHelper
    def wait_for(message, **) ; yield or raise "never: #{message}" ; end
  end

  SPEC = { 'family' => 'unicast', 'start' => '10.0.0.0/24', 'count' => 300,
           'attributes' => { 'next_hop' => '192.0.2.1', 'med' => { 'step' => { 'start' => 0, 'by' => 1 } } } }

  def test_spec_crosses_sends_the_feed_and_withdraws_it
    require 'bgp/gen'
    r = FakeRouter.new
    peer = FakePeer.new(r)
    seen = nil
    g = Driver.new.spec_crosses(r, 'ipv4', SPEC, peer) { |rows| seen = rows }
    assert_equal(300, g.total)
    assert_equal(10, seen.size, 'ten rows spread across the feed')
    assert_equal('10.0.0.0/24', seen.first['prefix'])
    assert_equal('10.1.43.0/24', seen.last['prefix'], 'the last route of the feed')
    assert_equal(0, r.path_count('ipv4'), 'withdrawn')
    assert_equal(g.updates.count + g.withdrawals.count, peer.sent)
    assert_equal(['ipv4'], r.asked.uniq, 'the family is asked in the router\'s own name')
  end

  # The count is the assertion, so a router that drops one route fails.
  def test_a_route_the_router_dropped_fails_the_count
    require 'bgp/gen'
    r = FakeRouter.new
    def r.take(u) ; super ; @held.delete('10.0.5.0/24') ; end
    e = assert_raise(RuntimeError) { Driver.new.spec_crosses(r, 'ipv4', SPEC, FakePeer.new(r)) }
    assert_match(/hold 300 ipv4 paths/, e.message)
  end

  def test_spec_crosses_takes_a_gen_already_built
    require 'bgp/gen'
    r = FakeRouter.new
    g = BGP::Gen.new(SPEC)
    assert_same(g, Driver.new.spec_crosses(r, 'ipv4', g, FakePeer.new(r)))
  end

  def test_the_sample_spreads_across_the_rows
    assert_equal([0, 33, 66, 99, 132, 166, 199, 232, 265, 299], LabHelper.sample(300))
    assert_equal([0, 1, 2], LabHelper.sample(3), 'every row when there are fewer')
    assert_equal([], LabHelper.sample(0))
    assert_equal([0, 99], LabHelper.sample(100, 2))
  end

  # ---- FRR ------------------------------------------------------------

  F = LabHelper::Frr

  # FRR's words when it cannot write its pid file, from lib/pid_output.c.
  # Under FRR 10's AppArmor profile the cause is Permission denied.
  PID_DENIED = "Can't create pid lock file /tmp/bgp4r-frr1/bgpd.pid " \
               "(Permission denied), exiting\n"

  def test_a_refused_pid_file_names_apparmor_and_the_way_round_it
    hint = F.startup_hint(PID_DENIED, :bin => '/elsewhere/bgpd', :apparmor => false)
    assert_match(/AppArmor/, hint)
    assert_match(/FRR_BGPD/, hint, 'the hint names the workaround')
  end

  # bgpd may die before its log goes anywhere this harness reads, so an
  # exit of the packaged binary with AppArmor on is enough.
  def test_the_packaged_binary_dying_under_apparmor_gets_the_hint
    assert_not_nil(F.startup_hint('', :bin => F::PACKAGED, :apparmor => true))
  end

  def test_no_hint_where_apparmor_cannot_be_the_cause
    assert_nil(F.startup_hint('', :bin => F::PACKAGED, :apparmor => false),
               'AppArmor off')
    assert_nil(F.startup_hint('', :bin => '/elsewhere/bgpd', :apparmor => true),
               'a copy is not confined')
    assert_nil(F.startup_hint('', :bin => F::PACKAGED, :apparmor => true, :exited => false),
               'a slow start is not a confined one')
    assert_nil(F.startup_hint("% Unknown command: neighbor\n", :bin => '/x', :apparmor => false),
               'a config bgpd rejected')
  end

  def test_a_measured_major_runs_and_an_unmeasured_one_omits
    assert(F.measured?(8..8, 8, {}))
    assert(!F.measured?(8..8, 10, {}), 'FRR 10 is not measured for 8..8')
    assert(!F.measured?(8..8, nil, {}), 'no version read means nothing to run against')
  end

  def test_lab_frr_any_runs_an_unmeasured_version
    assert(F.measured?(8..8, 10, 'LAB_FRR_ANY' => '1'))
    assert(!F.measured?(8..8, 10, 'LAB_FRR_ANY' => '0'), 'only 1 turns it on')
    assert(!F.measured?(8..8, nil, 'LAB_FRR_ANY' => '1'), 'still needs a version')
  end

  # FRR 10 refuses IPv6 unicast over an IPv4 session with no zebra, so a
  # config only carries it when a test asks.
  def test_ipv6_unicast_is_off_unless_asked_for
    plain = F.new
    asked = F.new(:ipv6 => true)
    assert_no_match(/ipv6 unicast/, plain.config)
    assert_match(/address-family ipv6 unicast/, asked.config)
  ensure
    [plain, asked].compact.each { |r| FileUtils.rm_rf(r.dir) }
  end
end
