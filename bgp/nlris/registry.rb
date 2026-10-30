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

require 'bgp/common'
require 'bgp/iana'

module BGP

  # Which class reads and writes the NLRI of an address family.
  #
  # There were two hard coded `case safi` statements before this: one on
  # the build side in MpReachCommon#set and one on the parse side in
  # Nlri.factory. They could disagree, and they did, since the parse side
  # grouped SAFI 4 with 128 and 129 and the build side did not. Adding a
  # family meant editing both.
  #
  # This is the same answer the path attributes already use, where
  # Attr.register puts each attribute class in a registry under its hash
  # keys and Path_attribute never names an attribute class. A family
  # registers itself at the bottom of its own file, which is also why
  # each of those files requires this one.
  #
  # **Parse and build are two registries rather than one**, because the
  # two sides are not keyed alike and forcing them to be would mean
  # inventing an entry for one side that nothing reads. Parsing is keyed
  # by AFI and SAFI, since AFI 1 with SAFI 1 reads a whole NLRI list
  # where every other prefix family reads one prefix at a time. Building
  # is keyed by SAFI alone, since every AFI builds a family the same way.
  # Attr does the same thing with its two hashes, registered_types and
  # registered_keys.
  module Nlri_registry

    class << self

      # The parser for an address family. The block takes the octets, the
      # AFI, the SAFI, a Path Identifier (RFC 7911 section 3) or nil, and
      # the withdrawn flag Labeled.new_ntop wants, and returns an NLRI
      # object. afi: names one AFI, and left out the parser answers for
      # every AFI with this SAFI.
      def register_parse(safi, afi: :any, &blk)
        [safi].flatten.each { |s| nlri_parsers[[afi, s]] = blk }
      end

      # The builder for an address family. The block takes the :nlris
      # value as it was given, the AFI, the SAFI and the attribute level
      # Path Identifier, and returns the list of NLRI objects.
      def register_build(safi, &blk)
        [safi].flatten.each { |s| nlri_builders[s] = blk }
      end

      # The parser for this AFI and SAFI, or nil. An exact AFI match wins
      # over the :any one, which is how AFI 1 SAFI 1 differs from the
      # rest of SAFI 1.
      def parser(afi, safi)
        nlri_parsers[[afi, safi]] || nlri_parsers[[:any, safi]]
      end

      # The builder for this SAFI, or nil.
      def builder(safi)
        nlri_builders[safi]
      end

      # Every SAFI with a parser, for a test or a person to read. Not the
      # same question as which SAFIs a RIB will hold, which is
      # PeerAdapter::MP_SAFIS and is deliberately smaller.
      def registered_safis
        (nlri_parsers.keys.collect { |_, safi| safi } + nlri_builders.keys).uniq.sort
      end

      private

      def nlri_parsers
        @nlri_parsers ||= {}
      end

      def nlri_builders
        @nlri_builders ||= {}
      end

    end

  end

end
