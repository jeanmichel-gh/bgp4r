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
  # refuses it by name rather than leaving a comment to be ignored:
  # CLAUDE.md and the CI workflow each say not to run this one, and
  # neither can stop anybody.
  NEVER = {
    'functional/live_feed_test' =>
      'connects to a public feed that no longer answers and hangs forever',
  }.freeze

  # The areas, in the order the document prints them. An area is a
  # heading and nothing more: the features do the work.
  AREAS = {
    'families'   => 'What bgp4r can carry: one per NLRI family',
    'attributes' => 'What it can say about a route',
    'session'    => 'Getting a session up and keeping it',
    'routing'    => 'Deciding and advertising routes',
    'errors'     => 'What a receiver makes of something wrong',
    'programs'   => 'The four executables',
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
      :rfc   => 'RFC 9552',
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
                   path_attributes/link_state_attribute_test
                   bgp_ls_doc_test
                   daemon/link_state_table_test daemon/link_state_producer_test
                   daemon/link_state_producer_ospf_test],
      :functional => %w[link_state_test link_state_daemon_test link_state_ospf_daemon_test],
      :lab   => %w[link_state_gobgp_test link_state_frr_test],
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
      :unit  => %w[daemon/api_test daemon/client_test daemon/cli_test daemon/cli_doc_test
                   daemon/server_test daemon/views_test daemon/control_test
                   daemon/log_ring_test daemon/config_test
                   daemon/candidate_test daemon/speaker_test
                   daemon/community_keys_test daemon/hand_test sim/injector_test],
      :functional => %w[daemon_test],
      :lab   => %w[reflector_test],
    },

    'injector' => {
      :area  => 'programs',
      :about => 'bgp4r-sim: the ten actions, the HTTP API and what it sent',
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
                   capture/cli_test],
    },

    'speaker' => {
      :area  => 'programs',
      :about => 'lab/speaker.rb and the five topologies under lab/topologies',
      :doc   => 'docs/routescope-labs.md',
      :unit  => %w[lab_helper_test],
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

    # One file, and it earns a feature of its own because of its twin.
    # `bgp/misc/live_feed.rb` is a client for a public feed that no
    # longer answers. The unit test runs happily, since it never dials;
    # the functional one hangs forever and is in NEVER above. Keeping the
    # pair under one name is what makes that asymmetry visible instead of
    # being a comment in two other files.
    'live-feed' => {
      :area  => 'programs',
      :about => 'The client for an old public BGP feed, whose functional twin must never run',
      :unit  => %w[misc/live_feed_test],
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
