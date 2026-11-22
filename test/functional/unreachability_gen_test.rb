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
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon'
require 'bgp/gen'
require 'time'

# docs/design/unreachability.md pull request 4: what bgp/gen makes for
# `unreachability` and `evpn_unreachability` crosses a session to a
# bgp4rd, which shows what `expected` said, and the withdrawals empty it.
class BGP_Unreachability_Gen_Functional_Test < Test::Unit::TestCase

  PORT = 17_982
  SENDER = '127.0.0.1'
  BGP4RD = '127.0.0.3'
  CAPS = %w[mbgp_ipv4_unreachability_information mbgp_ipv6_unreachability_information
            mbgp_l2vpn_evpn].freeze

  def setup
    @dir = Dir.mktmpdir
    err = StringIO.new
    @d = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      'as' => 65_002, 'router_id' => BGP4RD, 'listen_address' => BGP4RD, 'port' => PORT,
      'state_file' => File.join(@dir, 'd.json'),
      'neighbors' => [{ 'address' => SENDER, 'as' => 65_001, 'capabilities' => ['as4_byte'] + CAPS }])
    assert_not_nil(@d.build(config, :socket => File.join(@dir, 'd.sock')), err.string)
    @n = BGP::Neighbor.new(4, 65_001, 180, '0.0.0.1', BGP4RD, SENDER)
    @n.add_cap BGP::OPT_PARM::CAP::As4.new(65_001)
    CAPS.each { |c| @n.capability(c) }
    @n.start :port => PORT
    assert(wait_for { @n.is_established? }, 'the session came up')
  end

  def teardown
    @n.stop if @n
    @d.stop if @d
    FileUtils.remove_entry(@dir) if @dir
  end

  def wait_for(timeout = 10)
    deadline = Time.now + timeout
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.05
    end
  end

  def rows
    c = BGP::Daemon::Client.new(@d.api.path)
    out, offset = [], 0
    loop do
      page = c.call('show.unreachability', 'offset' => offset, 'limit' => 1000)
      out.concat(page['rows'])
      offset = page['next_offset'] or break
    end
    out
  ensure
    c.close if c
  end

  # What bgp4rd shows, in `expected`'s words.
  def as_expected(r)
    reps = r['reporters']
    h = { 'prefix' => r['prefix'], 'reporters' => reps.collect { |p| p['identifier'] },
          'reporter_as' => reps.first['as'], 'reason' => reps.first['reason'] }
    h['timestamp'] = Time.parse(reps.first['timestamp']).to_i if reps.first['timestamp']
    h['rd'] = r['rd'] if r['rd']
    h['ethernet_tag'] = r['ethernet_tag'] if r['ethernet_tag']
    h
  end

  def crosses(spec)
    g = BGP::Gen.new(spec)
    g.updates.each { |u| @n.send_update u }
    total = g.total
    assert(wait_for { rows.size == total }, "#{rows.size} of #{total} reports arrived")
    keys = %w[prefix reporters reporter_as reason timestamp rd ethernet_tag]
    want = g.expected.collect { |e| e.slice(*keys) }.sort_by { |e| [e['rd'].to_s, e['prefix']] }
    got = rows.collect { |r| as_expected(r) }.sort_by { |e| [e['rd'].to_s, e['prefix']] }
    assert_equal(want, got)
    g.withdrawals.each { |u| @n.send_update u }
    assert(wait_for { rows.empty? }, "#{rows.size} reports left after the withdrawals")
  end

  def test_ipv4
    crosses('family' => 'unreachability', 'start' => '10.0.0.0/24', 'count' => 300,
            'reporters' => 3, 'reporter_as' => 65_001, 'reason' => { 'cycle' => [3, 9] },
            'timestamp' => { 'step' => { 'start' => 1_733_789_400, 'by' => 1 } },
            'attributes' => { 'as_path' => [65_001] })
  end

  def test_ipv6_with_no_timestamp
    crosses('family' => 'unreachability', 'start' => '2001:db8::/48', 'count' => 120,
            'reporter_as' => 65_001, 'attributes' => { 'as_path' => [65_001] })
  end

  def test_evpn
    crosses('family' => 'evpn_unreachability', 'start' => '10.1.0.0/24', 'count' => 40, 'vrfs' => 2,
            'rd' => '127.0.0.1:1', 'route_target' => '65001:1', 'ethernet_tag' => 5,
            'reporters' => 2, 'reporter_as' => 65_001, 'reason' => 12, 'timestamp' => 5,
            'attributes' => { 'as_path' => [65_001], 'next_hop' => SENDER })
  end

end
