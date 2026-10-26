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
        when MP_REACH
          # AFI, SAFI, next hop length, next hop, reserved (RFC 4760 section 3).
          if n < 5 or 5 + v.getbyte(3) > n
            return Finding.new(type, 9, RESET, "next hop does not fit in #{n} octets (RFC 7606 section 7.11)")
          end
        when MP_UNREACH
          return Finding.new(type, 9, RESET, "length #{n}, AFI and SAFI need 3 (RFC 7606 section 7.11)") if n < 3
        end
        nil
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
