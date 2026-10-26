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

module BGP

  # Helpers that build the attribute shapes covered by RFC 7606, so a
  # conformance test can send each one and check the receiver's reply
  # against the RFC. Each helper takes an attribute and returns an
  # Attr::Raw with the field changed. Encoding is unchanged, so the
  # attribute goes out exactly as built.
  module Fault

    include ATTR

    # The catalog of RFC 7606 cases. Each entry is [name, description,
    # expected RFC 7606 action, UPDATE error subcode (RFC 4271 section
    # 6.3), RFC section, a block that builds the faulty form]. A
    # conformance test sends each and checks the reply.
    CATALOG = [
      [:origin_length,     'ORIGIN length not 1',            :treat_as_withdraw, 5, '7606 7.1',
        -> { Fault.truncate(Origin.new(0)) }],
      [:origin_value,      'ORIGIN value undefined',         :treat_as_withdraw, 6, '7606 7.1',
        -> { Fault.value(Origin.new(0), "\x03") }],
      [:origin_flags,      'ORIGIN flags conflict',          :treat_as_withdraw, 4, '7606 3 (c)',
        -> { Fault.flags(Origin.new(0), ATTR::OPTIONAL_TRANSITIVE) }],
      [:next_hop_length,   'NEXT_HOP length not 4',          :treat_as_withdraw, 5, '7606 7.3',
        -> { Fault.truncate(Next_hop.new('10.0.0.1'), 3) }],
      [:med_length,        'MULTI_EXIT_DISC length not 4',   :treat_as_withdraw, 5, '7606 7.4',
        -> { Fault.pad(Multi_exit_disc.new(10)) }],
      [:as_path_segment,   'AS_PATH segment overruns',       :treat_as_withdraw, 11, '7606 7.2',
        -> { Fault.truncate(As_path.new(100, 200), 3) }],
      [:atomic_length,     'ATOMIC_AGGREGATE length not 0',  :attribute_discard, 5, '7606 7.6',
        # Correct well-known flags, so only the length is wrong.
        # Atomic_aggregate.new itself uses OPTIONAL flags (a bug).
        -> { Attr::Raw.new(ATTR::WELL_KNOWN_DISCRETIONARY, ATTR::ATOMIC_AGGREGATE, "\x00".b) }],
      [:aggregator_length, 'AGGREGATOR length wrong',        :attribute_discard, 5, '7606 7.7',
        -> { Fault.truncate(Aggregator.new('10.0.0.1', 100), 5) }],
      [:community_length,  'COMMUNITIES length not /4',      :treat_as_withdraw, 5, '7606 7.8',
        -> { Fault.pad(Communities.new('100:1')) }],
      [:unknown_wellknown, 'unrecognized well-known type',   :session_reset,     2, '4271 6.3',
        -> { Attr::Raw.new(ATTR::WELL_KNOWN_MANDATORY, 240, "\x00".b) }],
      [:attr_overrun,      'length past the attribute list', :treat_as_withdraw, 1, '7606 4',
        -> { Fault.length(Origin.new(0), 20) }],
    ].freeze

    class << self

      # An Attr::Raw with the same flags, type and value octets as attr.
      def raw(attr)
        bytes = attr.encode
        flags = bytes.getbyte(0) >> 4
        hdr = (flags & ATTR::EXTENDED_LENGTH) > 0 ? 4 : 3
        Attr::Raw.new(flags, bytes.getbyte(1), bytes.byteslice(hdr, bytes.size - hdr))
      end

      # Keep the first n value octets. Default 0, an empty value.
      # RFC 7606 section 7: a short value is malformed for most types.
      def truncate(attr, n = 0)
        r = raw(attr)
        r.instance_variable_set(:@value, r.value.byteslice(0, n).to_s.b)
        r
      end

      # Add n octets to the value (zero, or the given byte).
      def pad(attr, n = 1, byte = 0)
        r = raw(attr)
        r.instance_variable_set(:@value, (r.value + ([byte].pack('C') * n)).b)
        r
      end

      # Set the length field to len without changing the value octets, so
      # the length and the value disagree (RFC 7606 section 4).
      def length(attr, len)
        raw(attr).override(length: len)
      end

      # Set the Attribute Flags high nibble to flags (the ATTR bit
      # constants). RFC 7606 section 3 (c).
      def flags(attr, flags)
        raw(attr).override(flags: flags)
      end

      # Set the attribute type code to type (RFC 4271 section 4.3).
      def retype(attr, type)
        raw(attr).override(type: type)
      end

      # Replace the value with bytes (a binary String or hex String).
      def value(attr, bytes)
        bytes = [bytes].pack('H*') if bytes.is_a?(String) and bytes =~ /\A(\h\h)+\z/
        r = raw(attr)
        r.instance_variable_set(:@value, bytes.to_s.b)
        r
      end

      # The CATALOG entries, as Hashes.
      def catalog
        CATALOG.collect { |name, desc, action, subcode, rfc, build|
          { :name => name, :description => desc, :action => action,
            :subcode => subcode, :rfc => "RFC #{rfc}", :build => build }
        }
      end

      # The faulty attribute named in the catalog.
      def build(name)
        entry = CATALOG.find { |e| e[0] == name }
        raise ArgumentError, "unknown fault #{name.inspect}, see Fault::CATALOG" unless entry
        entry[5].call
      end

    end
  end

end

load "../../test/unit/fault_test.rb" if __FILE__ == $0
