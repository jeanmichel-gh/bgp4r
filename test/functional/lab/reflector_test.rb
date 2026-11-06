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

# `bgp4rd` as a route reflector, configured the way a person configures
# one: a node file with `route_reflector_client: true` on two neighbors
# and a `cluster_id`. FRR and GoBGP are the two clients and two bgp4r
# speakers are non-clients. No Docker and no zebra, everything on
# loopback, one address per peer, since the daemon tells its peers apart
# by source address.
#
#   ruby -I. test/functional/lab/reflector_test.rb
#
# Needs both gobgpd and FRR's bgpd. Omitted when either is missing,
# unless LAB_REQUIRE_GOBGPD=1 or LAB_REQUIRE_FRR=1.
#
# What this adds over rib_router_gobgp_test.rb and rib_router_frr_test.rb,
# which already have each router read a reflected route: those build the
# Table and the Export by hand, one router each. Here the node file is
# what reaches the export rules, and **two real routers read one
# reflector's UPDATE**. The RFC 4456 rules asserted, with the section each
# comes from:
#
# * A client's route reaches the other client and the non-clients
#   (section 6), with ORIGINATOR_ID and CLUSTER_LIST (section 8).
# * A non-client's route reaches the clients and not the other non-client
#   (section 6), which is the one refusal a reflector makes.
# * A route that already carries our cluster ID is not used (section 8),
#   so neither client gets it.
#
# One lab for the whole file, built in the first setup and torn down in
# shutdown, because each case only reads what the routes did and three
# routers per case would triple the cost for nothing.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp4r'
require 'bgp/daemon'
require_relative 'lab_helper'

class LabReflectorTest < Test::Unit::TestCase
  include LabHelper

  AS = 65001
  CLUSTER_ID = '7.7.7.7'

  FRR = '127.0.0.2'
  GOBGP = '127.0.0.3'
  NC1 = '127.0.0.4'
  NC2 = '127.0.0.5'
  FRR_ID = '10.0.0.2'
  GOBGP_ID = '10.0.0.3'
  NC1_ID = '10.0.0.4'
  NC2_ID = '10.0.0.5'

  # From a client: GoBGP originates it.
  FROM_CLIENT = '10.1.0.0/24'
  # From a non-client: NC1 sends it.
  FROM_NON_CLIENT = '10.2.0.0/24'
  # From NC1, carrying our own cluster ID already.
  LOOPED = '10.3.0.0/24'

  # Next hops FRR will take, which a loopback address is not; see
  # Frr::NEXT_HOP in lab_helper.rb.
  GOBGP_NEXT_HOP = '192.0.2.20'
  NC1_NEXT_HOP = '192.0.2.30'

  # Collects what a bgp4r non-client receives.
  class Catcher
    def updates ; @updates ||= [] ; end
    def update(m) ; updates << m if m.is_a?(BGP::Update) ; end
    def prefixes ; updates.flat_map { |u| u.nlri ? u.nlri.to_ary : [] } ; end
    def for(prefix) ; updates.find { |u| u.nlri && u.nlri.to_ary.include?(prefix) } ; end
  end

  @@lab = nil

  def self.shutdown
    lab = @@lab or return
    lab[:clients].each { |c| c.close }
    lab[:routers].each { |r| r.down }
    lab[:server].stop
    FileUtils.remove_entry(lab[:dir])
  end

  def setup
    unless LabHelper::Gobgpd.available?
      flunk('gobgpd is not installed') if ENV['LAB_REQUIRE_GOBGPD'] == '1'
      omit('gobgpd is not installed')
    end
    unless LabHelper::Frr.available?
      flunk('FRR bgpd is not installed') if ENV['LAB_REQUIRE_FRR'] == '1'
      omit('FRR bgpd is not installed')
    end
    @@lab ||= build_lab
  end

  def teardown
    return if passed? || @@lab.nil?
    @@lab[:routers].each { |r| puts "\n== #{r.class.name}\n#{r.log}" }
    puts "\n== bgp4rd\n#{@@lab[:err].string}"
  end

  # The node file, as a person would write it. Every neighbor is
  # internal and passive, so the daemon only listens.
  def node_file(dir, port)
    { 'as' => AS, 'router_id' => '10.0.0.1',
      'listen_address' => '127.0.0.1', 'port' => port,
      'state_file' => File.join(dir, 'state.json'),
      'export' => { 'cluster_id' => CLUSTER_ID },
      'neighbors' => [
        { 'address' => FRR,   'as' => AS, 'description' => 'frr',
          'route_reflector_client' => true },
        { 'address' => GOBGP, 'as' => AS, 'description' => 'gobgp',
          'route_reflector_client' => true },
        { 'address' => NC1,   'as' => AS, 'description' => 'nc1' },
        { 'address' => NC2,   'as' => AS, 'description' => 'nc2' },
      ] }
  end

  def build_lab
    dir = Dir.mktmpdir('bgp4r-reflector')
    port = LabHelper::Local.free_port
    err = StringIO.new
    server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(node_file(dir, port))
    lab = { :dir => dir, :err => err, :server => server, :routers => [], :clients => [] }
    @@lab = lab
    assert_not_nil(server.build(config, :socket => File.join(dir, 'bgp4rd.sock')),
                   "bgp4rd did not start: #{err.string}")

    frr = LabHelper::Frr.new(:local => FRR, :as => AS, :router_id => FRR_ID,
                             :peer => '127.0.0.1', :peer_as => AS,
                             :port => port, :ipv6 => false)
    lab[:routers] << frr
    frr.up
    gobgp = LabHelper::Gobgpd.new(:local => GOBGP, :as => AS, :router_id => GOBGP_ID,
                                  :peer => '127.0.0.1', :peer_as => AS,
                                  :port => port, :ipv6 => false)
    lab[:routers] << gobgp
    gobgp.up
    lab[:frr], lab[:gobgp] = frr, gobgp

    lab[:nc] = [[NC1, NC1_ID], [NC2, NC2_ID]].collect do |addr, id|
      n = BGP::Neighbor.new(4, AS, 180, id, '127.0.0.1', addr)
      catcher = Catcher.new
      n.add_observer(catcher)
      lab[:clients] << n
      n.start :port => port
      [n, catcher]
    end

    lab[:client] = BGP::Daemon::Client.new(File.join(dir, 'bgp4rd.sock'))
    wait_for('all four sessions to come up on the reflector', timeout: 60) do
      rows = lab[:client].call('show.peers')
      rows.all? { |r| r['state'] == 'established' } && rows
    end

    # LOOPED first and FROM_NON_CLIENT after it on the same session, so
    # once the second has reached a client the first has been decided.
    nc1 = lab[:nc][0][0]
    nc1.send_update ibgp_update(LOOPED, NC1_NEXT_HOP, [CLUSTER_ID])
    nc1.send_update ibgp_update(FROM_NON_CLIENT, NC1_NEXT_HOP)
    out, status = gobgp.client_run('global', 'rib', 'add', FROM_CLIENT,
                                   'nexthop', GOBGP_NEXT_HOP, '-a', 'ipv4')
    assert(status.success?, "gobgp could not originate #{FROM_CLIENT}: #{out}")
    lab
  end

  # RFC 4271 section 5.1.5: LOCAL_PREF goes to an internal peer, and FRR
  # 8.4.4 treats an internal route without one as a withdraw.
  def ibgp_update(prefix, next_hop, cluster_list = nil)
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new(next_hop),
             BGP::As_path.new, BGP::Local_pref.new(100)]
    attrs << BGP::Cluster_list.new(*cluster_list) if cluster_list
    BGP::Update.new(BGP::Path_attribute.new(*attrs), BGP::Nlri.new(prefix))
  end

  def lab ; @@lab ; end

  def frr_installed(prefix)
    wait_for("FRR to install #{prefix}") { lab[:frr].detail(prefix) }
  end

  def gobgp_installed(prefix)
    path = wait_for("GoBGP to install #{prefix}") { lab[:gobgp].path(prefix) }
    LabHelper::Gobgpd.attrs(path)
  end

  def nc_received(i, prefix)
    wait_for("non-client #{i + 1} to receive #{prefix}") { lab[:nc][i][1].for(prefix) }
  end

  ORIGINATOR_ID = 9
  CLUSTER_LIST = 10

  # The node file reached the daemon: it says it is a reflector, with
  # the cluster ID written there, and which of its peers are clients.
  def test_the_daemon_says_it_reflects_and_names_its_clients
    status = lab[:client].call('show.status')
    assert_equal(true, status['route_reflector'])
    assert_equal(CLUSTER_ID, status['cluster_id'])
    clients = lab[:client].call('show.peers').collect { |r|
      [r['address'], r['route_reflector_client']] }.sort
    assert_equal([[FRR, true], [GOBGP, true], [NC1, false], [NC2, false]], clients)
  end

  # Section 6: "A route from a Client peer: Reflect to all the
  # Non-Client peers and also to the Client peers". GoBGP's route reaches
  # FRR, the other client, and both non-clients, each with section 8's
  # two attributes.
  def test_a_clients_route_reaches_the_other_client_with_both_attributes
    d = frr_installed(FROM_CLIENT)
    assert_equal(GOBGP_ID, d['originatorId'],
                 'ORIGINATOR_ID is the originating client, as FRR read it')
    assert_equal([CLUSTER_ID], d['clusterList'] && d['clusterList']['list'],
                 'CLUSTER_LIST is our cluster ID, as FRR read it')
    assert_equal(GOBGP_NEXT_HOP, LabHelper::Frr.next_hop(d),
                 'NEXT_HOP left alone, RFC 4271 section 5.1.3')
  end

  def test_a_clients_route_reaches_both_non_clients
    [0, 1].each do |i|
      u = nc_received(i, FROM_CLIENT)
      assert_equal(GOBGP_ID, u.path_attribute[BGP::ATTR::ORIGINATOR_ID].originator_id,
                   "ORIGINATOR_ID at non-client #{i + 1}")
      assert_equal([CLUSTER_ID], u.path_attribute[BGP::ATTR::CLUSTER_LIST].cluster_ids,
                   "CLUSTER_LIST at non-client #{i + 1}")
    end
  end

  # Section 6: "A route from a Non-Client IBGP peer: Reflect to all the
  # Clients". Both clients read it, each through its own parser.
  def test_a_non_clients_route_reaches_both_clients
    d = frr_installed(FROM_NON_CLIENT)
    assert_equal(NC1_ID, d['originatorId'], 'ORIGINATOR_ID, as FRR read it')
    assert_equal([CLUSTER_ID], d['clusterList'] && d['clusterList']['list'],
                 'CLUSTER_LIST, as FRR read it')
    a = gobgp_installed(FROM_NON_CLIENT)
    assert_equal(NC1_ID, a[ORIGINATOR_ID] && a[ORIGINATOR_ID]['value'],
                 'ORIGINATOR_ID, as GoBGP read it')
    assert_equal([CLUSTER_ID], a[CLUSTER_LIST] && a[CLUSTER_LIST]['value'],
                 'CLUSTER_LIST, as GoBGP read it')
  end

  # And not to the other non-client, which section 6 leaves out: the
  # non-clients are fully meshed and have the route already. The
  # daemon says why in show.adj_out.
  def test_a_non_clients_route_does_not_reach_the_other_non_client
    gobgp_installed(FROM_NON_CLIENT)
    nc_received(1, FROM_CLIENT)
    assert_nil(lab[:nc][1][1].for(FROM_NON_CLIENT),
               'a non-client route reflected to a non-client')
    out = lab[:client].call('show.adj_out', 'peer' => NC2)
    skipped = (out['skipped'] || {})['rows'] || []
    assert_equal(['non_client_to_non_client'],
                 skipped.select { |r| r['prefix'] == FROM_NON_CLIENT }.collect { |r| r['reason'] },
                 "show.adj_out for #{NC2}: #{out.inspect}")
  end

  # Section 8: a route whose CLUSTER_LIST holds our cluster ID "MUST be
  # ignored". The daemon received it, so show.adj_in has it, and it is in
  # no Loc-RIB row and at neither client. It was sent before
  # FROM_NON_CLIENT on the same session, so once that one is at both
  # clients this one has been decided.
  def test_a_route_with_our_cluster_id_is_not_used
    frr_installed(FROM_NON_CLIENT)
    gobgp_installed(FROM_NON_CLIENT)
    adj_in = lab[:client].call('show.adj_in', 'peer' => NC1)['rows']
    assert(adj_in.any? { |r| r['prefix'] == LOOPED },
           "the daemon never received #{LOOPED}: #{adj_in.inspect}")
    rib = lab[:client].call('show.rib')['rows'].collect { |r| r['prefix'] }
    assert_equal(false, rib.include?(LOOPED), "#{LOOPED} reached the Loc-RIB")
    assert_nil(lab[:frr].detail(LOOPED), "FRR installed #{LOOPED}")
    assert_nil(lab[:gobgp].path(LOOPED), "GoBGP installed #{LOOPED}")
  end
end
