# The two-speakers checks, shared by the loopback and the Docker test.
# The including class sets @lab, and defines r1_addr and r2_addr: the
# address each node sees its peer at, which is also the expected next hop.

require 'test/unit'
require_relative 'lab_helper'

module TwoSpeakersScenario
  include LabHelper

  R1_ROUTES = ['192.168.1.0/24', '192.168.11.0/24']
  R2_ROUTES = ['192.168.2.0/24']

  def teardown
    puts "\n#{@lab.logs}" unless passed?
  end

  def test_1_sessions_establish
    n1 = wait_established(@lab, 'r1', r2_addr)
    n2 = wait_established(@lab, 'r2', r1_addr)
    assert_equal(65002, n1['peer_as'])
    assert_equal('10.10.0.2', n1['peer_router_id'])
    assert_equal(65001, n2['peer_as'])
    assert_equal('10.10.0.1', n2['peer_router_id'])
  end

  def test_2_routes_cross_with_ebgp_attributes
    n2 = wait_routes(@lab, 'r2', r1_addr, R1_ROUTES)
    R1_ROUTES.each do |p|
      r = n2['received'][p]
      assert_equal('65001', r['as_path'], "AS_PATH of #{p}: r1 prepends its AS over eBGP")
      assert_equal(r1_addr, r['next_hop'], "NEXT_HOP of #{p}: r1 sets itself over eBGP")
      assert_equal(10, r['med'])
      assert_equal('65001:100', r['communities'])
      assert_nil(r['local_pref'], 'LOCAL_PREF is not sent over eBGP')
    end
    n1 = wait_routes(@lab, 'r1', r2_addr, R2_ROUTES)
    r = n1['received']['192.168.2.0/24']
    assert_equal('65002', r['as_path'])
    assert_equal(r2_addr, r['next_hop'])
    assert_nil(r['med'])
  end

  def test_3_peer_stop_is_seen_and_session_returns
    wait_routes(@lab, 'r1', r2_addr, R2_ROUTES)
    @lab.stop('r2')
    # A clean close must end the session at once, not after the hold time.
    wait_for('r1 to drop the session and the routes after r2 stops', timeout: 10) do
      n = neighbor(@lab, 'r1', r2_addr)
      n && n['state'] != 'Established' && n['received'].empty?
    end
    @lab.start('r2')
    n1 = wait_routes(@lab, 'r1', r2_addr, R2_ROUTES)
    assert_equal('Established', n1['state'])
    assert_operator(n1['established_count'], :>=, 2)
  end
end
