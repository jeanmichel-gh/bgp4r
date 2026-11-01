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
    # action   what RFC 7606 says a receiver does, one of ACTIONS:
    #          :session_reset, :afi_safi_disable, :treat_as_withdraw,
    #          :attribute_discard or :nlri_discard. nil when the
    #          finding is not an error a peer would act on. See ACTIONS
    #          for which of those are RFC 7606 section 2's own and
    #          which is RFC 9552's.
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
    # Weakest first, so `strongest` is `max_by` over the index.
    #
    # **Section 2 lists four and names the direction**, read first hand:
    # the approaches are given "from the one with the 'strongest' action
    # to the one with the 'weakest' action", which is session reset,
    # AFI/SAFI disable, treat-as-withdraw, attribute discard. So
    # :afi_safi_disable sits between :treat_as_withdraw and
    # :session_reset and the other three keep their places. It is
    # section 7 of RFC 4760's option, which section 2 quotes as
    # "ignore all the subsequent routes with that AFI/SAFI received over
    # that session" and names "'disabling a particular AFI/SAFI' or
    # 'AFI/SAFI disable'".
    #
    # **:nlri_discard is not one of section 2's four**, and that is the
    # thing to know about it. Section 2 is about attributes; RFC 9552
    # section 8.2.2 asks for "'NLRI discard' (i.e., processing similar
    # to what is described in Section 5.4 of [RFC7606])", and section
    # 5.4 is "Typed NLRI", which has a speaker "handle routes with
    # unrecognized NLRI types within that address family by discarding
    # them". So it discards one NLRI and goes on, where every other
    # action here is about the attribute as a whole.
    #
    # **Its place in this list is a decision and not the RFC's**, since
    # the RFC does not rank it. What 8.2.2 says is that it is the case
    # where the router "allows for the router to skip the malformed
    # NLRI(s) and continue the processing of the rest of the BGP UPDATE
    # message", which is the property section 2 gives attribute discard
    # ("the UPDATE message continues to be processed"). So both are
    # continue-actions and neither escalates, and this one is first,
    # weakest, because it loses one NLRI where attribute discard loses
    # every TLV of an attribute.
    #
    # **A Finding whose action is not in this list crashes `strongest`**,
    # because `index` answers nil and `max_by` then compares nil, so an
    # action is added here and not only used.
    ACTIONS = [:nlri_discard, :attribute_discard, :treat_as_withdraw,
               :afi_safi_disable, :session_reset]

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
      # RFC 9552 section 8.2.2's two, which part 6b is the first caller
      # of. `NLRI_DISCARD` is per-NLRI where every other action here is
      # per-attribute, so a Finding carrying it says the attribute holds
      # a malformed NLRI and its reason names which one: `Finding`'s
      # granularity is the attribute and this does not change it.
      NLRI_DISCARD = :nlri_discard
      AFI_DISABLE  = :afi_safi_disable

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
        # RFC 9552 section 5.3: "The BGP-LS Attribute is an optional,
        # non-transitive BGP attribute". This one entry is the whole of
        # section 8.2.2's second attribute bullet, "the syntactic
        # correctness of the Attributes (including the BGP-LS Attribute)
        # have been verified as per [RFC7606]", that is this family's to
        # add: without it flags_finding takes any optional attribute it
        # does not know and says nothing.
        BGP_LS           => OPTIONAL,
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
          # **The next hop's own length, where a family states what it
          # expects.** Section 7.11 carries the rule and leaves the
          # expectation to the family: "If the Length of Next Hop
          # Network Address field of the MP_REACH attribute is
          # inconsistent with that which was expected, the attribute is
          # considered malformed", and "'That which was expected', while
          # somewhat vague, is intended to encompass the next hop
          # specified for the Address Family Identifier and Subsequent
          # Address Family Identifier fields and is potentially modified
          # by any extensions in use. For example, if [RFC5549] is in
          # use, then the next hop would have to have a length of 4 or
          # 16." So this is not a new rule and needs no new subcode: it
          # is 7.11's own clause with one family's expectation filled
          # in. See mcast_vpn_next_hop_finding for which family and why
          # only one.
          f = mcast_vpn_next_hop_finding(type, v.unpack1('n'), v.getbyte(2),
                                         v.getbyte(3)) ||
              link_state_next_hop_finding(type, v.getbyte(2), v.getbyte(3))
          return f if f
          # Each answers nil for the other's family, so the prefix
          # families pay one comparison each and nothing else.
          return flow_spec_finding(type, v.byteslice(nlri_at, n - nlri_at),
                                   v.unpack1('n'), v.getbyte(2)) ||
                 evpn_finding(type, v.byteslice(nlri_at, n - nlri_at),
                              v.unpack1('n'), v.getbyte(2), true) ||
                 mcast_vpn_finding(type, v.byteslice(nlri_at, n - nlri_at),
                                   v.unpack1('n'), v.getbyte(2), true) ||
                 link_state_finding(type, v.byteslice(nlri_at, n - nlri_at),
                                    v.getbyte(2))
        when MP_UNREACH
          return Finding.new(type, 9, RESET, "length #{n}, AFI and SAFI need 3 (RFC 7606 section 7.11)") if n < 3
          return flow_spec_finding(type, v.byteslice(3, n - 3),
                                   v.unpack1('n'), v.getbyte(2)) ||
                 evpn_finding(type, v.byteslice(3, n - 3),
                              v.unpack1('n'), v.getbyte(2), false) ||
                 mcast_vpn_finding(type, v.byteslice(3, n - 3),
                                   v.unpack1('n'), v.getbyte(2), false) ||
                 link_state_finding(type, v.byteslice(3, n - 3), v.getbyte(2))
        when ATTR_SET
          return attr_set_finding(type, v)
        when BGP_LS
          return link_state_attribute_finding(type, v)
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

      # **These four sit after `nonzero?` and not beside the EVPN checks
      # they resemble, which is deliberate.**
      # `evpn_doc_test.rb`'s row count slices validation.rb from `def
      # evpn_finding` to `def nonzero?` and counts `Finding.new(` in
      # between, so anything put in that window is counted as an EVPN
      # check and fails the guard. Writing them there is what happened
      # first, and the guard caught it. `nonzero?` is EVPN's own helper
      # and nothing else calls it, so that window is exactly the EVPN
      # block and is worth leaving exact.
      #
      # The MP_REACH next hop's length, for the one family whose RFC says
      # what it expects and what to do when it is not that. nil for every
      # other, so the prefix families pay one comparison.
      #
      # **RFC 6515, "IPv4 and IPv6 Infrastructure Addresses in BGP
      # Updates for Multicast VPN", February 2012, header `Updates:
      # 6514`.** Section 2 lists the four places a provider address
      # appears in an MCAST-VPN route; item 1 is this field: "it is
      # always clear whether the address is an IPv4 address (length is 4)
      # or an IPv6 address (length is 16)", and if it is neither "the
      # MP_REACH_NLRI attribute MUST be considered to be 'incorrect', and
      # MUST be handled as specified in Section 7 of [BGP-MP]".
      #
      # **The action and the subcode are RFC 7606's and not derived.**
      # RFC 6515 points at RFC 4760 section 7, and RFC 7606's header says
      # `Updates: 4760`: its section 7.11 is the same rule stated
      # generally, a next hop length "inconsistent with that which was
      # expected" is malformed and "the 'session reset' or 'AFI/SAFI
      # disable' approach MUST be used", because "the next hop precedes
      # the NLRI field in the attribute" so the NLRI cannot be located.
      # Its own worked example is the same sentence from the other end:
      # "if [RFC5549] is in use, then the next hop would have to have a
      # length of 4 or 16". So this is subcode 9 with a session reset,
      # which is exactly what the "next hop does not fit" finding above
      # already answers and for the same citation.
      #
      # **Why only this family, when three share the next hop arm in
      # `mp_reach.rb`.** The difference is which RFC names the error, not
      # which has an expectation. RFC 7432 section 14 says an EVPN next
      # hop "MUST be set to the IPv4 or IPv6 address of the advertising
      # PE", which binds a sender and names no receiver action; RFC 4684
      # section 4 says the field "shall be interpreted as an IPv4 address
      # whenever the length of NextHop address is 4 octets", which tells
      # a reader how to read it and says nothing about other lengths. RFC
      # 6515 is the only one of the three that states the error and the
      # handling. Extending this to the other two would be deriving from
      # 7.11 alone, which is legitimate and is a decision rather than an
      # implementation; `docs/mcast-vpn.md` section 8 records it as the
      # obvious next piece of work with the citations already in hand.
      #
      # **MP_UNREACH is not checked and that is the RFC's choice.** All
      # four of section 2's items name the MP_REACH_NLRI attribute and
      # none mentions MP_UNREACH_NLRI, measured by reading them. An
      # MP_UNREACH carries no next hop at all, so item 1 could not apply
      # there anyway.
      def mcast_vpn_next_hop_finding(type, afi, safi, len)
        return nil unless safi == IANA::SAFI::MCAST_VPN
        return nil if len == 4 or len == 16
        Finding.new(type, 9, RESET,
          "MCAST-VPN next hop of #{len} octets, must be 4 or 16 " \
          '(RFC 6515 section 2, RFC 7606 section 7.11)')
      end

      # The MCAST-VPN NLRI list of an MP_REACH or MP_UNREACH, SAFI 5.
      # nil for every other family, so this costs the prefix families one
      # comparison. AFI 1 and 2 both reach here, which RFC 6514 section 4
      # allows and nothing below reads differently.
      #
      # **Where the action and the subcode come from, because RFC 6514
      # says nothing at all.** Neither RFC 6514 nor
      # draft-ietf-bess-rfc6514bis-00 contains any NLRI error handling
      # text: "malformed" appears only for the PMSI Tunnel attribute and
      # the PE Distinguisher Labels attribute, and neither references RFC
      # 7606 for an NLRI. That is the RFC 7432, RFC 9572 and RFC 4684
      # situation and not RFC 8955's. So the framing findings get what
      # bgp4r already gives a malformed MP_REACH, subcode 9 with a
      # session reset, citing RFC 7606 section 7.11 as the two MP_REACH
      # findings and the EVPN ones do.
      #
      # **The route body findings are RFC 6515's, with its own action.**
      # Section 2 items 2, 3 and 4 cover the Originating Router's IP
      # Address in route types 1, 3 and 4, the three that carry it, and
      # each says the same thing: the field's width is what the NLRI
      # length leaves over, and "If the inferred length of the
      # 'Originating Router's IP Address' field is neither 4 nor 16, the
      # MP_REACH_NLRI attribute MUST be considered to be 'incorrect', and
      # MUST be handled as specified in Section 7 of [BGP-MP]". Item 2
      # also gives the only octet count any document in this family
      # states, for route type 1: the NLRI length field "will be either
      # 12 or 24, respectively".
      #
      # **An unknown route type is not an error here.** No MCAST-VPN RFC
      # says it is, where RFC 8955 section 4.2 says exactly that of a flow
      # spec component type, so this is the EVPN posture and for the same
      # reason: types 8 to 66 and 72 onward are unassigned, so reporting
      # one would make bgp4r call a correct router malformed the day IANA
      # assigns one. RFC 7441's three mLDP types are out of scope by
      # decision and land here too, so reporting would be worse than
      # noisy: it would call a conformant mLDP speaker malformed.
      #
      # **`reach` is why this takes the argument, and what it gates.**
      # All four of section 2's items name MP_REACH_NLRI and none
      # mentions MP_UNREACH_NLRI, measured by reading them rather than
      # inferred from the route key the way EVPN's two `reach` rules
      # were. The framing findings run on both, because octets that
      # cannot be split are not a question about which attribute holds
      # them.
      def mcast_vpn_finding(type, nlri, afi, safi, reach)
        return nil unless safi == IANA::SAFI::MCAST_VPN
        framing = ::BGP::Mcast_vpn::FRAMING
        while nlri.size > 0
          size = ::BGP::Mcast_vpn.nlri_size(nlri)
          if size.nil?
            return Finding.new(type, 9, RESET,
              "#{nlri.size} octet left, too few for an MCAST-VPN Route Type " \
              'and Length (RFC 6514 section 4)')
          end
          if size > nlri.size
            return Finding.new(type, 9, RESET,
              "MCAST-VPN NLRI of #{size} octets runs past the attribute, " \
              "#{nlri.size} left (RFC 6514 section 4)")
          end
          if reach
            f = mcast_vpn_route_finding(type, nlri.getbyte(0),
                                        nlri.byteslice(framing, size - framing))
            return f if f
          end
          nlri = nlri.byteslice(size, nlri.size - size)
        end
        nil
      end

      # One MCAST-VPN route's body, against RFC 6515 section 2. The route
      # type numbers come from the classes rather than being written again
      # here, so they cannot drift from `Mcast_vpn::ROUTES`.
      #
      # Three of the seven carry an Originating Router's IP Address and
      # so have a rule a receiver can check; the other four have no
      # receive side rule in any of the three documents. Section 4.5 has
      # two that are not these, and `docs/mcast-vpn.md` section 8 says
      # why each is out: one is an "outside the scope" sentence, and the
      # other needs a multicast range RFC 6514 does not number.
      def mcast_vpn_route_finding(type, route_type, body)
        case route_type
        when ::BGP::Mcast_vpn::Intra_as_i_pmsi.type
          # Item 2: an RD, then the address. Nothing in between, which is
          # why this is the item that can state a total.
          originator_finding(type, route_type, body.size - ::BGP::Mcast_vpn::RD_SIZE)
        when ::BGP::Mcast_vpn::S_pmsi.type
          # Item 3: an RD, the Multicast Source and Group, then the
          # address. Each of the two is a length in bits and that many
          # bits of value, so the walk is theirs and the remainder is the
          # address. A length claiming more than the body holds leaves
          # nothing behind it, which answers a width of 0 and is reported
          # for that reason rather than needing a rule of its own.
          i = ::BGP::Mcast_vpn::RD_SIZE
          2.times do
            break if i >= body.size
            i += 1 + ::BGP::Mcast_vpn::Addr.octets_for(body.getbyte(i))
          end
          originator_finding(type, route_type, body.size - i)
        when ::BGP::Mcast_vpn::Leaf_a_d.type
          # Item 4: "the 'NLRI length' field is following by a
          # variable-length 'route key', which is followed by the
          # 'Originating Router's IP' address. The Route Key has its own
          # length field. From the NLRI length and the route key length,
          # one can compute the length" of the address. So the nested
          # NLRI's own framing gives the split, which is the same reading
          # `Mcast_vpn::Leaf_a_d` takes.
          key = ::BGP::Mcast_vpn.nlri_size(body)
          return nil if key.nil? or key > body.size
          originator_finding(type, route_type, body.size - key)
        end
      end

      # RFC 6515 section 2, the sentence items 2, 3 and 4 share.
      def originator_finding(type, route_type, width)
        return nil if width == 4 or width == 16
        Finding.new(type, 9, RESET,
          "MCAST-VPN route type #{route_type} leaves #{width} octets for its " \
          "Originating Router's IP Address, must be 4 or 16 " \
          '(RFC 6515 section 2)')
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

      # **The BGP-LS checks sit last and not beside the families they
      # resemble, which is the second time this file has had to say
      # so.** Two sibling doc tests slice this file by method name and
      # count `Finding.new` in between: `evpn_doc_test.rb` from `def
      # evpn_finding` to `def nonzero?`, and `mcast_vpn_doc_test.rb`
      # from `def mcast_vpn_next_hop_finding` to `def
      # flow_spec_component_size`. So a BGP-LS check written in either
      # window is counted as that family's and fails its guard. The end
      # of `Check` is in neither, and `bgp_ls_doc_test.rb` slices from
      # `def link_state_next_hop_finding` to `class
      # Malformed_attribute`.
      #
      # **`BGP_LS` is three different numbers and this module sees the
      # wrong one.** `ATTR::BGP_LS` is 29 and `include ATTR` is in
      # effect here, so a bare `BGP_LS` means the attribute code;
      # `IANA::AFI::BGP_LS` is 16388 and `IANA::SAFI::BGP_LS` is 71.
      # `iana.rb` warns about the first two sharing a bare name, and
      # inside `Check` there is a third. Every SAFI below is written out
      # in full for that reason.
      #
      # The MP_REACH next hop's length, SAFI 71 and 72. nil for every
      # other family, so the rest pay one comparison.
      #
      # **The citation is a chain of three and the middle link is this
      # family's own fault management section**, which is what puts
      # BGP-LS on the near side of the line `mcast_vpn_next_hop_finding`
      # draws. RFC 9552 section 8.2.2 asks a BGP-LS Speaker to verify
      # "The syntactic correctness of the NLRI fields has been verified
      # as per [RFC7606]"; RFC 7606 section 7.11 says a next hop length
      # "inconsistent with that which was expected" makes the attribute
      # malformed and leaves the expectation to the family; and RFC 9552
      # section 5.5 states the expectation: "If the next-hop length is
      # 4, then the next hop is an IPv4 address; if the next-hop length
      # is 16, then it is a global IPv6 address; and if the next-hop
      # length is 32, then there is one global IPv6 address followed by
      # an IPv6 link-local address", with "For VPN Subsequent Address
      # Family Identifier (SAFI), as per custom, an 8-byte Route
      # Distinguisher set to all zero is prepended to the next hop."
      #
      # So this sits between MCAST-VPN, where RFC 6515 states the error
      # itself, and EVPN and RT-constrain, where neither the family RFC
      # nor anything else points at RFC 7606 for it. `docs/bgp-ls.md`
      # section 8 records that ordering and the one reading it rests on,
      # which is that "the NLRI fields" of bullet 5 means the fields of
      # the MP_REACH_NLRI attribute and not only the Link-State NLRI's
      # own. Bullets 1 and 2 name "the BGP MP_REACH_NLRI attribute" and
      # its length, so the list does range over the attribute; and under
      # the narrow reading bullet 5 would say nothing bullets 3 and 4 do
      # not.
      #
      # **The VPN lengths are arithmetic from that one sentence**, 8 + 4,
      # 8 + 16 and 8 + 16 + 16, since section 5.5 gives no list for the
      # VPN case. One Route Distinguisher for the whole field, not one
      # per address, which is why these are 12, 24 and 40 where RFC 8950
      # gives SAFI 128 and 129 24 or 48. `mp_reach.rb`'s own next hop arm
      # carries the same reading and the same note.
      #
      # **The Route Distinguisher's value is not checked.** Section 5.5
      # says it is "set to all zero", which binds a sender, and a
      # non-zero one is a value and not a length: section 8.2.2's
      # forbidden list keeps bgp4r out of values.
      #
      # **MP_UNREACH is not checked** because it carries no next hop.
      def link_state_next_hop_finding(type, safi, len)
        want = case safi
               when IANA::SAFI::BGP_LS     then [4, 16, 32]
               when IANA::SAFI::BGP_LS_VPN then [12, 24, 40]
               end
        return nil if want.nil? or want.include?(len)
        Finding.new(type, 9, RESET,
          "BGP-LS next hop of #{len} octets, must be " \
          "#{want[0, 2].join(', ')} or #{want[2]} " \
          '(RFC 9552 sections 5.5 and 8.2.2, RFC 7606 section 7.11)')
      end

      # The Link-State NLRI list of an MP_REACH or MP_UNREACH, SAFI 71
      # and 72. nil for every other family.
      #
      # **Every check here is syntactic, by instruction.** RFC 9552
      # section 8.2.2 opens with two MUST NOTs: neither the NLRI nor the
      # BGP-LS Attribute "MUST NOT be considered malformed or invalid
      # based on the inclusion/exclusion of TLVs or contents of the TLV
      # fields (i.e., semantic errors)". It then names four shapes of
      # check a BGP-LS Propagator "should not perform": the presence of
      # a mandatory TLV, whether a fixed-length TLV's length is correct
      # or a variable one's is permissible, whether TLV field values are
      # permissible, and whether a TLV is valid with a particular NLRI
      # type. bgp4r writes checks of all four shapes for EVPN and
      # MCAST-VPN, so for this family that is an instruction not to
      # rather than a gap. `docs/bgp-ls.md` section 8 lists them.
      #
      # **Which is why "the length of the TLVs are valid" below is not
      # the length check that is forbidden**, and the two sound alike.
      # The bullet asks whether a Length field is consistent with the
      # framing around it, so a TLV claiming more octets than its
      # container holds. The forbidden one asks whether a Length matches
      # the width a class expects, which is how an off-width TLV 1156
      # becomes a `Tlv::Unknown` here with nothing reported at all.
      #
      # **The whole set runs on MP_UNREACH too, where EVPN's and
      # MCAST-VPN's route checks do not.** Bullets 1 and 2 name
      # MP_REACH_NLRI and MP_UNREACH_NLRI in two sentences of the same
      # shape, and the rest are about the NLRI, which is the same object
      # in both. So this takes no `reach` argument: only the next hop is
      # MP_REACH's alone, and it has a method of its own above.
      #
      # **Section 8.2.2's two actions, chosen by its own criterion.**
      # "When the error that is determined allows for the router to skip
      # the malformed NLRI(s) and continue the processing of the rest of
      # the BGP UPDATE message (e.g., when the TLV ordering rule is
      # violated), then it MUST handle such malformed NLRIs as 'NLRI
      # discard'". Otherwise "the router SHOULD handle such malformed
      # NLRIs as 'AFI/SAFI disable' when other AFI/SAFI besides BGP-LS
      # are being advertised over the same session. Alternately, the
      # router MUST perform a 'session reset' when the session is only
      # being used for BGP-LS or if 'AFI/SAFI disable' action is not
      # possible."
      #
      # So the criterion is whether the rest of the UPDATE can still be
      # read, and that is the outer framing: while each NLRI's Total
      # NLRI Length lands inside the attribute, every other NLRI is
      # locatable and the error is skippable. The two framing findings
      # are the case where it does not, and they get a session reset,
      # which is the RFC's own alternate branch: `Attr::Check` is handed
      # one attribute at a time and cannot know what else the session
      # carries, so AFI/SAFI disable is not possible and the RFC says
      # what to do then. Part 6a added `:afi_safi_disable` to `ACTIONS`
      # all the same, for a caller that does have the session.
      #
      # **The criterion decides, not the parenthetical.** Section 8.2.2
      # offers "length-related encoding errors" as its example of the
      # non-skippable case, and that is looser than the criterion it
      # illustrates: a TLV Length that overruns one NLRI's body is
      # length-related and still leaves every other NLRI locatable, so
      # it is skippable. Read the sentence, not the example in brackets.
      def link_state_finding(type, nlri, safi)
        return nil unless safi == IANA::SAFI::BGP_LS or
                          safi == IANA::SAFI::BGP_LS_VPN
        framing = ::BGP::Link_state::FRAMING
        while nlri.size > 0
          size = ::BGP::Link_state.nlri_size(nlri)
          # Bullets 1 and 2: the NLRI list has to land on the attribute's
          # own end, or no sum over it can correspond to the attribute
          # length. Not skippable, so a session reset.
          if size.nil?
            return Finding.new(type, 9, RESET,
              "#{nlri.size} octet left, too few for a Link-State NLRI Type " \
              'and Total NLRI Length (RFC 9552 section 5.2)')
          end
          if size > nlri.size
            return Finding.new(type, 9, RESET,
              "Link-State NLRI of #{size} octets runs past the attribute, " \
              "#{nlri.size} left (RFC 9552 section 5.2)")
          end
          f = link_state_nlri_finding(type, nlri.getbyte(0) << 8 | nlri.getbyte(1),
                                     nlri.byteslice(framing, size - framing),
                                     safi)
          return f if f
          nlri = nlri.byteslice(size, nlri.size - size)
        end
        nil
      end

      # One Link-State NLRI's body, after its Type and Total NLRI Length.
      #
      # **An unknown NLRI type reports nothing, and that is section
      # 5.2's instruction rather than this family's posture.** "An
      # implementation MUST handle unknown Link-State NLRI types as
      # opaque objects and MUST preserve and propagate them." Nothing
      # establishes that such a body holds TLVs at all, so framing one
      # out of it would invent structure, and reporting it would make
      # bgp4r call a correct speaker malformed the day IANA assigns a
      # type. The four defined types come from `Link_state::TYPES` rather
      # than being written again here, so they cannot drift from it.
      #
      # The head is the Protocol-ID and the 8-octet Identifier that
      # figures 7 to 9 share, and for SAFI 72 a Route Distinguisher
      # before it (figure 6).
      def link_state_nlri_finding(type, nlri_type, body, safi)
        return nil if ::BGP::Link_state::TYPES[nlri_type].nil?
        head = ::BGP::Link_state::Headed::HEAD
        head += ::BGP::Link_state::RD_SIZE if safi == IANA::SAFI::BGP_LS_VPN
        # Bullet 3, from the bottom: a body with no room for the fields
        # that precede its TLVs cannot have a TLV sum at all.
        if body.size < head
          return Finding.new(type, 9, NLRI_DISCARD,
            "Link-State NLRI type #{nlri_type} has #{body.size} octets, too " \
            "few for its #{head} octet header (RFC 9552 section 5.2)")
        end
        tlvs = body.byteslice(head, body.size - head)
        link_state_tlv_finding(type, "NLRI type #{nlri_type}", tlvs, true) ||
          link_state_order_finding(type, nlri_type, tlvs)
      end

      # Bullets 3 and 4, and the attribute's 1 and 3, which are one walk:
      # "The sum of all TLV lengths found in a Link-State NLRI
      # corresponds to the Total NLRI Length field of all its
      # descriptors" and "The length of the TLVs and, when the TLV is
      # recognized then, the length of its sub-TLVs in the NLRI are
      # valid". A Length that overruns its container breaks the sum, and
      # a remainder too short to frame a TLV is the same failure from the
      # other end, so one walk answers both.
      #
      # _where_ names the container for the reason, and _nlri_ picks the
      # action: NLRI discard inside an NLRI, attribute discard inside the
      # BGP-LS Attribute. The framing octet counts and the sub-TLV
      # descent are the library's, so neither can drift from the classes.
      #
      # **"when the TLV is recognized" has exactly two cases in the
      # NLRI and none in the attribute.** The Node Descriptor TLVs, 256
      # and 257, are the only recognized TLVs in this family that carry
      # sub-TLVs, and no attribute TLV of RFC 9552's three tables carries
      # any. So the descent below is reachable only from an NLRI, and the
      # attribute half of that clause has no case to run on. An
      # unrecognized TLV's value is opaque and is not descended into,
      # which is what "when the TLV is recognized" says.
      def link_state_tlv_finding(type, where, tlvs, nlri)
        action = nlri ? NLRI_DISCARD : DISCARD
        f = ::BGP::Link_state::FRAMING
        i = 0
        while i < tlvs.size
          if tlvs.size - i < f
            return Finding.new(type, 9, action,
              "#{tlvs.size - i} octet left in #{where}, too few for a TLV " \
              'Type and Length (RFC 9552 section 5.1)')
          end
          t   = tlvs.byteslice(i, 2).unpack1('n')
          len = tlvs.byteslice(i + 2, 2).unpack1('n')
          if i + f + len > tlvs.size
            return Finding.new(type, 9, action,
              "TLV type #{t} of #{len} octets runs past #{where}, " \
              "#{tlvs.size - i - f} left (RFC 9552 section 5.1)")
          end
          if nlri and node_descriptor?(t)
            g = link_state_tlv_finding(type, "TLV type #{t} in #{where}",
                                       tlvs.byteslice(i + f, len), true) ||
                link_state_duplicate_finding(type, t, tlvs.byteslice(i + f, len))
            return g if g
          end
          i += f + len
        end
        nil
      end

      # The two TLVs whose sub-TLVs bullets 4 and 7 reach into, taken
      # from the classes so they cannot drift from the registry.
      def node_descriptor?(t)
        t == ::BGP::Link_state::Tlv::Local_node_descriptors.type or
          t == ::BGP::Link_state::Tlv::Remote_node_descriptors.type
      end

      # Bullet 7: "For NLRIs carrying either a Local or Remote Node
      # Descriptor TLV, there is not more than one instance of a sub-TLV
      # present." Section 5.2.1.4 is where the rule itself is: "At most,
      # there MUST be one instance of each sub-TLV type present in any
      # Node Descriptor."
      #
      # The counting is `Node_descriptors#duplicate_types`, so the rule
      # lives with the class that owns it, which is the house style
      # `flow_spec_rule_finding` records. The value is reparsed here
      # rather than taken from the decoder's output, because
      # `Attr::Check` runs on octets and the two channels stay
      # independent; the walk above has already bounded it.
      def link_state_duplicate_finding(type, t, value)
        dup = ::BGP::Link_state::Tlv::Local_node_descriptors
                .new(value.dup.is_packed).duplicate_types
        return nil if dup.empty?
        Finding.new(type, 9, NLRI_DISCARD,
          "TLV type #{t} carries sub-TLV type #{dup.join(', ')} more than " \
          'once (RFC 9552 sections 5.2.1.4 and 8.2.2)')
      end

      # Bullet 6: "The rule regarding the ordering of TLVs has been
      # followed as described in Section 5.1." Section 5.1: "all TLVs
      # within the NLRI MUST be ordered in ascending order by TLV Type.
      # If there are multiple TLVs of the same type within a single
      # NLRI, then the TLVs sharing the same type MUST be first in
      # ascending order based on the Length field followed by ascending
      # order based on the Value field." The comparison is
      # `Tlv.ordered?`, in one place, so this asks rather than
      # reimplementing it.
      #
      # This is the one check section 8.2.2 names as its own example of
      # a skippable error, so the action is not derived.
      #
      # **Section 5.1 qualifies the rule by role and section 8.2.2
      # overrides that.** 5.1 ends "NLRIs having TLVs that do not follow
      # the above ordering rules MUST be considered as malformed by a
      # BGP-LS Propagator", where bgp4r propagates no BGP-LS and would
      # not be one. 8.2.2 introduces its list with "A BGP-LS Speaker
      # MUST perform the following syntactic validation of the
      # Link-State NLRI to determine if it is malformed" and puts the
      # ordering rule in it. Speaker, not Propagator, in the section
      # whose subject is fault management, so the check is in scope and
      # the qualifier is settled by the document rather than by a
      # reading of it.
      #
      # **It is the NLRI's own TLVs and not their sub-TLVs**, which is
      # what keeps GoBGP's own traffic conformant here. Bullet 6 cites
      # section 5.1, whose rule is "all TLVs within the NLRI"; section
      # 5.2.1.4 states a separate ascending-order MUST for the sub-TLVs
      # within a Node Descriptor, and section 8.2.2 does not list it.
      # That it takes only the other half of 5.2.1.4, the once-only rule
      # of bullet 7, is what says its authors had that section open and
      # chose. So an unordered Node Descriptor is reported by
      # `Node_descriptors#ordered?` and by nothing here, which is also
      # the finding `docs/bgp-ls.md` section 11 measured: GoBGP 3.23.0
      # sends 512, 516, 513 on every route it originates.
      def link_state_order_finding(type, nlri_type, tlvs)
        list = ::BGP::Link_state::Tlv.parse_list(tlvs.dup.is_packed)
        return nil if ::BGP::Link_state::Tlv.ordered?(list)
        Finding.new(type, 9, NLRI_DISCARD,
          "Link-State NLRI type #{nlri_type} has TLV types " \
          "#{list.collect(&:type).join(', ')}, which are not in section 5.1 " \
          'order (RFC 9552 sections 5.1 and 8.2.2)')
      end

      # The BGP-LS Attribute, code 29, against the three bullets section
      # 8.2.2 gives it. They are the NLRI's 1, 3 and 4 over again one
      # level across: the TLV lengths must sum to the attribute's length,
      # each TLV's Length must be valid, and the attributes must be
      # syntactically correct per RFC 7606.
      #
      # **Every finding here is attribute discard, and that falls out of
      # the same criterion.** "When the error that is determined allows
      # for the router to skip the malformed BGP-LS Attribute and
      # continue the processing of the rest of the BGP UPDATE message
      # (e.g., when the BGP-LS Attribute length and the total Path
      # Attribute Length are correct but some TLV/sub-TLV length within
      # the BGP-LS Attribute is invalid), then it MUST handle such
      # malformed BGP-LS Attribute as 'Attribute Discard'." The
      # non-skippable case is the attribute's own length disagreeing with
      # the Path Attribute Length, and that is not this method's: it is
      # `next_attribute` and `attribute` above, which already answer it
      # for every attribute. So what is left for this family is the
      # skippable half.
      #
      # **Attribute discard is all or nothing by instruction**, which is
      # worth knowing before anyone tries to drop one bad TLV: "Note
      # that the 'Attribute Discard' action results in the loss of all
      # TLVs in the BGP-LS Attribute and not the removal of a specific
      # malformed TLV. The removal of specific malformed TLVs may give a
      # wrong indication to a BGP-LS Consumer of that specific
      # information being deleted or not available."
      #
      # **Bullet 2 is `flags_finding`'s, through one `FLAGS` entry.**
      # Section 5.3 makes the attribute "optional, non-transitive", so
      # `FLAGS[BGP_LS] = OPTIONAL` is the whole of "the syntactic
      # correctness of the Attributes (including the BGP-LS Attribute)
      # have been verified as per [RFC7606]" that is this family's to
      # add. Without the entry `flags_finding` takes any optional
      # attribute it does not know and says nothing.
      #
      # **The attribute's own TLV ordering is not checked and must not
      # be.** Section 5.1: "The TLVs within the BGP-LS Attribute SHOULD
      # be ordered in ascending order by TLV type. The BGP-LS Attribute
      # with unordered TLVs MUST NOT be considered malformed." A MUST
      # NOT, so reporting it would be a protocol error bgp4r invented.
      # That is why `Tlv.ordered?` makes its caller say which level it
      # is asking about.
      #
      # **An MP_REACH carrying Link-State NLRIs with no BGP-LS Attribute
      # is not an error either.** Section 8.2.2: it "is most likely an
      # indication that a BGP Speaker preceding it has performed the
      # 'Attribute Discard' fault handling", and an implementation
      # "SHOULD preserve and propagate the Link-State NLRIs". So the
      # absence is a diagnosis to pass on, not a fault to report, and
      # there is deliberately no check for it.
      def link_state_attribute_finding(type, v)
        link_state_tlv_finding(type, 'the BGP-LS Attribute', v, false)
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
