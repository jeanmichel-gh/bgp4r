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

require 'bgp/path_attributes/attributes'
require 'bgp/path_attributes/validation'
require 'bgp/nlris/nlris'
require 'bgp/fault'

module BGP

  # The valid counterpart of BGP::Fault: one named, well formed,
  # representative object per path attribute and per address family, so
  # a test or a control plane can ask for a correct LARGE_COMMUNITIES
  # attribute or a correct BGP-LS NLRI by name.
  #
  # **Nothing in the library consults this catalog and nothing should.**
  # Building never validates, per Conventions, so these are
  # representatives and not a specification. An attribute absent from
  # here is not thereby invalid, and an entry here is no claim that the
  # library would refuse anything else. Read it as the positive half of
  # what `lab/fault_matrix.rb` sends, not as a definition of correct.
  #
  # It exists because `test/coverage_matrix.rb` measured something
  # nothing in the tree had said: twelve registered path attributes have
  # never been sent to a router at all, and three address families the
  # build gate accepts have never been seen by one. A thing with no name
  # cannot be sent by name, which is the whole of what this closes.
  #
  # The shape is Fault's, deliberately, so a reader who knows one knows
  # the other: a CATALOG of entries, then `names`, `catalog`, `build`
  # and `wire`.
  #
  # `Specimen.update` is the twin of `Fault.update` and shares its
  # envelope rather than copying it: both go through `Fault.wrap`, so
  # "which attributes does a plain UPDATE need" is answered once. It
  # waited for a caller, which `bgp4r-sim`'s `specimen` key is.
  module Specimen

    include ATTR

    # The two attributes that get no entry of their own. They are the
    # envelope every family entry below is built from, so a specimen for
    # either would be one of those under a second name, and a reader
    # comparing the catalog against `Attr.registrations` would find two
    # attributes covered twice and eleven families covered once.
    #
    # The guard reads this Hash, so an attribute removed from it has to
    # gain a catalog entry and one added to it has to lose one.
    ENVELOPES = {
      ATTR::MP_REACH   => 'the envelope every family specimen is built from',
      ATTR::MP_UNREACH => 'the same envelope, withdrawing rather than announcing',
    }.freeze

    # Each entry is [name, description, subject, a block that builds it].
    #
    # The subject is an Integer path attribute type code, or an [AFI,
    # SAFI] pair for an address family. One field and not two, because a
    # family specimen is an MP_REACH_NLRI and an MP_REACH_NLRI is
    # attribute 14: the two kinds of entry build the same kind of object,
    # so they share one catalog, one name space and one `build`. That is
    # the same polymorphism `Fault::CATALOG` already has, where a block
    # returns one attribute or a whole Path_attribute.
    #
    # There is no RFC field, which is where this differs from
    # `Fault::CATALOG` and the difference is not an omission. A fault
    # entry's citation is a real claim: the clause that makes those
    # octets malformed. A specimen's would only say where the attribute
    # is defined, which `bgp/iana.rb` and the attribute's own class
    # already say, and a third copy is a third thing to go stale.
    #
    # Every construction below was measured rather than recalled, on
    # 2026-11-03: each one builds, encodes, parses back byte for byte,
    # and reports nothing on either validation channel. Four of the
    # first drafts were wrong and the library was right every time, so
    # do not edit one of these from memory either.
    CATALOG = [

      # ---- path attributes -------------------------------------------

      [:origin,                    'ORIGIN igp',                                ATTR::ORIGIN,
        -> { Origin.new(:igp) }],
      [:as_path,                   'AS_PATH, one AS_SEQUENCE of two',           ATTR::AS_PATH,
        -> { As_path.new(65000, 65001) }],
      [:next_hop,                  'NEXT_HOP, one IPv4 address',                ATTR::NEXT_HOP,
        -> { Next_hop.new('10.0.0.1') }],
      [:multi_exit_disc,           'MULTI_EXIT_DISC 100',                       ATTR::MULTI_EXIT_DISC,
        -> { Multi_exit_disc.new(100) }],
      [:local_pref,                'LOCAL_PREF 100',                            ATTR::LOCAL_PREF,
        -> { Local_pref.new(100) }],
      [:atomic_aggregate,          'ATOMIC_AGGREGATE, an empty value',          ATTR::ATOMIC_AGGREGATE,
        -> { Atomic_aggregate.new }],
      [:aggregator,                'AGGREGATOR, a 2-octet AS and an address',   ATTR::AGGREGATOR,
        -> { Aggregator.new('10.0.0.1', 65000) }],
      [:communities,               'COMMUNITIES, one community',                ATTR::COMMUNITIES,
        -> { Communities.new('65000:100') }],
      [:originator_id,             'ORIGINATOR_ID, a router id',                ATTR::ORIGINATOR_ID,
        -> { Originator_id.new('10.0.0.1') }],
      [:cluster_list,              'CLUSTER_LIST, one cluster id',              ATTR::CLUSTER_LIST,
        -> { Cluster_list.new('10.0.0.1') }],
      [:extended_communities,      'EXTENDED COMMUNITIES, a two-octet-AS RT',   ATTR::EXTENDED_COMMUNITY,
        -> { Extended_communities.new(Route_target.new(65000, 100)) }],
      [:as4_path,                  'AS4_PATH, one segment of two 4-octet AS',   ATTR::AS4_PATH,
        -> { As4_path.new(70000, 70001) }],
      [:as4_aggregator,            'AS4_AGGREGATOR, a 4-octet AS',              ATTR::AS4_AGGREGATOR,
        -> { As4_aggregator.new('10.0.0.1', 70000) }],
      [:pmsi_tunnel,               'PMSI_TUNNEL, ingress replication',          ATTR::PMSI_TUNNEL,
        -> { Pmsi_tunnel.new(:ingress_replication, '10.0.0.1') }],
      [:tunnel_encap,              'TUNNEL ENCAPSULATION, a VXLAN tunnel',      ATTR::TUNNEL_ENCAP,
        -> { Tunnel_encap.new(:tunnel_type => :vxlan, :egress_endpoint => '10.0.0.1') }],
      [:ipv6_extended_communities, 'IPv6 EXTENDED COMMUNITIES, one RT',         ATTR::IPV6_EXTENDED_COMMUNITY,
        -> { Ipv6_extended_communities.new([:route_target, '2001:db8::1', 100]) }],
      [:aigp,                      'AIGP, one AIGP TLV',                        ATTR::ACCUMULATED_IGP_METRIC,
        -> { Aigp.new(100) }],
      # The one attribute whose specimen is only half a specimen on its
      # own. RFC 9552 section 5.3 pairs the BGP-LS Attribute with the
      # NLRI it describes, and these four TLVs are node attributes, so
      # the route this belongs on is the :bgp_ls family entry below.
      [:link_state,                'BGP-LS ATTRIBUTE, four node TLVs',          ATTR::BGP_LS,
        -> { Link_state_attribute.new(
               Link_state::Tlv::Node_flag_bits.new(:overload, :attached),
               Link_state::Tlv::Node_name.new('router1'),
               Link_state::Tlv::Isis_area_id.new(['490001'].pack('H*')),
               Link_state::Tlv::Ipv4_local_router_id.new('10.0.0.1')) }],
      [:large_communities,         'LARGE COMMUNITIES, one community',          ATTR::LARGE_COMMUNITY,
        -> { Large_communities.new('65000:1:100') }],
      [:otc,                       'ONLY_TO_CUSTOMER, one AS',                  ATTR::ONLY_TO_CUSTOMER,
        -> { Otc.new(65000) }],
      [:prefix_sid,                'BGP Prefix-SID, a Label-Index TLV',         ATTR::PREFIX_SID,
        -> { Prefix_sid.new(Prefix_sid::Label_index.new(100)) }],
      [:attr_set,                  'ATTR_SET carrying an ORIGIN',               ATTR::ATTR_SET,
        -> { Attr_set.new(65000, Path_attribute.new(Origin.new(0))) }],

      # ---- address families ------------------------------------------
      #
      # Each builds the MP_REACH_NLRI a correct announcement in that
      # family carries, with the next hop that family's own RFC asks
      # for. The next hop is why these are not interchangeable: it is
      # four octets here, twelve for the two VPN families that prepend a
      # zero Route Distinguisher, and read by length rather than by AFI
      # for EVPN, RT-constrain and MCAST-VPN.

      [:unicast,        'IPv4 unicast, one prefix',                [1, 1],
        -> { Mp_reach.new(:afi => 1, :safi => 1, :nexthop => '10.0.0.1',
                          :nlris => ['203.0.113.0/24']) }],
      [:multicast,      'IPv4 multicast, one prefix',              [1, 2],
        -> { Mp_reach.new(:afi => 1, :safi => 2, :nexthop => '10.0.0.1',
                          :nlris => ['203.0.113.0/24']) }],
      [:labelled,       'labelled unicast, one prefix and label',  [1, 4],
        -> { Mp_reach.new(:afi => 1, :safi => 4, :nexthop => '10.0.0.1',
                          :nlris => [{ :prefix => '203.0.113.0/24', :label => 100 }]) }],
      [:mcast_vpn,      'MCAST-VPN, an Intra-AS I-PMSI A-D route', [1, 5],
        -> { Mp_reach.new(:afi => 1, :safi => 5, :nexthop => ['10.0.0.1'],
                          :nlris => [{ :intra_as_i_pmsi =>
                                       { :rd => [100, 200], :originator => '10.0.0.1' } }]) }],
      [:evpn,           'EVPN, an Ethernet A-D per ES route',      [25, 70],
        -> { Mp_reach.new(:afi => 25, :safi => 70, :nexthop => '10.0.0.1',
                          :nlris => [Evpn.new(Evpn::Ethernet_ad.new(
                            [100, 200], '00:11:22:33:44:55:66:77:88:99', 100, 500))]) }],
      [:bgp_ls,         'BGP-LS, a Node NLRI',                     [16388, 71],
        -> { Mp_reach.new(:afi => 16388, :safi => 71, :nexthop => ['10.0.0.1'],
                          :nlris => [Specimen.link_state_node]) }],
      [:bgp_ls_vpn,     'BGP-LS VPN, the same Node NLRI with an RD', [16388, 72],
        -> { Mp_reach.new(:afi => 16388, :safi => 72, :nexthop => ['10.0.0.1'],
                          :nlris => [Specimen.link_state_node.merge(:rd => [100, 200])]) }],
      # SAFI 128 and 129 are two families and not one, which is easy to
      # miss because they share the RD-and-label encoding of RFC 4364
      # section 4.2: IANA names them Labeled VPN Unicast and Labeled VPN
      # Multicast. test/coverage_matrix.rb printed them as one row until
      # building these two found it.
      [:vpn,            'VPN-IPv4 unicast, an RD, a label and a prefix', [1, 128],
        -> { Mp_reach.new(:afi => 1, :safi => 128, :nexthop => '10.0.0.1',
                          :nlris => [{ :rd => Rd.new(100, 200),
                                       :prefix => '203.0.113.0/24', :label => 100 }]) }],
      [:vpn_multicast,  'VPN-IPv4 multicast, the same shape',      [1, 129],
        -> { Mp_reach.new(:afi => 1, :safi => 129, :nexthop => '10.0.0.1',
                          :nlris => [{ :rd => Rd.new(100, 200),
                                       :prefix => '203.0.113.0/24', :label => 100 }]) }],
      [:rt_constrain,   'RT-constrain, a 96-bit membership prefix', [1, 132],
        -> { Mp_reach.new(:afi => 1, :safi => 132, :nexthop => '10.0.0.1',
                          :nlris => [Rt_constrain.new(65000, [65000, 100])]) }],
      [:flow_spec,      'flow spec, a destination and a protocol', [1, 133],
        -> { Mp_reach.new(:afi => 1, :safi => 133,
                          :nlris => [{ :destination_prefix => '203.0.113.0/24',
                                       :ip_protocol => [[:eq, 6]] }]) }],
      [:flow_spec_vpn,  'VPN flow spec, the same rule with an RD', [1, 134],
        -> { Mp_reach.new(:afi => 1, :safi => 134,
                          :nlris => [{ :rd => [100, 200],
                                       :destination_prefix => '203.0.113.0/24' }]) }],

    ].freeze

    class << self

      # The Node NLRI the two BGP-LS entries share, as a Hash so the VPN
      # one can merge an RD into it. A Local Node Descriptors TLV is the
      # smallest Node NLRI RFC 9552 section 5.2 describes.
      def link_state_node
        { :node => { :protocol_id => 2, :identifier => 0,
                     :tlvs => [{ :local_node_descriptors =>
                                 [{ :autonomous_system => 65000 }] }] } }
      end

      # The specimen named in the catalog.
      def build(name)
        entry = CATALOG.find { |e| e[0] == name }
        raise ArgumentError, "unknown specimen #{name.inspect}, see Specimen::CATALOG" unless entry
        entry[3].call
      end

      # The specimen as wire octets, in the 4-octet AS form by default.
      #
      # **The as4byte argument is not decoration here, where it is for
      # `Fault.wire`.** Every fault case that is a single attribute is an
      # `Attr::Raw`, whose octets are already fixed, so Fault can call
      # `encode` with no argument and be right. A specimen is the real
      # attribute, so AS_PATH, AGGREGATOR, AS4_PATH, AS4_AGGREGATOR and
      # ATOMIC_AGGREGATE each write a different number of octets
      # depending on the session. Calling `encode` with no argument gives
      # the 2-octet form, and a reader parsing those octets with
      # `:as4byte => true` sees a segment overrunning its attribute: a
      # finding about the caller's mismatch, not about the specimen.
      # Measured, when the guard's first run reported exactly that.
      #
      # So the argument is passed through, and which attributes take one
      # is asked of the method rather than declared, because a list of
      # them here is a list that goes stale when an attribute grows one.
      #
      # **The question is the parameter's name and not the arity**, which
      # the first draft got wrong and which is the composition idiom
      # showing through: `ATTR#encode(value, value_fmt)` is the parent
      # that writes every attribute's framing, so a class that does not
      # override it, such as `Atomic_aggregate`, has an `encode` whose
      # first argument is the **value**. Passing true there died on
      # `undefined method 'size' for true`, three frames away from here.
      # Find which layer owns the field before editing, as Conventions
      # says; it applies to reflection too.
      def wire(name, as4byte = true)
        built = build(name)
        takes = built.method(:encode).parameters.first
        takes && takes.last == :as4byte ? built.encode(as4byte) : built.encode
      end

      # One specimen as a whole UPDATE, in `Fault.update`'s envelope and
      # with its arguments: ORIGIN, an AS_PATH of `my_as`, a NEXT_HOP
      # when one is given and the specimen has none, and `prefixes` as
      # the NLRI. A family specimen carries its own NLRI inside
      # MP_REACH_NLRI, so it is sent with no `prefixes` at all.
      #
      #   Specimen.update(:large_communities, :my_as => 65001,
      #                   :next_hop => '10.0.0.1', :prefixes => ['203.0.113.0/24'])
      #   Specimen.update(:evpn, :my_as => 65001)
      def update(name, arg = {})
        Fault.wrap(build(name), arg)
      end

      # The CATALOG entries, as Hashes. A family entry carries :afi and
      # :safi and an attribute entry carries :type, so a reader can tell
      # the two apart without knowing the subject field is polymorphic.
      def catalog
        CATALOG.collect { |name, desc, subject, build|
          h = { :name => name, :description => desc, :build => build }
          if subject.is_a?(Array)
            h.merge(:afi => subject[0], :safi => subject[1], :type => ATTR::MP_REACH)
          else
            h.merge(:type => subject)
          end
        }
      end

      # The catalog names, which is what a control plane lists and what
      # a caller of build or wire may pass.
      def names
        CATALOG.collect(&:first)
      end

      # The entries whose subject is a path attribute, as [name, type].
      def attributes
        CATALOG.reject { |e| e[2].is_a?(Array) }.collect { |e| [e[0], e[2]] }
      end

      # The entries whose subject is an address family, as
      # [name, afi, safi].
      def families
        CATALOG.select { |e| e[2].is_a?(Array) }.collect { |e| [e[0], *e[2]] }
      end

    end
  end

end
