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
  end

  def test_the_families_spelled_alike_on_both_sides
    [G::FS_IPV4, G::FS_IPV6, G::RTC, 'ipv4-unicast'].each do |name|
      assert_equal(name, G.client_family(name),
                   "#{name} is spelled alike on both sides")
    end
  end
end
