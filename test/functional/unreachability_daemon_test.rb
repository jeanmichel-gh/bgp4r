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

# docs/design/unreachability.md pull request 3: two bgp4rd on loopback,
# one reporting, both collecting, over SAFI 81 for IPv4 and IPv6 and over
# EVPN route type 254.
class BGP_Unreachability_Daemon_Functional_Test < Test::Unit::TestCase

  PORT = 17_981
  R1 = '127.0.0.1'
  R2 = '127.0.0.2'
  CAPS = ['as4_byte', 'mbgp_ipv4_unreachability_information',
          'mbgp_ipv6_unreachability_information', 'mbgp_l2vpn_evpn'].freeze

  REPORTS = [
    { 'prefix' => '192.0.2.0/24', 'reason' => 'rpki_invalid', 'timestamp' => 1_733_789_400 },
    { 'prefix' => '2001:db8::/32', 'reason' => 9 },
    { 'prefix' => '198.51.100.0/24', 'reason' => 'vtep_unreachable',
      'evpn' => { 'rd' => '127.0.0.1:100', 'route_targets' => ['65001:100'], 'evi' => 100 } },
  ].freeze

  def setup
    @dir = Dir.mktmpdir
    @r2 = daemon('r2', 65_002, R2,
                 'listen_address' => R2, 'port' => PORT,
                 'neighbors' => [{ 'address' => R1, 'as' => 65_001, 'capabilities' => CAPS }])
    @r1 = daemon('r1', 65_001, R1,
                 'local_address' => R1,
                 'neighbors' => [{ 'address' => R2, 'as' => 65_002, 'connect' => true,
                                   'port' => PORT, 'retry' => 1, 'capabilities' => CAPS }],
                 'unreachability' => REPORTS.collect(&:dup))
  end

  def teardown
    [@r1, @r2].each { |d| d.stop if d }
    FileUtils.remove_entry(@dir) if @dir
  end

  def daemon(name, as, router_id, extra)
    err = StringIO.new
    server = BGP::Daemon::Server.new(StringIO.new, err)
    config = BGP::Daemon::Server.with_defaults(
      { 'as' => as, 'router_id' => router_id,
        'state_file' => File.join(@dir, "#{name}.json") }.merge(extra))
    assert_not_nil(server.build(config, :socket => File.join(@dir, "#{name}.sock")),
                   "#{name} did not start: #{err.string}")
    server
  end

  def call(server, method, params = {})
    c = BGP::Daemon::Client.new(server.api.path)
    c.call(method, params)
  ensure
    c.close if c
  end

  def rows(server, params = {})
    call(server, 'show.unreachability', { 'limit' => 1000 }.merge(params))['rows']
  end

  def wait_for(what, timeout = 10)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for #{what}") if Time.now > deadline
      sleep 0.05
    end
  end

  def received
    wait_for('r2 to hold r1\'s three reports') { rows(@r2).size == 3 }
    rows(@r2)
  end

  def test_r2_holds_what_r1_reports
    got = received
    assert_equal(%w[ipv4 ipv6 evpn], got.collect { |r| r['family'] })
    assert_equal([R1], got.collect { |r| r['peer'] }.uniq)
    v4 = got.first
    assert_equal('192.0.2.0/24', v4['prefix'])
    assert_equal([{ 'identifier' => R1, 'as' => 65_001, 'reason' => 3,
                    'reason_name' => 'RPKI Invalid', 'timestamp' => '2024-12-10T00:10:00.000Z' }],
                 v4['reporters'])
    assert_equal('65001', v4['as_path'])
    assert_equal([], v4['reporter_as_not_in_path'])
    evpn = got.last
    assert_equal(['127.0.0.1:100', 0, ['65001:100']],
                 [evpn['rd'], evpn['ethernet_tag'], evpn['route_targets']])
    assert_equal(['VTEP Unreachable', 100],
                 [evpn['reporters'].first['reason_name'], evpn['reporters'].first['evi']])
    # What r1 makes is shown on r1 with no peer.
    assert_equal([nil], rows(@r1).collect { |r| r['peer'] }.uniq)
    assert_equal(3, rows(@r1).size)
  end

  # The drafts' first MUST: nothing reaches the RIB.
  def test_no_report_reaches_the_rib
    received
    assert_equal(0, call(@r2, 'show.rib', 'limit' => 1000)['total'].to_i)
  end

  def test_report_and_clear_from_the_api
    received
    out = call(@r1, 'unreach.report', 'prefix' => '203.0.113.0/24', 'reason' => 'maintenance')
    assert_equal(1, out['announced'])
    wait_for('the new report') { rows(@r2, 'prefix' => '203.0.113.0/24').size == 1 }
    assert_equal('Maintenance', rows(@r2, 'prefix' => '203.0.113.0/24').first['reporters'].first['reason_name'])
    out = call(@r1, 'unreach.clear', 'prefix' => '192.0.2.0/24')
    assert_equal(1, out['withdrawn'])
    wait_for('the clear') { rows(@r2, 'prefix' => '192.0.2.0/24').empty? }
    # The running configuration says what is reported.
    assert_match(/203\.0\.113\.0/, call(@r1, 'show.configuration')['text'].to_s +
                                   call(@r1, 'show.configuration').to_s)
    e = assert_raise(BGP::Daemon::Client::Error) { call(@r1, 'unreach.clear', 'prefix' => '192.0.2.0/24') }
    assert_match(/no report of 192\.0\.2\.0\/24/, e.message)
  end

  def test_an_evpn_report_is_cleared_by_its_rd
    received
    call(@r1, 'unreach.clear', 'prefix' => '198.51.100.0/24', 'evpn' => { 'rd' => '127.0.0.1:100' })
    wait_for('the EVPN clear') { rows(@r2, 'family' => 'evpn').empty? }
  end

  def test_a_bad_report_is_refused_and_changes_nothing
    received
    e = assert_raise(BGP::Daemon::Client::Error) do
      call(@r1, 'unreach.report', 'prefix' => '203.0.113.0/24', 'reason' => 'no_such_reason')
    end
    assert_match(/no reason is named/, e.message)
    assert_equal(3, rows(@r1).size)
  end

  def test_the_session_going_down_takes_the_reports
    received
    call(@r2, 'peer.stop', 'peer' => R1)
    wait_for('r2 to drop the reports') { rows(@r2).empty? }
  end

  def test_events_for_what_arrives
    received
    kinds = call(@r2, 'api.info')['event_kinds']
    assert_include(kinds, 'unreachability')
    evs = call(@r2, 'show.log', 'limit' => 1000)
    assert_not_nil(evs)
  end

  def test_the_shell_prints_frr_words
    received
    sh = BGP::Daemon::Shell.new(BGP::Daemon::Client.new(@r2.api.path))
    out = sh.execute('show bgp ipv4 unreachability').text
    assert_match(/192\.0\.2\.0\/24, from 127\.0\.0\.1, AS path 65001/, out)
    assert_match(/Reporter 127\.0\.0\.1 +AS 65001 +RPKI Invalid \(3\) at 2024-12-10T00:10:00\.000Z/, out)
    assert_match(/RD 127\.0\.0\.1:100 tag 0 198\.51\.100\.0\/24/, sh.execute('show bgp l2vpn evpn unreachability').text)
    assert_match(/No ipv6 unreachability reports/, sh.execute('show bgp ipv6 unreachability 2001:db8:1::/48').text)
  end

end
