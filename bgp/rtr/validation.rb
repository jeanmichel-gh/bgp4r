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

require 'bgp/rtr/pdus'

module BGP
  module Rtr

    # What a receiver finds wrong in one PDU, as RFC 8210 section 12's
    # Error Code it would answer with. Building never checks; this is
    # the receive side's list, as bgp/path_attributes/validation.rb is
    # for an UPDATE's attributes.
    #
    #   Rtr::Validation.check(octets, :negotiated => 1)
    #   # => [#<Finding code=8 name="Unexpected Protocol Version" ...>]
    #
    # It reads one PDU's octets on its own. What needs a session's
    # memory, a withdrawal of a record never announced (6) or the same
    # one announced twice (7), is the router's to find, against its VRP
    # table.
    module Validation

      Finding = Struct.new(:code, :name, :detail) do
        def fatal? ; Rtr::ERRORS.fetch(code, [nil, true]).last ; end
        def to_s ; "#{name} (#{code}): #{detail}" ; end
      end

      # The Length each PDU Type has, by version; nil where it varies.
      LENGTHS = {
        0 => 12, 1 => 12, 2 => 8, 3 => 8, 4 => 20, 6 => 32, 8 => 8,
      }.freeze

      def self.finding(code, detail) ; Finding.new(code, Rtr.error_name(code), detail) ; end

      # The findings for one PDU's octets, worst first; [] for none.
      # negotiated: the version this session agreed (section 7), or nil
      # before it has.
      def self.check(octets, negotiated: nil)
        octets = octets.b
        return [finding(0, "#{octets.bytesize} octets, shorter than the 8 of a header")] if octets.bytesize < HEADER
        version, type, _f16, length = octets.unpack('CCnN')
        found = []
        # Section 7: "neither 0 nor 1", then a version other than the one
        # agreed.
        unless VERSIONS.include?(version)
          return [finding(4, "version #{version}, where 0 and 1 are known")]
        end
        if negotiated && version != negotiated
          return [finding(8, "version #{version} after #{negotiated} was negotiated")]
        end
        return [finding(5, "PDU type #{type}")] unless Pdu::TYPES.key?(type)
        found << finding(0, "Length #{length}, the PDU is #{octets.bytesize} octets") if length != octets.bytesize
        want = expected_length(version, type, octets)
        found << finding(0, "Length #{length}, a type #{type} PDU is #{want}") if want && length != want
        found << finding(5, 'a Router Key in version 0, which has none (RFC 8210 section 1.2)') if type == 9 && version.zero?
        found.concat(prefix_findings(type, octets)) if found.empty? && [4, 6].include?(type)
        found.concat(error_report_findings(octets)) if found.empty? && type == 10
        found
      end

      def self.expected_length(version, type, octets)
        return(version.zero? ? 12 : 24) if type == 7
        return nil if type == 9 && octets.bytesize >= 32
        return 32 if type == 9
        LENGTHS[type]
      end

      # Section 5.1: Max Length "MUST NOT be less than the Prefix Length",
      # and each is at most the address's bits.
      def self.prefix_findings(type, octets)
        bits = type == 4 ? 32 : 128
        _flags, len, max = octets.unpack('@8CCC')
        found = []
        found << finding(0, "Prefix Length #{len} is more than #{bits}") if len > bits
        found << finding(0, "Max Length #{max} is more than #{bits}") if max > bits
        found << finding(0, "Max Length #{max} is less than the Prefix Length #{len}") if max < len
        found
      end

      # Section 5.11: the two inner lengths have to fit.
      def self.error_report_findings(octets)
        body = octets.byteslice(HEADER..)
        return [finding(0, 'an Error Report with no Length of Encapsulated PDU')] if body.bytesize < 4
        n = body.unpack1('N')
        return [finding(0, "Length of Encapsulated PDU #{n} overruns the PDU")] if 4 + n + 4 > body.bytesize
        t = body.unpack1("@#{4 + n}N")
        return [finding(0, "Length of Error Text #{t} overruns the PDU")] if 8 + n + t != body.bytesize
        []
      end
    end
  end
end
