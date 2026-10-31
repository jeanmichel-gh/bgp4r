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

require 'bgp/path_attributes/attribute'

module BGP

  class Attr

    # One problem with one path attribute.
    #
    # type     the attribute type code, nil when the header itself is cut
    # subcode  the UPDATE Message Error subcode (RFC 4271 section 6.3),
    #          nil when no NOTIFICATION applies
    # action   what RFC 7606 says a receiver does: :session_reset,
    #          :treat_as_withdraw or :attribute_discard. nil when the
    #          finding is not an error a peer would act on.
    # reason   plain words, with the RFC section
    Finding = Struct.new(:type, :subcode, :action, :reason) do
      def to_s
        "attribute #{type || '?'}: #{reason}" + (action ? " (#{action})" : '')
      end
      # The NOTIFICATION a session reset sends (RFC 4271 section 6.3).
      def notification
        Notification.new(3, subcode) if subcode
      end
    end

    # One attribute bgp4r itself could not decode, kept as an Attr::Raw.
    #
    # This is not a protocol error and deliberately not a Finding. RFC
    # 7606 section 7 lists, attribute by attribute, what makes one
    # malformed, and "the receiver has no code for this address family"
    # is on none of those lists. The four approaches of RFC 7606 section
    # 2 are all answers to a peer's mistake, and RFC 4271 section 5 has a
    # receiver accept an attribute it does not recognize rather than
    # complain about it. So a Gap never reaches Path_attribute#errors,
    # and the :strict policy never raises on one: bgp4r's coverage is
    # bgp4r's business, and a conformance tool that calls its own gap a
    # protocol error gives a wrong verdict about a correct router.
    #
    # It carries no action, no subcode and no notification, so it cannot
    # be fed to Attr.strongest or to Malformed_attribute by accident.
    #
    # type       the attribute type code
    # reason     what the decoder raised, in its own words
    # error      the exception class it raised
    # attribute  the Attr::Raw that holds the octets
    Gap = Struct.new(:type, :reason, :error, :attribute) do
      def to_s
        "attribute #{type || '?'}: bgp4r could not decode it: #{reason}"
      end
    end

    # The RFC 7606 section 3 (h) order: the strongest action wins.
    ACTIONS = [:attribute_discard, :treat_as_withdraw, :session_reset]

    def self.strongest(findings)
      findings.select(&:action).max_by { |f| ACTIONS.index(f.action) }
    end

    # The checks bgp4r runs on received attributes, and on built ones
    # with Path_attribute#validate. Encoding never runs them: bgp4r must
    # be able to send anything.
    module Check

      include ATTR

      TAW     = :treat_as_withdraw
      DISCARD = :attribute_discard
      RESET   = :session_reset

      # The Optional and Transitive bits each known attribute must have.
      FLAGS = {
        ORIGIN           => TRANSITIVE,
        AS_PATH          => TRANSITIVE,
        NEXT_HOP         => TRANSITIVE,
        MULTI_EXIT_DISC  => OPTIONAL,
        LOCAL_PREF       => TRANSITIVE,
        ATOMIC_AGGREGATE => TRANSITIVE,
        AGGREGATOR       => OPTIONAL | TRANSITIVE,
        COMMUNITIES      => OPTIONAL | TRANSITIVE,
        ORIGINATOR_ID    => OPTIONAL,
        CLUSTER_LIST     => OPTIONAL,
        MP_REACH         => OPTIONAL,
        MP_UNREACH       => OPTIONAL,
        EXTENDED_COMMUNITY => OPTIONAL | TRANSITIVE,
        AS4_PATH         => OPTIONAL | TRANSITIVE,
        AS4_AGGREGATOR   => OPTIONAL | TRANSITIVE,
        ACCUMULATED_IGP_METRIC => OPTIONAL,
        LARGE_COMMUNITY  => OPTIONAL | TRANSITIVE,
        ONLY_TO_CUSTOMER => OPTIONAL | TRANSITIVE,
        IPV6_EXTENDED_COMMUNITY => OPTIONAL | TRANSITIVE,
        PREFIX_SID       => OPTIONAL | TRANSITIVE,
        PMSI_TUNNEL      => OPTIONAL | TRANSITIVE,
        TUNNEL_ENCAP     => OPTIONAL | TRANSITIVE,
        ATTR_SET         => OPTIONAL | TRANSITIVE,   # RFC 6368 section 5
      }

      extend self

      # Splits the next attribute off s. Returns [bytes, finding]: the
      # attribute's octets, and a Finding when the header is cut or the
      # length runs past the end of s (RFC 7606 section 4). Then bytes
      # is all of s.
      def next_attribute(s)
        flags = s.getbyte(0)
        hdr = (flags & 0x10) > 0 ? 4 : 3
        left = s.size
        if left < hdr
          f = Finding.new(nil, 1, TAW,
            "only #{left} octets left for an attribute header of #{hdr} (RFC 7606 section 4)")
          return [s.slice!(0, left).is_packed, f]
        end
        len = hdr == 4 ? s.unpack('xxn')[0] : s.getbyte(2)
        if hdr + len > left
          f = Finding.new(s.getbyte(1), 1, TAW,
            "length #{len} runs past the attribute list, #{left - hdr} octets left (RFC 7606 section 4)")
          return [s.slice!(0, left).is_packed, f]
        end
        [s.slice!(0, hdr + len).is_packed, nil]
      end

      # Findings for one attribute's exact octets. With exact: true
      # (validate), a length field shorter than the value is reported.
      # With flags: false, the flags are not checked (see flags_finding).
      def attribute(bytes, as4byte = false, exact: false, flags: true)
        flags = bytes.getbyte(0) >> 4
        type  = bytes.getbyte(1)
        hdr   = (flags & EXTENDED_LENGTH) > 0 ? 4 : 3
        return [Finding.new(type, 1, TAW, "attribute header cut (RFC 7606 section 4)")] if bytes.size < hdr
        len   = hdr == 4 ? bytes.unpack('xxn')[0] : bytes.getbyte(2)
        value = bytes.byteslice(hdr, bytes.size - hdr)
        out = []
        if len > value.size
          out << Finding.new(type, 1, TAW, "length #{len} but #{value.size} value octets (RFC 7606 section 4)")
        elsif exact and len < value.size
          out << Finding.new(type, 1, TAW, "length #{len} but #{value.size} value octets follow")
        end
        value = value.byteslice(0, len) if len < value.size
        if (f = flags_finding(type, flags)) then out << f end
        if (f = value_finding(type, value, as4byte)) then out << f end
        out
      end

      # RFC 7606 section 3 (c), and RFC 4271 section 6.3 for an
      # unrecognized well-known attribute.
      def flags_finding(type, flags)
        want = FLAGS[type]
        if want.nil?
          return nil if (flags & OPTIONAL) > 0
          return Finding.new(type, 2, RESET,
            "unrecognized well-known attribute (RFC 4271 section 6.3)")
        end
        got = flags & (OPTIONAL | TRANSITIVE)
        return nil if got == want
        Finding.new(type, 4, TAW,
          format("flags 0x%x, the Optional and Transitive bits must be 0x%x (RFC 7606 section 3 (c))", flags << 4, want << 4))
      end

      # RFC 7606 section 7, per attribute.
      def value_finding(type, v, as4byte)
        n = v.size
        case type
        when ORIGIN
          return Finding.new(type, 5, TAW, "length #{n}, must be 1 (RFC 7606 section 7.1)") if n != 1
          return Finding.new(type, 6, TAW, "undefined ORIGIN value #{v.getbyte(0)} (RFC 7606 section 7.1)") if v.getbyte(0) > 2
        when AS_PATH
          return as_path_finding(type, v, as4byte ? 4 : 2, TAW, '7606 section 7.2', false)
        when AS4_PATH
          return as_path_finding(type, v, 4, DISCARD, '6793 section 6', true)
        when NEXT_HOP
          return fixed(type, n, 4, TAW, '7606 section 7.3', 5)
        when MULTI_EXIT_DISC
          return fixed(type, n, 4, TAW, '7606 section 7.4', 5)
        when LOCAL_PREF
          # From an external peer the attribute is discarded whatever
          # its length (section 7.5); bgp4r does not know the peer here.
          return fixed(type, n, 4, TAW, '7606 section 7.5', 5)
        when ATOMIC_AGGREGATE
          return fixed(type, n, 0, DISCARD, '7606 section 7.6', 5)
        when AGGREGATOR
          return fixed(type, n, as4byte ? 8 : 6, DISCARD, '7606 section 7.7', 5)
        when AS4_AGGREGATOR
          return fixed(type, n, 8, DISCARD, '6793 section 6', 5)
        when COMMUNITIES
          return multiple(type, n, 4, TAW, '7606 section 7.8')
        when ORIGINATOR_ID
          return fixed(type, n, 4, TAW, '7606 section 7.9', 5)
        when CLUSTER_LIST
          return multiple(type, n, 4, TAW, '7606 section 7.10')
        when EXTENDED_COMMUNITY
          return multiple(type, n, 8, TAW, '7606 section 7.14')
        when LARGE_COMMUNITY
          return multiple(type, n, 12, TAW, '8092 section 6')
        when ONLY_TO_CUSTOMER
          return fixed(type, n, 4, TAW, '9234 section 5', 5)
        when IPV6_EXTENDED_COMMUNITY
          return multiple(type, n, 20, TAW, '7606 section 7.15')
        when PREFIX_SID
          return prefix_sid_finding(type, v)
        when TUNNEL_ENCAP
          return tunnel_encap_finding(type, v)
        when PMSI_TUNNEL
          # RFC 6514 section 5: flags, tunnel type, a 3 octet label, then
          # the tunnel identifier.
          return Finding.new(type, 5, TAW, "length #{n}, needs at least 5 (RFC 6514 section 5)") if n < 5
          return pmsi_tunnel_finding(type, v)
        when MP_REACH
          # AFI, SAFI, next hop length, next hop, reserved (RFC 4760 section 3).
          if n < 5 or 5 + v.getbyte(3) > n
            return Finding.new(type, 9, RESET, "next hop does not fit in #{n} octets (RFC 7606 section 7.11)")
          end
          nlri_at = 5 + v.getbyte(3)
          # Each answers nil for the other's family, so the prefix
          # families pay one comparison each and nothing else.
          return flow_spec_finding(type, v.byteslice(nlri_at, n - nlri_at),
                                   v.unpack1('n'), v.getbyte(2)) ||
                 evpn_finding(type, v.byteslice(nlri_at, n - nlri_at),
                              v.unpack1('n'), v.getbyte(2), true)
        when MP_UNREACH
          return Finding.new(type, 9, RESET, "length #{n}, AFI and SAFI need 3 (RFC 7606 section 7.11)") if n < 3
          return flow_spec_finding(type, v.byteslice(3, n - 3),
                                   v.unpack1('n'), v.getbyte(2)) ||
                 evpn_finding(type, v.byteslice(3, n - 3),
                              v.unpack1('n'), v.getbyte(2), false)
        when ATTR_SET
          return attr_set_finding(type, v)
        end
        nil
      end

      # The ATTR_SET attribute of RFC 6368 section 5: a 4-octet Origin
      # AS then "a variable-length field that conforms to the BGP UPDATE
      # message path attribute encoding rules". Section 5 names three
      # things that make it malformed, and all three are here: a length
      # below 4, an included MP_REACH or MP_UNREACH, and an included
      # attribute that is itself malformed.
      #
      # **The action is RFC 7606 section 7.16's, not RFC 6368's, and the
      # section 5 paragraph must not be implemented as written.** That
      # paragraph conditions the handling on "its Partial flag is set
      # and its Neighbor-Complete flag is clear", referring to
      # [OPT-TRANS-BGP], which RFC 6368's own reference list gives as
      # Work in Progress, September 2010. That draft became RFC 7606,
      # which has no Neighbor-Complete flag at all. RFC 7606 section
      # 7.16 replaces the paragraph outright: "An UPDATE message with a
      # malformed ATTR_SET attribute SHALL be handled using the approach
      # of 'treat as withdraw'", and "the normative reference to
      # [OPT-TRANS-BGP] in [RFC6368] is removed". So every finding here
      # is TAW and none of them reads a flag.
      #
      # The subcodes are RFC 4271's, since 7.16 names none: 5 for a
      # length error, as every length finding in this file uses, and 9,
      # Optional Attribute Error, for the content cases, which is where
      # section 5's superseded text pointed before 7.16 replaced it.
      #
      # The nested attributes are **walked, not decoded**, which is the
      # house style of prefix_sid_finding and tunnel_encap_finding and
      # is right for the same reason: Attr::Check runs on raw octets and
      # never on a decoder's output, so a set that is both malformed and
      # undecodable gets a Finding here and an Attr::Gap there, with
      # neither waiting on the other.
      def attr_set_finding(type, v)
        n = v.size
        if n < 4
          return Finding.new(type, 5, TAW,
            "length #{n}, needs at least 4 for the Origin AS (RFC 6368 section 5)")
        end
        s = v.byteslice(4, n - 4).to_s.dup
        until s.empty?
          bytes, cut = next_attribute(s)
          return Finding.new(type, 9, TAW,
            "included attribute is malformed: #{cut.reason} (RFC 6368 section 5)") if cut
          inner = bytes.getbyte(1)
          if inner == MP_REACH or inner == MP_UNREACH
            return Finding.new(type, 9, TAW,
              "includes attribute #{inner}, which RFC 6368 section 5 excludes")
          end
          # as4byte is true and not the session's: section 5 fixes the AS
          # size inside the set. Checking a nested AS_PATH with 2-octet
          # AS numbers would report a conformant set as malformed.
          found = attribute(bytes, true)
          unless found.empty?
            return Finding.new(type, 9, TAW,
              "included attribute #{inner} is malformed: #{found.first.reason} (RFC 6368 section 5)")
          end
        end
        nil
      end

      # The flow spec NLRI list of an MP_REACH or MP_UNREACH, RFC 8955
      # section 4 and RFC 8956. nil for every other SAFI, so this costs
      # the prefix families one comparison.
      #
      # **The subcode and the action are not RFC 8955's.** Its section 10
      # is four lines and defines neither: "Error handling according to
      # [RFC7606] and [RFC4760] applies to this specification." And
      # section 4.2 says an NLRI "not encoded as specified here,
      # including an NLRI that contains an unknown component type, is
      # considered malformed and error handling according to Section 10
      # is performed". So a malformed rule makes the attribute carrying
      # it malformed, and it gets what bgp4r already gives a malformed
      # MP_REACH: subcode 9 and a session reset, read from RFC 7606
      # section 7.11 in the two findings above. Inventing a subcode here
      # would be the error.
      #
      # **This walks the octets rather than asking Flow_spec to parse
      # them, on purpose.** Attr::Check runs on the raw octets and never
      # on the decoder's output, so the two channels stay independent:
      # an NLRI that is both malformed and undecodable gets a Finding
      # here and an Attr::Gap there, and neither waits on the other.
      # Parsing first would mean a rule bgp4r cannot read is never
      # reported as a protocol error, however plainly the RFC says it is
      # one. See #116 and Conventions in CLAUDE.md.
      #
      # What it does **not** reimplement is anything the family already
      # owns: `Flow_spec.nlri_size` gives the section 4.1 framing,
      # `Flow_spec::COMPONENTS` gives the type numbers known per family,
      # and `Flow_spec::Pair` gives the operator masks. So a component
      # class added to the library is known here the same day, and the
      # masks cannot drift apart. Only the component boundary walk is
      # local, because nothing else needs it.
      def flow_spec_finding(type, nlri, afi, safi)
        return nil unless safi == IANA::SAFI::FLOW_SPEC_RULES_1 or
                          safi == IANA::SAFI::FLOW_SPEC_RULES_2
        known = ::BGP::Flow_spec::COMPONENTS[afi]
        return nil if known.nil?
        vpn = safi == IANA::SAFI::FLOW_SPEC_RULES_2
        while nlri.size > 0
          size = ::BGP::Flow_spec.nlri_size(nlri)
          if size.nil?
            return Finding.new(type, 9, RESET,
              "#{nlri.size} octet left, too few for a flow spec NLRI length field (RFC 8955 section 4.1)")
          end
          if size > nlri.size
            return Finding.new(type, 9, RESET,
              "flow spec NLRI of #{size} octets runs past the attribute, #{nlri.size} left (RFC 8955 section 4.1)")
          end
          # The value is the 2-tuple minus its own length field, and
          # nlri_size counts both, so take the field width off the front.
          field = (nlri.getbyte(0) & 0xf0) == 0xf0 ? 2 : 1
          f = flow_spec_rule_finding(type, nlri.byteslice(field, size - field),
                                     known, vpn)
          return f if f
          nlri = nlri.byteslice(size, nlri.size - size)
        end
        nil
      end

      # One flow spec NLRI value: the section 8 Route Distinguisher for
      # SAFI 134, then the components, against the three rules of RFC
      # 8955 section 4.2.
      def flow_spec_rule_finding(type, value, known, vpn)
        i = 0
        if vpn
          # RFC 8955 section 8: "The NLRI length field shall include both
          # the 8 octets of the Route Distinguisher as well as the
          # subsequent Flow Specification NLRI value."
          if value.size < ::BGP::Flow_spec::RD_SIZE
            return Finding.new(type, 9, RESET,
              "#{value.size} octets, a SAFI 134 rule needs 8 for its Route Distinguisher (RFC 8955 section 8)")
          end
          i = ::BGP::Flow_spec::RD_SIZE
        end
        if i == value.size
          # Section 4.2 encodes the value as <[component]+>, one or more.
          return Finding.new(type, 9, RESET,
            "flow spec NLRI with no component (RFC 8955 section 4.2)")
        end
        seen = nil
        while i < value.size
          comp = value.getbyte(i)
          unless known.key?(comp)
            return Finding.new(type, 9, RESET,
              "unknown flow spec component type #{comp} (RFC 8955 section 4.2)")
          end
          # "Components MUST follow strict type ordering by increasing
          # numerical order. A given component type MAY (exactly once) be
          # present in the Flow Specification." Equal is not increasing,
          # so a repeat breaks both halves; it gets its own words because
          # they say more to a reader than "not increasing" does.
          if seen and comp == seen
            return Finding.new(type, 9, RESET,
              "flow spec component type #{comp} appears more than once (RFC 8955 section 4.2)")
          end
          if seen and comp < seen
            return Finding.new(type, 9, RESET,
              "flow spec component type #{comp} after type #{seen}, which is not increasing (RFC 8955 section 4.2)")
          end
          seen = comp
          size = flow_spec_component_size(value, i, known[comp])
          if size.nil? or i + size > value.size
            return Finding.new(type, 9, RESET,
              "flow spec component type #{comp} runs past the NLRI (RFC 8955 section 4.2)")
          end
          i += size
        end
        nil
      end

      # The EVPN NLRI list of an MP_REACH or MP_UNREACH, AFI 25 SAFI 70.
      # nil for every other family, so this costs the prefix families one
      # comparison.
      #
      # **Where the action and the subcode come from, because the route
      # type RFCs mostly do not say.** RFC 7432 and RFC 9572 contain no
      # error handling text at all: neither says "malformed", neither
      # mentions RFC 7606. RFC 9251 section 9.7 is the only EVPN RFC that
      # does, and it agrees with what bgp4r already gives a malformed
      # MP_REACH: "If a received BGP update is malformed such that BGP
      # route keys cannot be extracted, then the BGP update MUST be
      # considered invalid. The receiving PE MUST apply the 'session
      # reset' procedure per [RFC7606]." So the framing and length
      # findings are subcode 9 with a session reset, the same as the two
      # MP_REACH findings above and for the same reason, RFC 7606 section
      # 7.11. Where a route type's own RFC names treat-as-withdraw
      # instead, that wins, which is RFC 7606 section 3 working as
      # intended; those findings say which section said so.
      #
      # **An unknown route type is not an error here, where an unknown
      # flow spec component type is.** That asymmetry is the RFCs': RFC
      # 8955 section 4.2 says in so many words that an NLRI containing an
      # unknown component type "is considered malformed", and no EVPN RFC
      # says anything of the kind about a route type outside its own. So
      # an unregistered route type keeps its octets as an `Evpn::Unknown`
      # and is reported nowhere, which is RFC 4271 section 5's posture
      # toward what a receiver does not recognize. Do not add it: types
      # 12 to 255 are unassigned, so it would make bgp4r call a correct
      # router malformed the day IANA assigns one.
      #
      # **`reach` is why this takes an argument `flow_spec_finding` does
      # not, and it changes the answer.** Two of the rules below are
      # about the data in a route being advertised, and the fields they
      # read are explicitly not part of the route key: RFC 9136 section
      # 3.1 says only "The RD, Ethernet Tag ID, IP prefix length, and IP
      # prefix are part of the route key", and RFC 9251 section 9.1 says
      # "all the fields are considered to be part of the prefix in the
      # NLRI, except for the 1-octet Flags field". A withdrawal names a
      # route key, so whatever it carries in the other fields is
      # don't-care. Running the version flag rule on an MP_UNREACH would
      # be worse than useless: RFC 9251 section 4.1 asks a PE to withdraw
      # the route rather than re-advertise it with the flags reset, so
      # bgp4r would report the very withdrawal the RFC asked for.
      def evpn_finding(type, nlri, afi, safi, reach)
        return nil unless afi == IANA::AFI::L2VPN and safi == IANA::SAFI::EVPN
        framing = ::BGP::Evpn::FRAMING
        while nlri.size > 0
          size = ::BGP::Evpn.nlri_size(nlri)
          if size.nil?
            return Finding.new(type, 9, RESET,
              "#{nlri.size} octet left, too few for an EVPN Route Type and Length (RFC 7432 section 7)")
          end
          if size > nlri.size
            return Finding.new(type, 9, RESET,
              "EVPN NLRI of #{size} octets runs past the attribute, #{nlri.size} left (RFC 7432 section 7)")
          end
          f = evpn_route_finding(type, nlri.getbyte(0),
                                 nlri.byteslice(framing, size - framing), reach)
          return f if f
          nlri = nlri.byteslice(size, nlri.size - size)
        end
        nil
      end

      # One EVPN route's body, against the rules its own RFC states. The
      # route type numbers come from the classes rather than being written
      # again here, so they cannot drift from `Evpn::ROUTES`.
      #
      # Only two of the eleven have rules a receiver can check from these
      # octets alone. The others are either silent (RFC 7432's five and
      # RFC 9572's three say nothing about error handling) or need another
      # attribute, which is what `docs/evpn.md` section 9 records.
      def evpn_route_finding(type, route_type, body, reach)
        case route_type
        when ::BGP::Evpn::Ip_prefix_route.type
          ip_prefix_route_finding(type, body, reach)
        when ::BGP::Evpn::Selective_multicast.type
          selective_multicast_finding(type, body, reach)
        end
      end

      # RFC 9136 sections 3.1 and 3.2, the IP Prefix route. The one route
      # type with a stated length, and the only one whose RFC names
      # treat-as-withdraw for a data combination.
      def ip_prefix_route_finding(type, body, reach)
        klass  = ::BGP::Evpn::Ip_prefix_route
        v4, v6 = klass::SIZE_V4, klass::SIZE_V6
        # Section 3.1: "The Length field of the BGP EVPN NLRI for an EVPN
        # IP Prefix route MUST be either 34 (if IPv4 addresses are
        # carried) or 58 (if IPv6 addresses are carried)."
        unless body.size == v4 or body.size == v6
          return Finding.new(type, 9, RESET,
            "EVPN IP Prefix route of #{body.size} octets, must be #{v4} or #{v6} (RFC 9136 section 3.1)")
        end
        # RD (8), ESI (10), Ethernet Tag ID (4), then the IP Prefix Length
        # octet, the prefix, the GW IP Address and a 3 octet label.
        esi_at, esi_len, plen_at = 8, 10, 22
        # Section 3.1: the prefix length "specifies the number of bits in
        # the prefix. The value MUST NOT be greater than 128." The section
        # names no receiver action, so the generic one applies.
        plen = body.getbyte(plen_at)
        if plen > 128
          return Finding.new(type, 9, RESET,
            "IP prefix length #{plen}, must not be greater than 128 (RFC 9136 section 3.1)")
        end
        return nil unless reach
        # Section 3.2: "The ESI and GW IP fields may both be zero at the
        # same time. However, they MUST NOT both be non-zero at the same
        # time. A route containing a non-zero GW IP and a non-zero ESI (at
        # the same time) SHOULD be treat as withdraw [RFC7606]." Table 1
        # of that section lists every combination it does allow.
        addr = body.size == v4 ? 4 : 16
        if nonzero?(body, esi_at, esi_len) and
           nonzero?(body, plen_at + 1 + addr, addr)
          return Finding.new(type, 9, TAW,
            'a non-zero ESI and a non-zero GW IP at the same time (RFC 9136 section 3.2)')
        end
        nil
      end

      # RFC 9251 sections 4.1, 9.1 and 9.7, the Selective Multicast
      # Ethernet Tag route.
      def selective_multicast_finding(type, body, reach)
        klass = ::BGP::Evpn::Selective_multicast
        # RD (8), Ethernet Tag ID (4), three length-prefixed addresses,
        # then the Flags octet. With all three addresses absent that is
        # the smallest body there can be, so anything shorter cannot hold
        # the RD and Ethernet Tag ID the route key is made of.
        if body.size < klass::FIXED_SIZE
          return Finding.new(type, 9, RESET,
            "EVPN SMET route of #{body.size} octets, too few for its route key, " \
            "which needs #{klass::FIXED_SIZE} (RFC 9251 section 9.7)")
        end
        # Each of the three addresses is a length in bits then its octets,
        # and the Flags octet follows the third. A length field claiming
        # more octets than are left is malformed under any reading of the
        # bit count, which is what makes this safe to report: RFC 6514
        # section 4.3 gives 32 and 128 and calls other values "outside the
        # scope", so bgp4r echoes any of them rather than ruling on them.
        i = 8 + 4
        3.times do |n|
          i += 1 + (body.getbyte(i) + 7) / 8
          if i > body.size - 1
            return Finding.new(type, 9, RESET,
              "EVPN SMET route address #{n + 1} runs past the route, " \
              "leaving no Flags octet (RFC 9251 section 9.7)")
          end
        end
        return nil unless reach
        # Section 4.1: "the received EVPN route MUST have at least one
        # version flag set. If all version flags are reset, it is an error
        # because the PE should have received an EVPN route withdraw for
        # the last version flag. An error MUST be considered as a BGP
        # error, and the PE MUST apply the 'treat-as-withdraw' procedure
        # per [RFC7606]." Section 9.7 restates it as Flags "not in
        # accordance with the IGMP/MLD version-X expectation".
        #
        # Route types 7 and 8 carry the same Flags octet and this does not
        # check them, because the RFC states the rule in SMET's own
        # processing section and nowhere else. See docs/evpn.md section 9.
        flags = ::BGP::Evpn::Flags
        versions = flags::V1 | flags::V2 | flags::V3
        if (body.getbyte(-1) & versions) == 0
          return Finding.new(type, 9, TAW,
            'an EVPN SMET route with no IGMP version flag set (RFC 9251 section 4.1)')
        end
        nil
      end

      # True when any of n octets of s from i is not zero.
      def nonzero?(s, i, n)
        s.byteslice(i, n).each_byte.any? { |b| b > 0 }
      end

      # The whole size of the component at i, type octet included, or nil
      # when the octets run out before its own fields do.
      #
      # Three shapes, and the class says which: a prefix (RFC 8955
      # section 4.2.2.1, "encoded as in BGP UPDATE messages"), an IPv6
      # prefix with the extra offset octet of RFC 8956 section 3.1, and
      # everything else as {op, value} pairs ended by the section 4.2.1.1
      # end-of-list bit.
      def flow_spec_component_size(value, i, klass)
        fs = ::BGP::Flow_spec
        if klass <= fs::Ipv6_prefix_component
          return nil if i + 3 > value.size
          len, off = value.getbyte(i + 1), value.getbyte(i + 2)
          return nil if len < off
          3 + ((len - off) + 7) / 8
        elsif klass <= fs::Prefix_component
          return nil if i + 2 > value.size
          2 + (value.getbyte(i + 1) + 7) / 8
        else
          j = i + 1
          loop do
            return nil if j >= value.size
            op = value.getbyte(j)
            j += 1 + (1 << ((op & fs::Pair::LEN_MASK) >> fs::Pair::LEN_SHIFT))
            break if (op & fs::Pair::EOL) != 0
          end
          j - i
        end
      end

      def fixed(type, n, want, action, rfc, subcode)
        return nil if n == want
        Finding.new(type, subcode, action, "length #{n}, must be #{want} (RFC #{rfc})")
      end

      def multiple(type, n, unit, action, rfc)
        return nil if n > 0 and n % unit == 0
        Finding.new(type, 5, action, "length #{n}, must be a non-zero multiple of #{unit} (RFC #{rfc})")
      end

      # AS_PATH segments: type, count, then count AS numbers of size octets.
      def as_path_finding(type, v, size, action, rfc, no_confed)
        i = 0
        while i < v.size
          return Finding.new(type, 11, action, "one octet left after a segment (RFC #{rfc})") if v.size - i < 2
          seg, count = v.getbyte(i), v.getbyte(i + 1)
          unless (SET..CONFED_SET).include?(seg)
            return Finding.new(type, 11, action, "unknown segment type #{seg} (RFC #{rfc})")
          end
          if no_confed and seg >= CONFED_SEQUENCE
            return Finding.new(type, 11, action, "confederation segment in AS4_PATH (RFC #{rfc})")
          end
          return Finding.new(type, 11, action, "segment of length zero (RFC #{rfc})") if count == 0
          if i + 2 + count * size > v.size
            return Finding.new(type, 11, action, "segment overruns the attribute (RFC #{rfc})")
          end
          i += 2 + count * size
        end
        nil
      end

      # RFC 7606 section 3 (g): keep the first, discard the others,
      # except MP_REACH_NLRI and MP_UNREACH_NLRI: session reset.
      # RFC 8669 section 6: malformed when a TLV does not fit its own
      # length or runs past the end of the attribute. The action is
      # attribute discard, the attribute is ignored and not passed on.
      def prefix_sid_finding(type, v)
        i = 0
        while i < v.size
          if v.size - i < 3
            return Finding.new(type, 5, DISCARD,
              "#{v.size - i} octets left, a TLV header needs 3 (RFC 8669 section 6)")
          end
          tlv, len = v.getbyte(i), v.byteslice(i + 1, 2).unpack1('n')
          if i + 3 + len > v.size
            return Finding.new(type, 5, DISCARD,
              "TLV type #{tlv} runs past the attribute (RFC 8669 section 6)")
          end
          if tlv == 1 and len != 7
            return Finding.new(type, 5, DISCARD,
              "Label-Index TLV length #{len}, must be 7 (RFC 8669 section 3.1)")
          end
          if tlv == 3 and (len < 8 or (len - 2) % 6 != 0)
            return Finding.new(type, 5, DISCARD,
              "Originator SRGB TLV length #{len}, must be 2 plus a non-zero multiple of 6 (RFC 8669 section 3.2)")
          end
          i += 3 + len
        end
        nil
      end

      # RFC 9012 section 13. The attribute is malformed, and the action
      # is treat-as-withdraw, when it holds no valid TLV, or when a
      # TLV's last octet is not the last octet of its last sub-TLV.
      #
      # Nothing else here is an attribute error. Section 13 says an
      # unrecognized tunnel type is not malformed, and that a sub-TLV
      # that is unrecognized, malformed, duplicated or meaningless for
      # its tunnel type affects its own TLV at most. So the sub-TLV
      # lengths the RFC gives are not checked, and bgp4r keeps and
      # passes on every sub-TLV it reads.
      # RFC 8317 section 6.2's one receive side rule on the PMSI Tunnel
      # attribute: "Using the composite tunnel bit for Tunnel Types 0x00
      # 'no tunnel information present' and 0x06 'Ingress Replication'
      # is invalid. A PE that receives a PMSI Tunnel attribute with such
      # information considers it malformed, and it SHOULD treat this
      # Update as though all the routes contained in this Update had
      # been withdrawn per Section 6 of [RFC6514]." So the action is
      # treat-as-withdraw in the section's own words, and the subcode is
      # the one the length finding above already uses, since the section
      # names none and inventing one is the trap EVPN part 9 recorded.
      #
      # **The bit on its own is not an error**, and must not become one:
      # every other composite tunnel type is valid, and 0x80 to 0xfa are
      # Reserved for Composite Tunnel by section 8.1. The type numbers
      # come from `Pmsi_tunnel` so they cannot drift from the encoder.
      def pmsi_tunnel_finding(type, v)
        octet = v.getbyte(1)
        return nil if (octet & ::BGP::Pmsi_tunnel::COMPOSITE).zero?
        base = octet & ~::BGP::Pmsi_tunnel::COMPOSITE
        return nil unless [::BGP::Pmsi_tunnel::NO_TUNNEL,
                           ::BGP::Pmsi_tunnel::INGRESS_REPLICATION].include?(base)
        Finding.new(type, 5, TAW,
                    "composite tunnel bit with tunnel type #{base} " \
                    "(RFC 8317 section 6.2)")
      end

      def tunnel_encap_finding(type, v)
        return Finding.new(type, 5, TAW, "no TLVs (RFC 9012 section 13)") if v.empty?
        i = 0
        while i < v.size
          if v.size - i < 4
            return Finding.new(type, 5, TAW,
              "#{v.size - i} octets left, a TLV header needs 4 (RFC 9012 section 13)")
          end
          tunnel = v.byteslice(i, 2).unpack1('n')
          len    = v.byteslice(i + 2, 2).unpack1('n')
          if i + 4 + len > v.size
            return Finding.new(type, 5, TAW,
              "TLV type #{tunnel} runs past the attribute (RFC 9012 section 13)")
          end
          if (f = sub_tlv_fit_finding(type, tunnel, v.byteslice(i + 4, len)))
            return f
          end
          i += 4 + len
        end
        nil
      end

      # RFC 9012 section 13: the last octet of a TLV must be the last
      # octet of its last sub-TLV. A sub-TLV of type 128 or above has a
      # two octet length, the rest one octet (section 2).
      def sub_tlv_fit_finding(type, tunnel, body)
        i = 0
        while i < body.size
          hdr = body.getbyte(i) >= 128 ? 3 : 2
          if body.size - i < hdr
            return Finding.new(type, 5, TAW,
              "#{body.size - i} octets left in TLV type #{tunnel}, a sub-TLV header needs #{hdr} (RFC 9012 section 13)")
          end
          len = hdr == 3 ? body.byteslice(i + 1, 2).unpack1('n') : body.getbyte(i + 1)
          if i + hdr + len > body.size
            return Finding.new(type, 5, TAW,
              "sub-TLV type #{body.getbyte(i)} runs past TLV type #{tunnel} (RFC 9012 section 13)")
          end
          i += hdr + len
        end
        nil
      end

      def duplicate_finding(type)
        if type == MP_REACH or type == MP_UNREACH
          Finding.new(type, 1, RESET, "appears more than once (RFC 7606 section 3 (g))")
        else
          Finding.new(type, 1, DISCARD, "appears more than once, the first one counts (RFC 7606 section 3 (g))")
        end
      end

    end
  end

  # Raised by the :strict receive policy. finding is the strongest of
  # findings (RFC 7606 section 3 (h)); findings has them all.
  class Malformed_attribute < StandardError
    attr_reader :finding, :findings, :path_attribute
    def initialize(findings, path_attribute = nil)
      @findings = findings
      @finding = Attr.strongest(findings) || findings.first
      @path_attribute = path_attribute
      super(@finding.to_s)
    end
    def type;    finding.type;    end
    def subcode; finding.subcode; end
    def action;  finding.action;  end
  end

end
