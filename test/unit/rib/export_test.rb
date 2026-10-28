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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibExport < Test::Unit::TestCase

  LOCAL_AS = 65001
  OURS = '1.1.1.1'
  # Two external peers and two internal ones, as seen from LOCAL_AS.
  E1 = BGP::Rib::Peer.new(:address => '10.0.0.2', :remote_as => 65002,
                          :router_id => '2.2.2.2', :local_as => LOCAL_AS)
  E2 = BGP::Rib::Peer.new(:address => '10.0.0.3', :remote_as => 65003,
                          :router_id => '3.3.3.3', :local_as => LOCAL_AS)
  I1 = BGP::Rib::Peer.new(:address => '10.0.0.4', :remote_as => LOCAL_AS,
                          :router_id => '4.4.4.4', :local_as => LOCAL_AS)
  I2 = BGP::Rib::Peer.new(:address => '10.0.0.5', :remote_as => LOCAL_AS,
                          :router_id => '5.5.5.5', :local_as => LOCAL_AS)

  def setup
    @export = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS)
  end

  def route(peer, prefix = '10.1.0.0/16', attrs = nil)
    attrs ||= [BGP::Origin.new(0), BGP::Next_hop.new(peer.address),
               BGP::As_path.new(*(peer.ebgp? ? [peer.remote_as] : []))]
    BGP::Rib::Route.new(prefix, BGP::Path_attribute.new(*attrs), peer)
  end

  # RFC 4271 section 5.1.2, toward an external peer: the speaker prepends
  # its own AS number as the last element of the sequence, which is the
  # leftmost position in the octets.

  def test_as_path_is_prepended_toward_an_external_peer
    r = route(E1)
    res = @export.for(r, E2, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    assert_equal(:ebgp, res.reason)
    assert_equal('65001 65002', res.path_attribute[BGP::As_path].as_path)
    assert_equal('65002', r.path_attribute[BGP::As_path].as_path, 'the route itself is untouched')
  end

  # "if the AS_PATH is empty, the local system creates a path segment of
  # type AS_SEQUENCE, places its own AS into that segment".
  def test_an_empty_as_path_becomes_one_sequence_with_our_as
    r = route(I1, '10.1.0.0/16', [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4')])
    res = @export.for(r, E2, :next_hop => '10.0.0.1')
    assert_equal('65001', res.path_attribute[BGP::As_path].as_path)
  end

  # "if the first path segment of the AS_PATH is of type AS_SET, the local
  # system prepends a new path segment of type AS_SEQUENCE to the AS_PATH".
  def test_an_as_set_first_gets_a_new_sequence_in_front
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
             BGP::As_path.new(:set => [65010, 65011])]
    res = @export.for(route(E1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    segs = res.path_attribute[BGP::As_path].segments
    assert_equal([BGP::As_path::SEQUENCE, BGP::As_path::SET], segs.map(&:seg_type))
    assert_equal([65001], segs.first.as)
    assert_equal('65001 {65010, 65011}', res.path_attribute[BGP::As_path].as_path)
  end

  # "If the act of prepending will cause an overflow in the AS_PATH segment
  # (i.e., more than 255 ASes), it SHOULD prepend a new segment of type
  # AS_SEQUENCE and prepend its own AS number to this new segment."
  def test_a_full_segment_gets_a_new_sequence_rather_than_overflowing
    full = (1..255).to_a
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(*full)]
    res = @export.for(route(E1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    segs = res.path_attribute[BGP::As_path].segments
    assert_equal(2, segs.size, 'a second segment rather than a 256 AS one')
    assert_equal([65001], segs.first.as)
    assert_equal(255, segs.last.as.size)
  end

  def test_a_segment_with_room_is_grown_rather_than_split
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'),
             BGP::As_path.new(*(1..254).to_a)]
    res = @export.for(route(E1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    segs = res.path_attribute[BGP::As_path].segments
    assert_equal(1, segs.size)
    assert_equal(255, segs.first.as.size)
    assert_equal(65001, segs.first.as.first)
  end

  # Section 5.1.2: toward an internal peer "the advertising speaker SHALL
  # NOT modify the AS_PATH attribute associated with the route".
  def test_as_path_is_untouched_toward_an_internal_peer
    res = @export.for(route(E1), I1)
    assert_equal(:ibgp, res.reason)
    assert_equal('65002', res.path_attribute[BGP::As_path].as_path)
  end

  # Section 5.1.3: toward an external peer one hop away the speaker SHOULD
  # use the address of the interface it established the session on, which
  # Export cannot know, so the caller passes it.
  def test_the_next_hop_becomes_ours_toward_an_external_peer
    res = @export.for(route(E1), E2, :next_hop => '10.0.0.1')
    assert_equal('10.0.0.1', res.path_attribute[BGP::Next_hop].next_hop)
    assert_equal('10.0.0.1', res.next_hop)
  end

  def test_an_external_peer_without_a_next_hop_is_refused_loudly
    e = assert_raise(ArgumentError) { @export.for(route(E1), E2) }
    assert_match(/next_hop is required/, e.message)
    assert_match(/5\.1\.3/, e.message, 'and says which rule wants it')
  end

  # Section 5.1.3: for a route that is not locally originated the speaker
  # SHOULD NOT modify the NEXT_HOP toward an internal peer.
  def test_the_next_hop_is_untouched_toward_an_internal_peer
    res = @export.for(route(E1), I1)
    assert_equal('10.0.0.2', res.path_attribute[BGP::Next_hop].next_hop)
    assert_equal('10.0.0.2', res.next_hop)
  end

  # Section 5.1.5: "A BGP speaker MUST NOT include this attribute in UPDATE
  # messages it sends to external peers."
  def test_local_pref_never_goes_to_an_external_peer
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4'), BGP::Local_pref.new(300)]
    res = @export.for(route(I1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    assert(!res.path_attribute.has?(BGP::Local_pref))
  end

  # Section 5.1.5: it "SHALL be included in all UPDATE messages that a given
  # BGP speaker sends to other internal peers". Import drops it from an
  # external peer's route, so this is where one gets a LOCAL_PREF.
  def test_local_pref_is_added_toward_an_internal_peer
    res = @export.for(route(E1), I1)
    assert_equal(BGP::Rib::Decision::DEFAULT_LOCAL_PREF, res.path_attribute[BGP::Local_pref].to_i)
  end

  def test_an_existing_local_pref_is_kept_toward_an_internal_peer
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4'), BGP::Local_pref.new(300)]
    res = @export.for(route(I1, '10.1.0.0/16', attrs), I2)
    rr = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS, :route_reflector => true)
    assert_equal(:ibgp_to_ibgp, res.reason, 'not a reflector, so it does not go at all')
    kept = rr.for(route(I1, '10.1.0.0/16', attrs), I2)
    assert_equal(300, kept.path_attribute[BGP::Local_pref].to_i)
  end

  def test_the_default_local_pref_can_be_set
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS, :default_local_pref => 42)
    assert_equal(42, e.for(route(E1), I1).path_attribute[BGP::Local_pref].to_i)
  end

  # Section 5.1.4: "The MULTI_EXIT_DISC attribute received from a
  # neighboring AS MUST NOT be propagated to other neighboring ASes."
  def test_med_does_not_cross_into_another_as
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(65002),
             BGP::Multi_exit_disc.new(50)]
    r = route(E1, '10.1.0.0/16', attrs)
    assert(!@export.for(r, E2, :next_hop => '10.0.0.1').path_attribute.has?(BGP::Multi_exit_disc))
    assert_equal(50, @export.for(r, I1).path_attribute[BGP::Multi_exit_disc].to_i,
                 'but it does reach our own AS')
  end

  # RFC 1997, "Well-known Communities", which has no numbered sections.

  def test_no_advertise_stops_a_route_reaching_any_peer
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(65002),
             BGP::Communities.new(:no_advertise)]
    r = route(E1, '10.1.0.0/16', attrs)
    [[E2, '10.0.0.1'], [I1, nil]].each do |peer, hop|
      res = @export.for(r, peer, :next_hop => hop)
      assert(!res.advertise?, "sent to #{peer}")
      assert_equal(:no_advertise, res.reason)
    end
  end

  def test_no_export_stops_a_route_leaving_our_as_only
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(65002),
             BGP::Communities.new(:no_export)]
    r = route(E1, '10.1.0.0/16', attrs)
    assert_equal(:no_export, @export.for(r, E2, :next_hop => '10.0.0.1').reason)
    assert(@export.for(r, I1).advertise?, 'our own AS is inside the boundary')
  end

  def test_no_export_sub_confed_stops_a_route_reaching_an_external_peer
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(65002),
             BGP::Communities.new(:no_export_sub_confed)]
    r = route(E1, '10.1.0.0/16', attrs)
    assert_equal(:no_export_sub_confed, @export.for(r, E2, :next_hop => '10.0.0.1').reason)
    assert(@export.for(r, I1).advertise?)
  end

  def test_an_ordinary_community_stops_nothing_and_travels
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.2'), BGP::As_path.new(65002),
             BGP::Communities.new('65001:7')]
    res = @export.for(route(E1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    assert_equal('65001:7', res.path_attribute[BGP::Communities].communities)
  end

  # The base IBGP rule RFC 4456 section 4 describes: IBGP speakers "will not
  # re-advertise these IBGP learned routes to other IBGP speakers".

  def test_an_ibgp_route_does_not_go_to_another_ibgp_peer
    res = @export.for(route(I1), I2)
    assert(!res.advertise?)
    assert_equal(:ibgp_to_ibgp, res.reason)
  end

  def test_an_ibgp_route_does_go_to_an_external_peer
    assert(@export.for(route(I1), E2, :next_hop => '10.0.0.1').advertise?)
  end

  def test_an_ebgp_route_goes_to_an_ibgp_peer
    assert(@export.for(route(E1), I1).advertise?)
  end

  # A route is not sent back to the peer it came from. Not an RFC rule.
  def test_a_route_does_not_go_back_to_its_sender
    assert_equal(:back_to_sender, @export.for(route(E1), E1).reason)
    assert_equal(:back_to_sender, @export.for(route(I1), I1).reason)
  end

  # RFC 4456 section 8, the loop avoidance attributes a reflector adds.

  def reflector(cluster_id = nil)
    BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                         :route_reflector => true, :cluster_id => cluster_id)
  end

  def test_a_reflector_may_send_an_ibgp_route_to_an_ibgp_peer
    res = reflector.for(route(I1), I2)
    assert(res.advertise?)
    assert_equal(:ibgp, res.reason)
  end

  def test_a_reflector_adds_the_originator_id_and_the_cluster_list
    res = reflector.for(route(I1), I2)
    assert_equal('4.4.4.4', res.path_attribute[BGP::Originator_id].originator_id,
                 'the BGP Identifier of the originator in our AS')
    assert_equal([OURS], res.path_attribute[BGP::Cluster_list].cluster_ids,
                 'the CLUSTER_ID defaults to our router ID')
  end

  # "SHOULD NOT create an ORIGINATOR_ID attribute if one already exists."
  def test_an_existing_originator_id_is_left_alone
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4'),
             BGP::Originator_id.new('9.9.9.9')]
    res = reflector.for(route(I1, '10.1.0.0/16', attrs), I2)
    assert_equal('9.9.9.9', res.path_attribute[BGP::Originator_id].originator_id)
  end

  # "MUST prepend the local CLUSTER_ID to the CLUSTER_LIST."
  def test_the_cluster_id_is_prepended_to_an_existing_list
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4'),
             BGP::Cluster_list.new('8.8.8.8')]
    res = reflector('7.7.7.7').for(route(I1, '10.1.0.0/16', attrs), I2)
    assert_equal(['7.7.7.7', '8.8.8.8'], res.path_attribute[BGP::Cluster_list].cluster_ids)
  end

  def test_a_reflector_does_not_reflect_an_ebgp_route
    res = reflector.for(route(E1), I1)
    assert(res.advertise?)
    assert(!res.path_attribute.has?(BGP::Originator_id), 'it did not come from inside our AS')
    assert(!res.path_attribute.has?(BGP::Cluster_list))
  end

  # Both are optional non-transitive and exist to avoid loops inside the
  # local AS, so neither leaves it.
  def test_the_reflection_attributes_do_not_leave_our_as
    assert(BGP::Originator_id.new('9.9.9.9').is_optional?)
    assert(!BGP::Originator_id.new('9.9.9.9').is_transitive?)
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new('10.0.0.4'),
             BGP::Originator_id.new('9.9.9.9'), BGP::Cluster_list.new('8.8.8.8')]
    res = @export.for(route(I1, '10.1.0.0/16', attrs), E2, :next_hop => '10.0.0.1')
    assert(!res.path_attribute.has?(BGP::Originator_id))
    assert(!res.path_attribute.has?(BGP::Cluster_list))
  end

  # Reachability is the message's job, so it never comes back in the
  # attributes. Result#next_hop is what a sender puts in MP_REACH_NLRI.
  def test_reachability_attributes_are_stripped_and_the_next_hop_reported
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65002),
             BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2011:1::1'],
                               :nlris => ['2011:1::/32'])]
    r = BGP::Rib::Route.new('2011:1::/32', BGP::Path_attribute.new(*attrs), E1)
    res = @export.for(r, I1)
    assert(!res.path_attribute.has?(BGP::Mp_reach))
    assert_equal('2011:1::1', res.next_hop, 'unchanged toward an internal peer')
    out = @export.for(r, E2, :next_hop => '2011:9::1')
    assert_equal('2011:9::1', out.next_hop, 'and ours toward an external one')
    assert(!out.path_attribute.has?(BGP::Mp_reach))
  end

  def test_mp_unreach_is_stripped_too
    attrs = [BGP::Origin.new(0), BGP::As_path.new(65002),
             BGP::Mp_unreach.new(:afi => 2, :safi => 1, :nlris => ['2011:1::/32'])]
    r = BGP::Rib::Route.new('2011:1::/32', BGP::Path_attribute.new(*attrs), E1)
    assert(!@export.for(r, I1).path_attribute.has?(BGP::Mp_unreach))
  end

  # The recorded decision for this phase: no policy language, a Ruby block.

  def test_the_policy_block_may_refuse_a_route
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                             :policy => proc { |route, _peer, pa| route.prefix.start_with?('10.1') ? nil : pa })
    assert_equal(:policy, e.for(route(E1, '10.1.0.0/16'), I1).reason)
    assert(e.for(route(E1, '10.2.0.0/16'), I1).advertise?)
  end

  def test_the_policy_block_may_change_the_attributes
    e = BGP::Rib::Export.new(
          :local_as => LOCAL_AS, :router_id => OURS,
          :policy => proc { |_r, _peer, pa| pa << BGP::Communities.new('65001:9') ; pa })
    res = e.for(route(E1), I1)
    assert_equal('65001:9', res.path_attribute[BGP::Communities].communities)
  end

  # It runs last, so it sees what the rules already did and can undo it.
  def test_the_policy_block_runs_after_the_rules
    seen = nil
    e = BGP::Rib::Export.new(
          :local_as => LOCAL_AS, :router_id => OURS,
          :policy => proc { |_r, _peer, pa| seen = pa[BGP::As_path].as_path ; pa })
    e.for(route(E1), E2, :next_hop => '10.0.0.1')
    assert_equal('65001 65002', seen, 'our AS was already prepended')
  end

  def test_the_policy_block_is_not_run_for_a_route_the_rules_refused
    ran = false
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                             :policy => proc { |_r, _p, pa| ran = true ; pa })
    assert_equal(:ibgp_to_ibgp, e.for(route(I1), I2).reason)
    assert(!ran)
  end

  def test_cluster_id_defaults_to_the_router_id
    assert_equal(OURS, @export.cluster_id)
    assert_equal('7.7.7.7', reflector('7.7.7.7').cluster_id)
    assert(!@export.route_reflector?)
    assert(reflector.route_reflector?)
  end

  # RFC 4456 section 6, the client and non-client matrix. Two more internal
  # peers, so there is a non-client to refuse a route to.
  NC1 = BGP::Rib::Peer.new(:address => '10.0.0.6', :remote_as => LOCAL_AS,
                           :router_id => '6.6.6.6', :local_as => LOCAL_AS)
  NC2 = BGP::Rib::Peer.new(:address => '10.0.0.7', :remote_as => LOCAL_AS,
                           :router_id => '7.7.7.7', :local_as => LOCAL_AS)

  # I1 and I2 are the clients; NC1 and NC2 are other reflectors.
  def clustered
    BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                         :route_reflector => true,
                         :clients => [I1.address, I2.address])
  end

  def test_who_is_a_client
    e = clustered
    assert(e.client?(I1))
    assert(e.client?(I2))
    assert(!e.client?(NC1))
    assert(!e.client?(E1), 'an external peer is never a client')
    assert_equal(%w[10.0.0.4 10.0.0.5], e.clients.sort)
  end

  # "A route from a Client peer: Reflect to all the Non-Client peers and
  # also to the Client peers."
  def test_a_clients_route_goes_to_clients_and_non_clients
    e = clustered
    assert_equal(:ibgp, e.for(route(I1), I2).reason, 'to another client')
    assert_equal(:ibgp, e.for(route(I1), NC1).reason, 'and to a non-client')
  end

  # "A route from a Non-Client IBGP peer: Reflect to all the Clients."
  def test_a_non_clients_route_goes_only_to_clients
    e = clustered
    assert_equal(:ibgp, e.for(route(NC1), I1).reason, 'to a client')
    res = e.for(route(NC1), NC2)
    assert(!res.advertise?)
    assert_equal(:non_client_to_non_client, res.reason,
                 'the other reflectors are fully meshed and have it already')
  end

  # With no list every internal peer is a client, which is the single
  # cluster case: section 6 says "The Clients will be configured to
  # maintain IBGP session only with the RR in their cluster".
  def test_with_no_client_list_every_internal_peer_is_a_client
    e = reflector
    assert(e.client?(I1))
    assert(e.client?(NC1))
    assert_nil(e.clients)
    assert_equal(:ibgp, e.for(route(NC1), NC2).reason, 'so nothing is refused for being a non-client')
  end

  # Section 6 does not cover a route from an external peer: Appendix B says
  # "the reference to EBGP routes/peers are removed". So it goes to every
  # internal peer under the ordinary rules, and is not reflection.
  def test_an_external_route_reaches_a_non_client_and_is_not_reflected
    e = clustered
    res = e.for(route(E1), NC1)
    assert(res.advertise?)
    assert(!res.path_attribute.has?(BGP::Originator_id))
    assert(!res.path_attribute.has?(BGP::Cluster_list))
  end

  def test_a_client_may_be_given_as_a_peer_rather_than_an_address
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                             :route_reflector => true, :clients => [I1])
    assert(e.client?(I1))
    assert(!e.client?(I2))
  end

  # A client list without route_reflector changes nothing: the base rule
  # still stops an internal route at an internal peer.
  def test_a_client_list_alone_is_not_reflection
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                             :clients => [I1.address, I2.address])
    assert_equal(:ibgp_to_ibgp, e.for(route(I1), I2).reason)
  end

  def test_an_empty_client_list_means_no_clients_at_all
    e = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS,
                             :route_reflector => true, :clients => [])
    assert(!e.client?(I1))
    assert_equal([], e.clients)
    assert_equal(:non_client_to_non_client, e.for(route(I1), I2).reason,
                 'a reflector with no clients reflects nothing')
  end

  # Originating a route, RFC 4271 sections 5.1.1, 5.1.2 and 5.1.3. The
  # attributes are the ones Table#originate builds: an empty AS_PATH, and a
  # NEXT_HOP placeholder the export step replaces.

  LOCAL = BGP::Rib::LocalPeer.new(:local_as => LOCAL_AS, :router_id => OURS)

  def originated(prefix = '10.1.0.0/16')
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Next_hop.new(OURS))
    BGP::Rib::Route.new(prefix, pa, LOCAL)
  end

  def test_a_local_peer_is_us
    assert(LOCAL.local?)
    assert(LOCAL.ibgp?, 'in our own AS')
    assert(originated.local?)
    assert(!route(E1).local?)
  end

  # "the originating speaker includes its own AS number in a path segment,
  # of type AS_SEQUENCE, in the AS_PATH attribute of all UPDATE messages
  # sent to an external peer", and it is "the only entry the path segment,
  # and this path segment will be the only segment in the AS_PATH".
  def test_an_originated_route_carries_only_our_as_to_an_external_peer
    res = @export.for(originated, E1, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    segs = res.path_attribute[BGP::As_path].segments
    assert_equal(1, segs.size, 'the only segment')
    assert_equal(BGP::As_path::SEQUENCE, segs.first.seg_type)
    assert_equal([LOCAL_AS], segs.first.as, 'the only entry')
  end

  # "the originating speaker includes an empty AS_PATH attribute in all
  # UPDATE messages sent to internal peers", and "An empty AS_PATH attribute
  # is one whose length field contains the value zero."
  def test_an_originated_route_carries_an_empty_as_path_to_an_internal_peer
    res = @export.for(originated, I1, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    assert(res.path_attribute.has?(BGP::As_path), 'the attribute is there')
    assert(res.path_attribute[BGP::As_path].segments.empty?, 'and carries nothing')
    assert_equal('empty', res.path_attribute[BGP::As_path].as_path)
  end

  # Section 5.1.3: announcing a locally originated route to an internal
  # peer, where the route "is directly connected to the speaker", the
  # speaker "SHOULD use its own IP address for the NEXT_HOP attribute". So
  # unlike a route we learned, this one gets ours toward either kind of peer,
  # and the attribute says what Result#next_hop says.
  def test_an_originated_route_carries_our_next_hop_to_either_kind_of_peer
    [[E1, '10.0.0.1'], [I1, '10.0.0.1']].each do |peer, hop|
      res = @export.for(originated, peer, :next_hop => hop)
      assert_equal(hop, res.next_hop, "to #{peer}")
      assert_equal(hop, res.path_attribute[BGP::Next_hop].next_hop,
                   "the attribute agrees, to #{peer}")
    end
  end

  def test_an_originated_route_needs_a_next_hop_even_for_an_internal_peer
    e = assert_raise(ArgumentError) { @export.for(originated, I1) }
    assert_match(/a route we originated/, e.message)
  end

  # Section 5.1.3: "A route originated by a BGP speaker SHALL NOT be
  # advertised to a peer using an address of that peer as NEXT_HOP."
  def test_an_originated_route_is_not_sent_with_the_peers_own_address
    res = @export.for(originated, E1, :next_hop => E1.address)
    assert(!res.advertise?)
    assert_equal(:next_hop_is_the_peers_address, res.reason)
  end

  # The rule only binds a route we originated, so a route learned from one
  # peer may still reach another whose address happens to be its next hop.
  def test_the_rule_is_only_about_routes_we_originated
    attrs = [BGP::Origin.new(0), BGP::Next_hop.new(I1.address), BGP::Local_pref.new(100)]
    res = @export.for(route(I1, '10.1.0.0/16', attrs), I2)
    rr = BGP::Rib::Export.new(:local_as => LOCAL_AS, :router_id => OURS, :route_reflector => true)
    assert_equal(:ibgp_to_ibgp, res.reason, 'stopped for another reason entirely')
    assert(rr.for(route(I1, '10.1.0.0/16', attrs), I2).advertise?)
  end

  # Our own route goes to an internal peer without reflection: the base
  # IBGP rule is about re-advertising what another internal peer sent, and
  # ours came from nobody.
  def test_an_originated_route_reaches_an_internal_peer_without_reflection
    res = @export.for(originated, I1, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    assert_equal(:ibgp, res.reason)
    assert(!res.path_attribute.has?(BGP::Originator_id), 'and is not reflection')
    assert(!res.path_attribute.has?(BGP::Cluster_list))
  end

  # A reflector does not reflect its own route either.
  def test_a_reflector_does_not_reflect_its_own_route
    res = reflector.for(originated, I1, :next_hop => '10.0.0.1')
    assert(res.advertise?)
    assert(!res.path_attribute.has?(BGP::Originator_id))
    assert(!res.path_attribute.has?(BGP::Cluster_list))
  end

  # Section 5.1.5 still applies: an internal peer gets a LOCAL_PREF and an
  # external one does not.
  def test_local_pref_on_an_originated_route
    assert_equal(BGP::Rib::Decision::DEFAULT_LOCAL_PREF,
                 @export.for(originated, I1, :next_hop => '10.0.0.1')
                        .path_attribute[BGP::Local_pref].to_i)
    assert(!@export.for(originated, E1, :next_hop => '10.0.0.1')
                   .path_attribute.has?(BGP::Local_pref))
  end

  # A script may originate a route carrying NO_EXPORT, and the communities
  # still decide, since those are about the route and not about who sent it.
  def test_the_communities_still_apply_to_a_route_we_originated
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                                 BGP::Next_hop.new(OURS),
                                 BGP::Communities.new(:no_export))
    r = BGP::Rib::Route.new('10.1.0.0/16', pa, LOCAL)
    assert_equal(:no_export, @export.for(r, E1, :next_hop => '10.0.0.1').reason)
    assert(@export.for(r, I1, :next_hop => '10.0.0.1').advertise?)
  end
end
