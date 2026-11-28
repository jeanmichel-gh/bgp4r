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

require './test/lab_groups'

# Which test exercises which BGP feature, so a person can run everything
# about one feature across all three tiers:
#
#   ruby test/run_feature.rb evpn
#
# **This is a second axis and not a replacement for the first.** The test
# tree is laid out by source file, one test file per source file, which is
# what a person changing a class wants. `test/lab_groups.rb` is a third
# axis, by the binary a lab test needs, which is what CI wants: a job
# installs only gobgpd, or only FRR, or only Docker. This file is what a
# person *learning or exercising a feature* wants, and none of the three
# can answer the other two's question.
#
# **Features are tags and they overlap, where the groups in
# `lab_groups.rb` partition.** That difference is not a loose end; it is
# forced by the tree. A CI matrix must not run a file twice, so a lab
# file is in exactly one group. A feature set has no such constraint, and
# about a quarter of the files here genuinely carry two or more tags:
# `evpn_gobgp_test` is EVPN and interoperability both, `rd_test` is the
# Route Distinguisher of five families, and `validation_test` reaches
# seven. Forcing those into one tag each would mean choosing which
# feature's `run_feature.rb` silently misses them.
#
# **Nothing here is `:needs`.** What a tier needs to run is derived from
# `LabGroups`, which already knows: the group a lab file is in is the
# binary it wants. Restating it here would be a second copy to drift,
# which is the mistake `lab_groups.rb`'s own header records about keeping
# the grouping in the workflow.
#
# `test/unit/features_test.rb` is the guard. Every test file on disk must
# carry at least one tag, every tag must name a file that exists, and
# `docs/running-tests.md` must be what `test/features_doc.rb` generates.
# So a new test file fails the unit suite until it is tagged, and a tag
# added without regenerating the document fails it too.
module Features

  UNIT       = 'test/unit'
  FUNCTIONAL = 'test/functional'
  LAB        = 'test/functional/lab'

  # A test file that must never be run, with the reason. `run_feature.rb`
  # refuses it by name rather than leaving a comment to be ignored.
  # Empty since functional/live_feed_test.rb, which hung on a public feed
  # that no longer answers, was removed. An entry names a file that
  # exists; test/unit/features_test.rb checks it.
  NEVER = {}.freeze

  # The areas, in the order the document prints them. An area is a
  # heading and nothing more: the features do the work.
  AREAS = {
    'families'   => 'What bgp4r can carry: one per NLRI family',
    'attributes' => 'What it can say about a route',
    'session'    => 'Getting a session up and keeping it',
    'routing'    => 'Deciding and advertising routes',
    'errors'     => 'What a receiver makes of something wrong',
    'programs'   => 'The five executables',
    'contracts'  => 'Guards over the library and the suite, not over BGP',
  }.freeze

  FEATURES = {

    # ---- families ---------------------------------------------------

    'unicast' => {
      :area  => 'families',
      :about => 'IPv4 and IPv6 unicast, SAFI 1 and 2, and the prefix encodings',
      :rfc   => 'RFC 4271 section 4.3, RFC 4760',
      :unit  => %w[nlris/nlri_test nlris/inet_test nlris/prefix_test
                   nlris/nsap_test],
    },

    'labelled' => {
      :area  => 'families',
      :about => 'Labelled unicast, SAFI 4, and the label stack',
      :rfc   => 'RFC 8277',
      :unit  => %w[nlris/label_test nlris/labeled_test],
    },

    'vpn' => {
      :area  => 'families',
      :about => 'VPN-IPv4 and VPN-IPv6, SAFI 128 and 129, and the Route Distinguisher',
      :rfc   => 'RFC 4364 section 4.2',
      :unit  => %w[nlris/vpn_test nlris/rd_test],
    },

    'flow-spec' => {
      :area  => 'families',
      :about => 'Flow specification rules, SAFI 133 and 134',
      :rfc   => 'RFC 8955, RFC 8956',
      :doc   => 'docs/flow-spec.md',
      :unit  => %w[nlris/flow_spec_component_test nlris/flow_spec_test
                   flow_spec_doc_test],
      :functional => %w[flow_spec_test],
      :lab   => %w[flow_spec_gobgp_test flow_spec_frr_test],
    },

    'evpn' => {
      :area  => 'families',
      :about => 'EVPN, AFI 25 SAFI 70, all eleven route types',
      :rfc   => 'RFC 7432, RFC 9136, RFC 9251, RFC 9572',
      :doc   => 'docs/evpn.md',
      :unit  => %w[nlris/evpn_route_test nlris/evpn_test evpn_doc_test],
      :functional => %w[evpn_test],
      :lab   => %w[evpn_gobgp_test evpn_frr_test],
    },

    'rt-constrain' => {
      :area  => 'families',
      :about => 'Route Target membership, AFI 1 SAFI 132',
      :rfc   => 'RFC 4684 section 4',
      :unit  => %w[nlris/rt_constrain_test],
      :functional => %w[rt_constrain_test],
      :lab   => %w[rt_constrain_gobgp_test],
    },

    'unreachability' => {
      :area  => 'families',
      :about => 'Unreachability Information: AFI 1 and 2 SAFI 81 and EVPN route type 254, the codecs and bgp4rd',
      :rfc   => 'draft-tantsura-idr-unreachability-safi-06, draft-tantsura-bess-evpn-unreachability-02',
      :doc   => 'docs/unreachability.md',
      :unit  => %w[nlris/unreachability_test nlris/evpn_unreachability_test
                   daemon/unreachability_test gen/unreachability_routes_test],
      :functional => %w[unreachability_daemon_test unreachability_gen_test],
    },

    'mcast-vpn' => {
      :area  => 'families',
      :about => 'MCAST-VPN, SAFI 5, all seven route types',
      :rfc   => 'RFC 6514, RFC 6515, RFC 7441',
      :doc   => 'docs/mcast-vpn.md',
      :unit  => %w[nlris/mcast_vpn_route_test nlris/mcast_vpn_test
                   mcast_vpn_doc_test],
      :functional => %w[mcast_vpn_test],
      :lab   => %w[mcast_vpn_gobgp_test mcast_vpn_frr_test],
    },

    'bgp-ls' => {
      :area  => 'families',
      :about => 'BGP-LS, AFI 16388 SAFI 71 and 72, the NLRI and every attribute TLV',
      :rfc   => 'RFC 9552, RFC 9085, RFC 9086',
      :doc   => 'docs/bgp-ls.md',
      # The three attribute TLV files sit under nlris/ and belong to
      # path attribute 29. The directory is where the family lives, not
      # where the layer does.
      :unit  => %w[nlris/link_state_tlv_test nlris/link_state_test
                   nlris/link_state_nlri_test nlris/link_state_descriptor_test
                   nlris/link_state_link_descriptor_test
                   nlris/link_state_prefix_descriptor_test
                   nlris/link_state_node_attribute_test
                   nlris/link_state_link_attribute_test
                   nlris/link_state_prefix_attribute_test
                   nlris/link_state_sr_test
                   path_attributes/link_state_attribute_test
                   bgp_ls_doc_test
                   daemon/link_state_table_test daemon/link_state_producer_test
                   daemon/link_state_producer_ospf_test],
      :functional => %w[link_state_test link_state_daemon_test link_state_ospf_daemon_test],
      :lab   => %w[link_state_gobgp_test link_state_sr_gobgp_test
                   link_state_frr_test],
    },

    'add-path' => {
      :area  => 'families',
      :about => 'Several paths to one prefix, and the Path Identifier',
      :rfc   => 'RFC 7911',
      :unit  => %w[optional_parameters/add_path_test neighbor/add_path_cap_test],
      :functional => %w[add_path_test],
      :lab   => %w[add_path_gobgp_test add_path_topology_test],
    },

    # ---- attributes -------------------------------------------------

    'path-attributes' => {
      :area  => 'attributes',
      :about => 'The attribute container, the registry, and the well-known set',
      :rfc   => 'RFC 4271 section 5',
      :doc   => 'docs/building-objects.md',
      :unit  => %w[path_attributes/path_attribute_test
                   path_attributes/attribute_test path_attributes/raw_test
                   path_attributes/origin_test path_attributes/as_path_test
                   path_attributes/next_hop_test path_attributes/local_pref_test
                   path_attributes/multi_exit_disc_test
                   path_attributes/atomic_aggregate_test
                   path_attributes/aggregator_test
                   path_attributes/originator_id_test
                   path_attributes/cluster_list_test
                   path_attributes/as4_test path_attributes/aigp_test
                   path_attributes/otc_test],
    },

    'communities' => {
      :area  => 'attributes',
      :about => 'Communities, extended, IPv6 extended and large, and every sub-type',
      :rfc   => 'RFC 1997, RFC 4360, RFC 5701, RFC 8092',
      :unit  => %w[path_attributes/communities_test
                   path_attributes/extended_communities_test
                   path_attributes/extended_community_test
                   path_attributes/ipv6_extended_communities_test
                   path_attributes/large_communities_test],
    },

    'mp-reach' => {
      :area  => 'attributes',
      :about => 'MP_REACH_NLRI and MP_UNREACH_NLRI, the gates every family goes through',
      :rfc   => 'RFC 4760 sections 3 and 4, RFC 8950',
      :unit  => %w[path_attributes/mp_reach_test path_attributes/mp_unreach_test
                   nlris/mapped_ipv4_test],
    },

    'tunnel-encap' => {
      :area  => 'attributes',
      :about => 'Tunnel encapsulation and the PMSI tunnel',
      :rfc   => 'RFC 9012, RFC 6514 section 5',
      :unit  => %w[path_attributes/tunnel_encap_test path_attributes/pmsi_tunnel_test],
    },

    'segment-routing' => {
      :area  => 'attributes',
      :about => 'The BGP Prefix-SID',
      :rfc   => 'RFC 8669',
      :unit  => %w[path_attributes/prefix_sid_test],
    },

    'attr-set' => {
      :area  => 'attributes',
      :about => 'ATTR_SET, a path attribute set inside a path attribute',
      :rfc   => 'RFC 6368 section 5',
      :unit  => %w[path_attributes/attr_set_test],
      :lab   => %w[attr_set_gobgp_test],
    },

    # ---- session ----------------------------------------------------

    'open' => {
      :area  => 'session',
      :about => 'OPEN, the optional parameters, and every capability',
      :rfc   => 'RFC 4271 section 4.2, RFC 5492, RFC 9072',
      :unit  => %w[messages/open_test messages/capability_test
                   optional_parameters/optional_parameter_test
                   optional_parameters/capability_test
                   optional_parameters/as4_test optional_parameters/mbgp_test
                   optional_parameters/extended_nexthop_test
                   optional_parameters/graceful_restart_test
                   optional_parameters/dynamic_test
                   optional_parameters/role_test
                   optional_parameters/extended_message_test
                   optional_parameters/long_lived_graceful_restart_test],
      :lab   => %w[capabilities_frr_test],
    },

    'messages' => {
      :area  => 'session',
      :about => 'The common header, KEEPALIVE, UPDATE and NOTIFICATION',
      :rfc   => 'RFC 4271 section 4',
      :unit  => %w[messages/message_test messages/keepalive_test
                   messages/update_test messages/notification_test
                   messages/markers_test],
    },

    'route-refresh' => {
      :area  => 'session',
      :about => 'ROUTE-REFRESH and outbound route filtering',
      :rfc   => 'RFC 2918, RFC 7313, RFC 5291 section 4',
      :unit  => %w[messages/route_refresh_test
                   optional_parameters/route_refresh_test
                   optional_parameters/enhanced_route_refresh_test
                   optional_parameters/orf_test orfs/orf_test
                   orfs/prefix_orf_test],
    },

    'bfd' => {
      :area  => 'session',
      :about => 'bfd: true on a neighbor: a BFD session from bfd4r, and Cease 6/10 when it fails',
      :rfc   => 'RFC 5882 sections 4.1, 4.2 and 10.2, RFC 9384',
      :doc   => 'docs/bfd.md',
      :unit  => %w[daemon/bfd_test],
      :functional => %w[bfd_test],
      :lab   => %w[bfd_frr_lab_topology_test],
    },

    'end-of-rib' => {
      :area  => 'session',
      :about => 'end_of_rib on a neighbor: a marker per negotiated family after the first table; received ones recorded',
      :rfc   => 'RFC 4724 section 2',
      :doc   => 'docs/daemon.md',
      :unit  => %w[messages/markers_test daemon/end_of_rib_test daemon/vpn_reflector_test],
      :functional => %w[end_of_rib_test],
      :lab   => %w[end_of_rib_frr_test],
    },

    'route-refresh-answer' => {
      :area  => 'session',
      :about => 'a route refresh answered with the family\'s Adj-RIB-Out, between BoRR and EoRR to an enhanced peer; counted and published',
      :rfc   => 'RFC 2918 section 4, RFC 7313 section 4',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/refresh_test rib/router_test daemon/vpn_reflector_test],
      :functional => %w[route_refresh_test],
      :lab   => %w[route_refresh_frr_test],
    },

    'route-refresh-stale' => {
      :area  => 'session',
      :about => 'a BoRR marks the peer\'s routes of a family stale in every table, the EoRR or refresh_stale_time removes what is still stale; 7/1 for a wrong length',
      :rfc   => 'RFC 7313 sections 4 and 5',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/refresh_test rib/adj_rib_in_test rib/table_test rib/vpn_table_test rib/evpn_table_test
                   rib/vrf_ce_table_test daemon/link_state_table_test daemon/unreachability_test messages/message_test],
      :functional => %w[refresh_stale_test],
      :lab   => %w[route_refresh_frr_test],
    },

    'bmp-codec' => {
      :area  => 'session',
      :about => 'the BMP messages of RFC 7854 and RFC 9069, their findings, and BGP::Fault::BMP',
      :rfc   => 'RFC 7854 sections 4 and 5, RFC 9069 sections 4 and 5',
      :doc   => 'docs/bmp.md',
      :unit  => %w[bmp/messages_test bmp/validation_test fault_test to_hash_round_trip_test path_attributes/attribute_test],
    },

    'rpki-rtr' => {
      :area  => 'session',
      :about => 'the RTR PDUs of RFC 8210 and RFC 6810, their findings, and BGP::Fault::RTR',
      :rfc   => 'RFC 8210 sections 5, 7 and 12, RFC 6810 section 5.7',
      :doc   => 'docs/rpki.md',
      :unit  => %w[rtr/pdus_test rtr/validation_test fault_test to_hash_round_trip_test],
    },

    'rpki-origin-validation' => {
      :area  => 'routing',
      :about => "bgp4rd's rpki: key: an RTR client per cache, the VRPs of the preferred caches, and each unicast route's state, Valid, Invalid or NotFound",
      :rfc   => 'RFC 6811 sections 2 and 4, RFC 8210 sections 5 to 8, 10 and 12',
      :doc   => 'docs/rpki.md',
      :unit  => %w[rtr/client_test rtr/vrps_test daemon/rpki_test rtr/validation_test fault_test daemon/cli_doc_test],
      :functional => %w[rpki_daemon_test],
      :lab   => %w[rpki_frr_test],
    },

    'rpki-fault-matrix' => {
      :area  => 'session',
      :about => "BGP::Fault::RTR and the RTR behaviours against bgp4rd's RTR client and FRR's bgpd, and what each answered",
      :rfc   => 'RFC 8210 sections 6, 8 and 12',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[rtr/pdus_test fault_test],
      :functional => %w[rtr_fault_matrix_test rtr_cache_test],
      :lab   => %w[rtr_fault_frr_test],
    },

    'rpki-policy' => {
      :area  => 'routing',
      :about => "rpki:'s invalid: prefer_less and reject in the decision, a VRP change decided again, and mark_ibgp's origin validation state community",
      :rfc   => 'RFC 6811 sections 2 and 4, RFC 8097 section 2',
      :doc   => 'docs/rpki.md',
      :unit  => %w[rib/decision_test rib/table_test rib/export_test rib/view_test daemon/rpki_test],
      :functional => %w[rpki_policy_test],
    },

    'rpki-cache' => {
      :area  => 'programs',
      :about => 'bgp4r-rtr, an RTR cache: VRPs from a YAML file, Serial Notify on a change, and the RTR faults and behaviours from its HTTP API',
      :rfc   => 'RFC 8210 sections 5 to 8 and 12',
      :doc   => 'docs/rpki.md',
      :unit  => %w[rtr/cache_test fault_test sim/http_test daemon/server_test],
      :functional => %w[rtr_cache_test],
    },

    'bmp-station' => {
      :area  => 'programs',
      :about => 'bgp4r-bmp, a BMP station: a JSON line per message, and each router\'s peers and their pre-policy, post-policy and Loc-RIB routes from its HTTP API',
      :rfc   => 'RFC 7854 sections 3, 4.5 and 5, RFC 9069 section 5.4',
      :doc   => 'docs/bmp.md',
      :unit  => %w[bmp/station_test bmp/lines_doc_test path_attributes/mp_unreach_test],
      :functional => %w[bmp_station_test],
      :lab   => %w[bmp_frr_test],
    },

    'bmp-daemon' => {
      :area  => 'session',
      :about => 'bmp: in bgp4rd: each peer reported to BMP stations, a Peer Up with both OPENs, the Adj-RIB-In as received, each UPDATE, a Peer Down with its reason, stats and a Termination',
      :rfc   => 'RFC 7854 sections 3, 4.3 to 4.10 and 5',
      :doc   => 'docs/bmp.md',
      :unit  => %w[daemon/bmp_test bmp/routes_test bmp/station_test],
      :functional => %w[bmp_daemon_test],
      :lab   => %w[bmp_bgp4rd_frr_test],
    },

    'llgr' => {
      :area  => 'session',
      :about => 'long_lived_graceful_restart: the LLGR period after a peer restarts, LLGR_STALE and NO_LLGR, the llgr_stale step and the export rule, in the RIB and the VPN, EVPN, BGP-LS and unreachability tables',
      :rfc   => 'RFC 9494 sections 3 and 4',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/llgr_test rib/llgr_test rib/view_test daemon/graceful_restart_test rib/vpn_table_test rib/evpn_table_test daemon/link_state_table_test daemon/unreachability_test],
      :functional => %w[llgr_test],
      :lab   => %w[llgr_frr_test],
    },

    'route-refresh-faults' => {
      :area  => 'errors',
      :about => 'BGP::Fault::REFRESH and the borr_without_eorr behaviour, sent by bgp4r-sim, and what bgp4rd and FRR do',
      :rfc   => 'RFC 2918 section 4, RFC 7313 sections 4 and 5',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[fault_test sim/injector_test],
      :functional => %w[refresh_fault_matrix_test],
      :lab   => %w[route_refresh_fault_frr_test],
    },

    'graceful-restart' => {
      :area  => 'session',
      :about => 'graceful_restart on a neighbor: a helper, keeping a restarting peer\'s routes stale until its End-of-RIB, its Restart Time or stale_time; RFC 8538\'s N bit and Hard Reset',
      :rfc   => 'RFC 4724 sections 3 to 5, RFC 8538',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/graceful_restart_test rib/table_test rib/peer_adapter_test rib/peer_feed_test rib/vpn_table_test
                   rib/evpn_table_test rib/vrf_ce_table_test daemon/link_state_table_test daemon/unreachability_test
                   neighbor/neighbor_test daemon/refresh_test daemon/control_test],
      :functional => %w[graceful_restart_test],
      :lab   => %w[graceful_restart_frr_test],
    },

    'graceful-restart-faults' => {
      :area  => 'errors',
      :about => 'BGP::Fault::GR and the eleven gr_ behaviours, bgp4r-sim restarting as RFC 4724 and 8538 describe, and what bgp4rd and FRR do',
      :rfc   => 'RFC 4724 section 4.2, RFC 8538 sections 3.2, 4 and 4.1',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[fault_test sim/injector_test daemon/speaker_test optional_parameters/graceful_restart_test],
      :functional => %w[gr_fault_matrix_test],
      :lab   => %w[gr_fault_frr_test],
    },

    'llgr-faults' => {
      :area  => 'errors',
      :about => 'BGP::Fault::LLGR and the three llgr_ behaviours, bgp4r-sim restarting as RFC 9494 describes, and what bgp4rd and FRR do',
      :rfc   => 'RFC 9494 sections 3.1, 4.2 to 4.5',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[fault_test sim/injector_test optional_parameters/long_lived_graceful_restart_test],
      :functional => %w[llgr_fault_matrix_test],
      :lab   => %w[llgr_fault_frr_test],
    },

    'gtsm' => {
      :area  => 'session',
      :about => 'ttl_security on a neighbor: GTSM, sent at TTL 255, dropped below 256 - hops',
      :rfc   => 'RFC 5082 section 3',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/gtsm_test],
      :functional => %w[gtsm_test],
    },

    'tcp-md5' => {
      :area  => 'session',
      :about => 'password on a neighbor: TCP MD5, every segment signed, a missing or wrong digest dropped',
      :rfc   => 'RFC 2385 section 2',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/tcp_auth_test],
      :functional => %w[tcp_auth_test],
      :lab   => %w[md5_frr_test],
    },

    'tcp-ao' => {
      :area  => 'session',
      :about => 'tcp_ao on a neighbor: TCP-AO keys, every segment signed, the first key the one a session starts on',
      :rfc   => 'RFC 5925 section 3.1',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/tcp_auth_test],
      :functional => %w[tcp_auth_test],
      :lab   => %w[tcp_ao_gobgp_test],
    },

    'fsm' => {
      :area  => 'session',
      :about => 'The finite state machine, the TCP session and the two IO threads',
      :rfc   => 'RFC 4271 section 8',
      :unit  => %w[neighbor/neighbor_test io_test helpers/server_test],
    },

    # ---- routing ----------------------------------------------------

    'rib' => {
      :area  => 'routing',
      :about => 'Adj-RIB-In, the decision process and the Loc-RIB',
      :rfc   => 'RFC 4271 section 9',
      :unit  => %w[rib/route_test rib/adj_rib_in_test rib/decision_test
                   rib/loc_rib_test rib/table_test rib/peer_adapter_test
                   rib/peer_feed_test],
      :functional => %w[rib_feed_test],
    },

    'vpn-table' => {
      :area  => 'routing',
      :about => 'The VPN table: VPN-IPv4 and VPN-IPv6 routes received (SAFI 128), keyed on RD and prefix, best path per key, reflected between PEs',
      :rfc   => 'RFC 4364 sections 4.1 and 4.3',
      :unit  => %w[rib/vpn_route_test rib/vpn_table_test daemon/vpn_reflector_test],
      :functional => %w[vpn_daemon_test],
      :lab   => %w[vpn_frr_test],
    },

    'evpn-table' => {
      :area  => 'routing',
      :about => 'The EVPN table: types 2 and 3 received (AFI 25 SAFI 70), keyed on RD and RFC 7432 key fields, best path per key, show.evpn',
      :rfc   => 'RFC 7432 sections 7.2, 7.3; RFC 8365 section 5.1.3',
      :doc   => 'docs/design/evpn.md',
      :unit  => %w[rib/evpn_table_test],
      :functional => %w[evpn_daemon_test],
    },

    'macvrfs' => {
      :area  => 'routing',
      :about => 'MAC-VRFs: one per VNI, import by Route Target, flood VTEPs from type 3 and remote MACs from type 2 written into vtep4rd, show.macvrfs and show.macvrf',
      :rfc   => 'RFC 7432 sections 7.10, 9.2.1, 11.2, 15; RFC 8365 sections 5.1.2, 5.1.3; RFC 1982 section 3.2',
      :doc   => 'docs/design/evpn.md',
      :unit  => %w[rib/macvrf_test rib/macvrfs_test],
      :functional => %w[evpn_daemon_test],

      :lab   => %w[evpn_frr_test],
    },

    'evpn-export' => {
      :area  => 'routing',
      :about => 'EVPN export: type 3 per MAC-VRF and type 2 per local MAC, MAC Mobility sequences, duplicate MACs, the hold on a lost vtep4rd, evpn.clear_duplicate',
      :rfc   => 'RFC 7432 sections 7.7, 9.2.1, 11.2, 15, 15.1, 15.2; RFC 8365 section 5.1.3',
      :doc   => 'docs/design/evpn.md',
      :unit  => %w[daemon/evpn_exporter_test rib/macvrfs_test],
      :functional => %w[evpn_daemon_test],
      :lab   => %w[evpn_frr_test],
    },

    'evpn-reflector' => {
      :area  => 'routing',
      :about => 'EVPN route reflection: types 2 and 3 to clients with ORIGINATOR_ID and CLUSTER_LIST, next hop, labels and PMSI Tunnel kept',
      :rfc   => 'RFC 4456 sections 6 and 8; RFC 7432',
      :doc   => 'docs/design/evpn.md',
      :unit  => %w[daemon/evpn_reflector_test],
      :functional => %w[evpn_daemon_test],
    },

    'vrfs' => {
      :area  => 'routing',
      :about => "A PE's VRFs: import by Route Target, the mpls and gre transports, VRF routes in the kernel, export with a label per VRF, IPv6 over an IPv4 core, CEs by eBGP",
      :rfc   => 'RFC 4364 sections 4.3.1, 4.3.2, 5 and 7; RFC 8277 section 2.4; RFC 4659 sections 3.2 and 4; RFC 4360 section 5',
      :unit  => %w[rib/vrf_test rib/vpn_transport_test rib/vrf_fib_test rib/l3vpn_test daemon/vrf_sync_test daemon/vpn_exporter_test
                   rib/vrf_ce_table_test daemon/vrf_ce_exporter_test],
    },

    'export' => {
      :area  => 'routing',
      :about => 'The export rules, Adj-RIB-Out, UPDATE building and the MRAI timer',
      :rfc   => 'RFC 4271 sections 5.1 and 9.2.1.1, RFC 4456',
      :unit  => %w[rib/export_test rib/adj_rib_out_test rib/update_builder_test
                   rib/mrai_test rib/router_test],
      :functional => %w[rib_router_test],
      :lab   => %w[rib_router_gobgp_test rib_router_frr_test speaker_router_test
                   reflector_test rr_lab_topology_test],
    },

    'fib' => {
      :area  => 'routing',
      :about => 'Putting the Loc-RIB in a forwarding table, and packets following it',
      :unit  => %w[rib/fib_test rib/ip_route_test rib/fib_installer_test],
      :lab   => %w[fib_test fwd_lab_netns_test fwd_lab_topology_test],
    },

    'show' => {
      :area  => 'routing',
      :about => 'The three vendor styles, and the same state as plain data',
      :unit  => %w[rib/show_test rib/view_test],
    },

    # ---- errors -----------------------------------------------------

    'validation' => {
      :area  => 'errors',
      :about => 'Receive-side error handling, and the matrix of what three routers do',
      :rfc   => 'RFC 7606',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[path_attributes/validation_test],
      :lab   => %w[fault_matrix_native_test fault_matrix_frr_test
                   fault_matrix_test],
    },

    # specimen_test is tagged here as well as under contracts, which is
    # what overlapping tags are for: its last test pairs each fault case
    # against the valid specimen for the same attribute, so a fault case
    # whose rule went away fails there and nowhere else.
    'fault' => {
      :area  => 'errors',
      :about => 'Building the UPDATEs no RFC allows, and the catalog of them',
      :rfc   => 'RFC 7606',
      :doc   => 'docs/protocol-testing.md',
      :unit  => %w[fault_test specimen_test],
    },

    # ---- programs ---------------------------------------------------

    'daemon' => {
      :area  => 'programs',
      :about => 'bgp4rd and bgp4r-cli: the control socket, the views and the configuration',
      :doc   => 'docs/daemon.md',
      :unit  => %w[daemon/api_test daemon/client_test daemon/cli_test daemon/cli_doc_test daemon/shell_test
                   daemon/server_test daemon/views_test daemon/control_test
                   daemon/log_ring_test daemon/config_test
                   daemon/candidate_test daemon/speaker_test
                   daemon/community_keys_test daemon/hand_test sim/injector_test],
      :functional => %w[daemon_test routescope_api_test],
      :lab   => %w[reflector_test cease_frr_test],
    },

    'injector' => {
      :area  => 'programs',
      :about => 'bgp4r-sim: the eleven actions, the HTTP API and what it sent',
      :doc   => 'docs/daemon.md',
      :unit  => %w[sim/injector_test sim/http_test sim/server_test
                   sim/sent_test sim/views_test],
      :functional => %w[sim_test],
    },

    'routegen' => {
      :area  => 'programs',
      :about => 'Generating many prefixes and packing them into UPDATEs',
      :doc   => 'docs/daemon.md',
      :unit  => %w[misc/route_generator_test sim/routegen_test],
      :functional => %w[routegen_test],
      :lab   => %w[routegen_loopback_test routegen_test generate_test],
    },

    'console' => {
      :area  => 'programs',
      :about => 'An irb prompt on bgp4r: bgp4r console, routegen, sim and bgp4rd --interact',
      :doc   => 'docs/console.md',
      :unit  => %w[prompt_test sim/console_test sim/console_command_test daemon/console_test
                   daemon/hand_test console_examples_doc_test],
      :functional => %w[console_test console_examples_test],
    },

    'gen' => {
      :area  => 'programs',
      :about => 'bgp/gen: UPDATEs and withdrawals from a spec, and what they meant',
      :doc   => 'docs/route-generation.md',
      :unit  => %w[gen_test gen/spec_test gen/packer_test gen/unicast_test gen/vary_test gen/sender_test
                   gen/multicast_test gen/labelled_test gen/vpn_test gen/flow_rules_test gen/evpn_routes_test
                   gen/rt_constrain_routes_test gen/link_state_routes_test gen/mcast_vpn_routes_test gen/churn_test
                   daemon/community_keys_test daemon/hand_test sim/injector_test],
      :functional => %w[gen_test],
      :lab   => %w[gen_gobgp_test gen_frr_test],
    },

    'capture' => {
      :area  => 'programs',
      :about => 'Reading BGP off a wire or a pcap file, and bgp4r lab new',
      :doc   => 'docs/daemon.md',
      :unit  => %w[capture/pcap_test capture/stream_test capture/dissect_test
                   capture/cli_test capture/as4_test],
    },

    'speaker' => {
      :area  => 'programs',
      :about => 'lab/speaker.rb and the five topologies under lab/topologies',
      :doc   => 'docs/routescope-labs.md',
      :unit  => %w[lab_helper_test lab_bases_test],
      :lab   => %w[speaker_test two_speakers_test add_path_topology_test
                   bgp4r_lab_topology_test rr_lab_topology_test fwd_lab_topology_test],
    },

    'events' => {
      :area  => 'programs',
      :about => 'The structured event stream both programs serve',
      :unit  => %w[events_test observable_test],
    },

    'logging' => {
      :area  => 'programs',
      :about => 'The injected logger, the process log and the log level',
      :unit  => %w[logging_test],
      :lab   => %w[log_level_test],
    },

    # ---- contracts --------------------------------------------------

    'contracts' => {
      :area  => 'contracts',
      :about => 'The object contract, the hash round trips and the suite-wide guards',
      :doc   => 'docs/building-objects.md',
      :unit  => %w[building_objects_test to_hash_round_trip_test
                   lab_groups_test features_test coverage_matrix_test
                   specimen_test common_test iana_test],
    },

  }.freeze

  # What a tier needs before it can run. Derived, never restated: the
  # group a lab file is in is the binary it wants, and `lab_groups.rb`
  # already says which group. A unit or functional test needs nothing
  # beyond Ruby.
  NEEDS = {
    'compose'       => 'docker',
    'gobgp-matrix'  => 'gobgpd',
    'gobgp-families' => 'gobgpd',
    'gobgp-router'  => 'gobgpd',
    'gobgp4'        => 'gobgpd 4',
    'frr'           => 'frr',
    'reflector'     => 'gobgpd and frr',
    'local'         => 'nothing',
  }.freeze

  # The two lab files whose group says `nothing` and which want more:
  # they put routes in a real kernel table, so they omit themselves
  # without CAP_NET_ADMIN. `lab_groups.rb` records the same thing in
  # prose.
  ROOT_ONLY = %w[fib_test fwd_lab_netns_test].freeze

  class << self

    def names ; FEATURES.keys.sort ; end

    def areas ; AREAS.keys ; end

    # One feature, raising on a name that is not one rather than running
    # nothing and exiting 0, which reads as a pass.
    def feature(name)
      FEATURES[name] or
        raise ArgumentError,
          "unknown feature #{name.inspect}, have #{names.join(', ')}"
    end

    # The features of one area, in the order this file lists them.
    def in_area(area)
      AREAS.key?(area) or
        raise ArgumentError,
          "unknown area #{area.inspect}, have #{areas.join(', ')}"
      FEATURES.select { |_, f| f[:area] == area }.keys
    end

    # The paths of one tier of one feature, relative to the repository
    # root. An empty Array where the feature has no test in that tier.
    def files(name, tier)
      dir = { :unit => UNIT, :functional => FUNCTIONAL, :lab => LAB }.fetch(tier)
      Array(feature(name)[tier]).sort.collect { |f| "#{dir}/#{f}.rb" }
    end

    # Every path of one feature, in the order the tiers are run: cheapest
    # and most local first.
    def all_files(name)
      %i[unit functional lab].flat_map { |t| files(name, t) }
    end

    # What that lab file needs, as a word from `LabGroups`' own
    # vocabulary. `nil` for a unit or functional file, and for a lab file
    # in no group, which the guard refuses.
    #
    # **The path decides, not the basename**, because two tiers share
    # one: `test/unit/daemon/speaker_test.rb` and
    # `test/functional/lab/speaker_test.rb` are different files with the
    # same name, and asking `LabGroups` about the first answered for the
    # second. Found by `test_a_unit_or_functional_file_needs_nothing`.
    def needs(path)
      return nil unless path.start_with?("#{LAB}/")
      base = File.basename(path, '.rb')
      return 'root' if ROOT_ONLY.include?(base)
      g = LabGroups.group_of(base)
      g && NEEDS[g]
    end

    # Every test file on disk, as a path, both tiers and the lab. This is
    # a glob, so the guard sees a new file the day it lands.
    def present
      (Dir["#{UNIT}/**/*_test.rb"] +
       Dir["#{FUNCTIONAL}/*_test.rb"] +
       Dir["#{LAB}/*_test.rb"]).sort
    end

    # The features a path carries, which is usually one and is sometimes
    # several: a tag set, not a partition. Empty for a file nothing tags,
    # which is what the guard fails on.
    def features_of(path)
      names.select { |n| all_files(n).include?(path) }
    end

    # The paths no feature tags, excluding the ones that must never run.
    def untagged
      present.reject { |p| never?(p) || features_of(p).any? }
    end

    # Every path a feature names that is not on disk, so a rename fails
    # rather than quietly running one file fewer.
    def missing
      names.flat_map { |n| all_files(n) }.uniq.reject { |p| File.exist?(p) }
    end

    def never?(path)
      key = path.sub(%r{\Atest/}, '').sub(/\.rb\z/, '')
      NEVER.key?(key)
    end

    def never_reason(path)
      NEVER[path.sub(%r{\Atest/}, '').sub(/\.rb\z/, '')]
    end

  end

end
