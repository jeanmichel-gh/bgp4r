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

require 'bgp/rib/route'
require 'bgp/rib/decision'

module BGP
  module Rib

    # Whether a route may go to one peer, and what its attributes become.
    #
    #   e = Export.new(local_as: 65001, router_id: '1.1.1.1')
    #   r = e.for(route, peer, next_hop: '10.0.0.1')
    #   r.advertise?      # false when this route must not go to this peer
    #   r.reason          # why: :no_advertise, :ibgp_to_ibgp, :ebgp ...
    #   r.path_attribute  # what to send, or nil
    #   r.next_hop        # the next hop chosen, for building MP_REACH_NLRI
    #
    # A pure function, like Decision#best: it reads a Route and a Peer and
    # returns a Result. It holds no Adj-RIB-Out, sends nothing, and never
    # changes the route it is given, so the whole of the export policy can
    # be tested with no session and no table. AdjRibOut records what was
    # sent; the Adj-RIB-Out and the UPDATE building are separate.
    #
    # **Reachability is not here.** The returned attributes never carry
    # MP_REACH_NLRI or MP_UNREACH_NLRI: which prefixes go in which UPDATE is
    # the sender's job, and it packs prefixes that share attributes into one
    # message. For a family that travels in MP_REACH_NLRI the sender needs
    # the next hop to put in it, which is why Result carries next_hop for
    # every route, IPv4 included.
    #
    # Every rule below was read in the RFC rather than recalled. What is
    # deliberately not here: confederations (RFC 5065), so a route whose
    # leftmost AS_PATH segment is a confederation segment is treated as the
    # RFC 4271 section 5.1.2 AS_SET case; and locally originated routes,
    # since every Route has a peer it was learned from.
    #
    # One thing RFC 4456 section 6 does not cover: a route from an EBGP
    # peer. Appendix B records that "the reference to EBGP routes/peers are
    # removed" from the document, so such a route goes to every internal
    # peer under the ordinary rules and is not reflection, which is why it
    # gets no ORIGINATOR_ID and no CLUSTER_LIST.
    class Export

      # path_attribute and next_hop are nil when the route is not sent.
      # reason is why: one of REFUSALS, or :ebgp or :ibgp when it is sent.
      Result = Struct.new(:path_attribute, :next_hop, :reason) do
        def advertise? ; !path_attribute.nil? ; end
      end

      # Why a route is not sent to a peer.
      #
      # :back_to_sender is not from an RFC. A route is not sent to the peer
      #   it was learned from, because that peer has it already.
      # :no_advertise, :no_export, :no_export_sub_confed are RFC 1997,
      #   "Well-known Communities", which has no numbered sections.
      # :ibgp_to_ibgp is the base IBGP rule RFC 4456 section 4 describes as
      #   the model it changes: IBGP speakers "will not re-advertise these
      #   IBGP learned routes to other IBGP speakers".
      # :non_client_to_non_client is a reflector obeying RFC 4456 section 6,
      #   which reflects a non-client's route to clients only. See clients?.
      # :policy is the caller's block returning nil.
      REFUSALS = %i[back_to_sender no_advertise no_export no_export_sub_confed
                    ibgp_to_ibgp non_client_to_non_client policy].freeze

      attr_reader :local_as, :router_id, :cluster_id, :default_local_pref

      # local_as, router_id: ours.
      # default_local_pref: the LOCAL_PREF to give a route that has none when
      #   it goes to an internal peer, since RFC 4271 section 5.1.5 says the
      #   attribute "SHALL be included in all UPDATE messages that a given
      #   BGP speaker sends to other internal peers".
      # route_reflector: true lets an IBGP learned route go to an internal
      #   peer, with the RFC 4456 section 8 attributes added.
      # clients: the addresses of our route reflection clients, as Strings or
      #   Peers. With none, every internal peer is treated as a client, which
      #   is the single cluster case and the one a script usually wants. See
      #   client? for what the list changes.
      # cluster_id: ours as a route reflector; defaults to router_id.
      # policy: a block taking (route, peer, path_attribute) and returning
      #   the attributes to send, a changed copy, or nil to refuse. It runs
      #   last, after every rule here.
      def initialize(local_as:, router_id:, default_local_pref: Decision::DEFAULT_LOCAL_PREF,
                     route_reflector: false, clients: nil, cluster_id: nil, policy: nil)
        @local_as = Integer(local_as)
        @router_id = IPAddr.new(router_id.to_s).to_s
        @default_local_pref = default_local_pref
        @route_reflector = route_reflector ? true : false
        @cluster_id = IPAddr.new((cluster_id || @router_id).to_s).to_s
        @policy = policy
        # A Hash rather than a Set, so this needs no require: Ruby keeps
        # moving standard libraries to bundled gems (see Conventions).
        @clients = nil
        unless clients.nil?
          @clients = {}
          Array(clients).each { |c| @clients[address_of(c)] = true }
        end
      end

      def route_reflector? ; @route_reflector ; end

      # True when peer is one of our route reflection clients.
      #
      # With no client list, every internal peer is one. RFC 4456 section 6
      # says "The Clients will be configured to maintain IBGP session only
      # with the RR in their cluster", so a speaker whose internal peers are
      # all clients is the ordinary single cluster, and it needs no list.
      # Give one as soon as some internal peers are not clients: section 6
      # also has "Each RR would be configured with other RRs as Non-Client
      # peers (thus all the RRs will be fully meshed)", and those are the
      # peers the list is for.
      def client?(peer)
        return false unless peer.ibgp?
        return true if @clients.nil?
        @clients.key?(address_of(peer))
      end

      # The client addresses, or nil when every internal peer is a client.
      def clients ; @clients && @clients.keys ; end

      # next_hop: our address on the session with peer. RFC 4271 section
      #   5.1.3: toward a peer one IP hop away "the BGP speaker SHOULD use
      #   the IP address of the interface that the speaker uses to establish
      #   the BGP connection". Export cannot know it, so the caller passes
      #   it. Required for an external peer: without it the only choices are
      #   to send the wrong next hop or to say so, and sending a next hop
      #   that is not ours is how a route becomes a black hole.
      def for(route, peer, next_hop: nil)
        # The refusals come first. A route that is not going to this peer
        # needs no next hop, so asking for one would turn a plain answer
        # into an exception.
        reason = refuse(route, peer)
        return Result.new(nil, nil, reason) if reason
        if peer.ebgp? and next_hop.nil?
          raise ArgumentError, "next_hop is required for the external peer #{peer}: " \
                               'RFC 4271 section 5.1.3 wants our address on that session'
        end

        hop = peer.ebgp? ? IPAddr.new(next_hop.to_s).to_s : route.next_hop
        pa = attributes(route, peer, hop)
        if @policy
          pa = @policy.call(route, peer, pa)
          return Result.new(nil, nil, :policy) if pa.nil?
        end
        Result.new(pa, hop, peer.ebgp? ? :ebgp : :ibgp)
      end

      private

      def refuse(route, peer)
        return :back_to_sender if route.peer == peer
        if route.path_attribute.has?(Communities)
          c = route.path_attribute[Communities]
          # RFC 1997: NO_ADVERTISE routes "MUST NOT be advertised to other
          # BGP peers", so this one is checked for every peer.
          return :no_advertise if c.has_no_advertise?
          if peer.ebgp?
            # NO_EXPORT "MUST NOT be advertised outside a BGP confederation
            # boundary", and a stand alone AS counts as one confederation,
            # so outside is an external peer. NO_EXPORT_SUBCONFED "MUST NOT
            # be advertised to external BGP peers".
            return :no_export if c.has_no_export?
            return :no_export_sub_confed if c.has_no_export_sub_confed?
          end
        end
        if route.peer.ibgp? and peer.ibgp?
          # RFC 4456 section 4, the model reflection changes.
          return :ibgp_to_ibgp unless @route_reflector
          # Section 6, the two rules it gives, as one condition. "A route
          # from a Non-Client IBGP peer: Reflect to all the Clients", so a
          # non-client's route goes only to a client. "A route from a Client
          # peer: Reflect to all the Non-Client peers and also to the Client
          # peers", so a client's route goes to either kind. What is left
          # over is non-client to non-client, and those are expected to be
          # fully meshed and to have the route already.
          unless client?(route.peer) or client?(peer)
            return :non_client_to_non_client
          end
        end
        nil
      end

      # A Peer or an address, as the address.
      def address_of(peer)
        peer.respond_to?(:address) ? peer.address : IPAddr.new(peer.to_s).to_s
      end

      # A copy, so the route keeps the attributes it was received with.
      # Path_attribute has no deep copy, and encode then parse is the idiom
      # Table#import already uses for the same reason.
      def attributes(route, peer, hop)
        pa = Path_attribute.new(route.path_attribute.encode(true), true)
        # Reachability belongs to the message, not to this.
        pa.delete(Mp_reach)
        pa.delete(Mp_unreach)
        peer.ebgp? ? to_external(pa, hop) : to_internal(pa, route)
        pa
      end

      def to_external(pa, hop)
        # RFC 4271 section 5.1.2, the four cases, all read from the section.
        prepend_as(pa)
        # Section 5.1.3: our address on this session.
        pa.delete(Next_hop)
        pa << Next_hop.new(hop)
        # Section 5.1.5: "A BGP speaker MUST NOT include this attribute in
        # UPDATE messages it sends to external peers."
        pa.delete(Local_pref)
        # Section 5.1.4: "The MULTI_EXIT_DISC attribute received from a
        # neighboring AS MUST NOT be propagated to other neighboring ASes."
        # A speaker may set a MED of its own toward this peer; that is the
        # policy block's business, not a rule.
        pa.delete(Multi_exit_disc)
        # RFC 4456 section 8 gives both of these to avoid loops inside the
        # local AS, and bgp4r marks both optional non-transitive, so neither
        # belongs in a message leaving the AS.
        pa.delete(Originator_id)
        pa.delete(Cluster_list)
      end

      def to_internal(pa, route)
        # Section 5.1.2: "the advertising speaker SHALL NOT modify the
        # AS_PATH attribute". Section 5.1.3: for a route that is not locally
        # originated the speaker "SHOULD NOT modify the NEXT_HOP attribute".
        # So neither is touched here.
        reflect(pa, route) if @route_reflector and route.peer.ibgp?
        # Section 5.1.5: LOCAL_PREF "SHALL be included in all UPDATE
        # messages that a given BGP speaker sends to other internal peers".
        # Import drops it from an external peer's route, so this is where a
        # route out of another AS gets one.
        pa << Local_pref.new(@default_local_pref) unless pa.has?(Local_pref)
      end

      # RFC 4456 section 8. The ORIGINATOR_ID carries the BGP Identifier of
      # the route's originator in the local AS, and a speaker "SHOULD NOT
      # create an ORIGINATOR_ID attribute if one already exists". The
      # reflector "MUST prepend the local CLUSTER_ID to the CLUSTER_LIST".
      def reflect(pa, route)
        pa << Originator_id.new(route.peer.router_id) unless pa.has?(Originator_id)
        ids = pa.has?(Cluster_list) ? pa[Cluster_list].cluster_ids : []
        pa.delete(Cluster_list)
        pa << Cluster_list.new(@cluster_id, *ids)
      end

      # RFC 4271 section 5.1.2, in the section's own order. Each new segment
      # is built rather than edited, so the route's own AS_PATH is untouched
      # even though this runs on a copy.
      def prepend_as(pa)
        unless pa.has?(As_path)
          pa << As_path.new(@local_as)
          return
        end
        old = pa[As_path].segments
        first = old.first
        pa.delete(As_path)
        if first.nil?
          # "if the AS_PATH is empty, the local system creates a path
          # segment of type AS_SEQUENCE, places its own AS into that
          # segment, and places that segment into the AS_PATH."
          pa << As_path.new(@local_as)
        elsif first.seg_type == As_path::SEQUENCE && first.as.size < 255
          # "if the first path segment of the AS_PATH is of type
          # AS_SEQUENCE, the local system prepends its own AS number as the
          # last element of the sequence (put it in the leftmost position
          # with respect to the position of octets in the protocol message)."
          grown = As_path::Segment.new(:sequence, @local_as, *first.as)
          pa << As_path.new(grown, *old[1..-1])
        else
          # An AS_SET first: "the local system prepends a new path segment
          # of type AS_SEQUENCE to the AS_PATH, including its own AS number
          # in that segment." And on overflow: "If the act of prepending
          # will cause an overflow in the AS_PATH segment (i.e., more than
          # 255 ASes), it SHOULD prepend a new segment of type AS_SEQUENCE
          # and prepend its own AS number to this new segment." Both come
          # out as a new leading AS_SEQUENCE, and so does a confederation
          # segment, which RFC 5065 would handle and bgp4r does not.
          pa << As_path.new(As_path::Segment.new(:sequence, @local_as), *old)
        end
      end
    end

  end
end
