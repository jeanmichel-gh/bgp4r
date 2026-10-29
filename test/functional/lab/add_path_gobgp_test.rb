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

# ADD-PATH (RFC 7911) against a real router, as a plain process on
# loopback, no Docker.
#
#   ruby -I. test/functional/lab/add_path_gobgp_test.rb
#
# Omitted when gobgpd is not installed, unless LAB_REQUIRE_GOBGPD=1.
#
# This closes the gap that let the inverted Send/Receive field live in
# bgp4r for years. What made it survive was behaviour: every add-path
# test ran bgp4r against bgp4r, where both sides invert the field and the
# error cancels, so the session came up and the paths arrived either way.
#
# Be precise about what is new here, because #115 already did some of it.
# Since that fix, bgp4r's own tests do pin the direction, by writing the
# field value itself on one side: invert `_send_recv` today and
# test/functional/add_path_test.rb fails too. So this file is not the
# only guard, and claiming otherwise would be the kind of confident wrong
# note CLAUDE.md warns about.
#
# What it adds is the two things bgp4r cannot tell itself:
#
#   * A second implementation's reading of the field. GoBGP prints what it
#     made of the capability we sent, so the asymmetric rows below say
#     that our 2 means send to somebody else and not just to us.
#   * The data path. That GoBGP accepts a Path Identifier from us at all,
#     holds two paths for one prefix because of it, and understands a
#     withdrawal that names one of them. Nothing had checked any of that
#     against another implementation, and a Path Identifier sent on a
#     session that did not negotiate one is four unexpected octets in
#     front of every prefix: a corrupt UPDATE, not a wrong route.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'socket'
require 'bgp4r'
require_relative 'lab_helper'

class LabAddPathGobgpTest < Test::Unit::TestCase
  include LabHelper

  OUR_AS = 65001
  THEIR_AS = 65002
  SOURCE_AS = 65003
  PREFIX = '198.51.100.0/24'
  NEXT_HOP = 3   # the attribute type code, RFC 4271 section 4.3

  # What we advertise, what GoBGP must read it as, and what bgp4r then
  # believes about the session. RFC 7911 section 4: 1 is "able to
  # receive", 2 is "able to send", 3 is both, and the symbols name what
  # the sender of the capability can do.
  #
  # The asymmetric rows are the guard. Inverting `_send_recv` makes this
  # fail with GoBGP reading our :send as "receive", which is the bug #115
  # fixed, seen from the outside for the first time.
  FIELD = { :send_and_receive => ['receive/send', true,  true],
            :send             => ['send',         true,  false],
            :recv             => ['receive',      false, true] }

  def setup
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    @sessions = []
    @routers = []
  end

  def teardown
    @sessions.each do |server, peer, thread|
      thread.kill if thread
      peer.close
      server.close unless server.closed?
    end
    @routers.each { |r| r.down }
    puts "\n== gobgpd\n#{@routers.collect(&:log).join}" unless passed?
  end

  # A gobgpd that will both take and send several paths per prefix, and a
  # bgp4r session to it advertising mode for IPv4 unicast. Returns both.
  def session(mode)
    router = LabHelper::Gobgpd.new(:local => '127.0.0.2', :as => THEIR_AS,
                                   :router_id => '10.0.0.2',
                                   :peer => '127.0.0.1', :peer_as => OUR_AS,
                                   :add_path => { :receive => true, :send_max => 8 })
    @routers << router
    router.up

    server = TCPServer.new('127.0.0.1', router.port)
    peer = BGP::Neighbor.new(4, OUR_AS, 180, '10.0.0.1', '127.0.0.2', '127.0.0.1')
    peer.capability :as4_byte
    peer.capability :mbgp, :ipv4, :unicast
    # Neighbor#capability passes its arguments on to the capability, and
    # CAP::Add_path#add takes them in the order (send_recv, afi, safi).
    peer.capability :add_path, mode, 1, 1
    thread = Thread.new do
      begin
        while (socket = server.accept)
          peer.start_session(socket)
        end
      rescue IOError, SystemCallError
      end
    end
    @sessions << [server, peer, thread]
    peer.wait_for_state(:Established, 40)
    [router, peer]
  end

  # One path to PREFIX, with its own Path Identifier (RFC 7911 section 3),
  # AS_PATH and next hop, so the two are told apart in the router's RIB.
  def path(path_id, as_path, next_hop)
    BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(:igp), BGP::As_path.new(*as_path),
                              BGP::Next_hop.new(next_hop)),
      BGP::Nlri.new(:path_id => path_id, :nlri => PREFIX))
  end

  def paths_for(router, count)
    wait_for("GoBGP to hold #{count} path(s) for #{PREFIX}", timeout: 30) do
      paths = (router.rib || {})[PREFIX]
      paths if paths && paths.size == count
    end
  end

  def next_hops(paths)
    paths.collect { |p| LabHelper::Gobgpd.attrs(p)[NEXT_HOP]['nexthop'] }.sort
  end

  # The test that could not be written without a second implementation.
  def test_gobgp_reads_our_send_receive_field_the_way_we_meant_it
    FIELD.each do |mode, (reading, can_send, can_recv)|
      router, peer = session(mode)
      assert_equal(reading, router.remote_add_path('127.0.0.1'),
                   "we advertised #{mode.inspect}, so GoBGP must read it as #{reading}")
      # And bgp4r's own view of the pair rule of RFC 7911 section 5, which
      # has to agree with the router's reading of our half.
      assert_equal(can_send, peer.session_info.path_id_send?(1, 1),
                   "path_id_send? with #{mode.inspect}")
      assert_equal(can_recv, peer.session_info.path_id_recv?(1, 1),
                   "path_id_recv? with #{mode.inspect}")
    end
  end

  # RFC 7911 section 3: the Path Identifier is what lets one peer hold
  # several paths to one prefix. Before this, nothing had checked that
  # anybody else reads ours.
  def test_gobgp_holds_both_paths_we_send_for_one_prefix
    router, peer = session(:send_and_receive)
    assert(peer.session_info.path_id_send?(1, 1), 'we may send several paths')

    peer.send_message path(7, [OUR_AS, SOURCE_AS], '10.0.0.7')
    peer.send_message path(9, [OUR_AS, 65004, 65005], '10.0.0.9')
    paths = paths_for(router, 2)

    assert_equal(['10.0.0.7', '10.0.0.9'], next_hops(paths),
                 'both paths, told apart by their next hops')
    # Only one of them can be best, and RFC 4271 section 9.1.2.2 a) says
    # which: the shorter AS_PATH, which is the one behind 10.0.0.7.
    best = paths.select { |p| p['best'] }
    assert_equal(1, best.size, 'exactly one best path')
    assert_equal('10.0.0.7', LabHelper::Gobgpd.attrs(best.first)[NEXT_HOP]['nexthop'],
                 'the shorter AS_PATH won')
  end

  # The half that is easy to get wrong: a withdrawal has to name the Path
  # Identifier too, or it takes every path to the prefix with it.
  def test_withdrawing_one_path_by_its_identifier_leaves_the_other
    router, peer = session(:send_and_receive)
    peer.send_message path(7, [OUR_AS, SOURCE_AS], '10.0.0.7')
    peer.send_message path(9, [OUR_AS, 65004, 65005], '10.0.0.9')
    paths_for(router, 2)

    peer.send_message BGP::Update.new(BGP::Withdrawn.new(:path_id => 7, :nlri => PREFIX))
    paths = paths_for(router, 1)

    assert_equal(['10.0.0.9'], next_hops(paths),
                 'the other path survived, so the router read our Path Identifier. ' \
                 'A withdrawal keyed on the prefix alone would have taken both')
    assert_equal(true, paths.first['best'], 'and it is the best path now')
  end
end
