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


require 'bgp/gen/unicast'

module BGP
  class Gen
    # Labelled unicast, SAFI 4 (RFC 8277): unicast's prefixes with an MPLS
    # label in front of each, the label a value or a pattern on the route
    # number, as `path_id` is, because it is part of the NLRI and not of
    # the attributes.
    #
    # **One label per route.** RFC 8277 section 2.2 allows a stack, and
    # bgp4r builds one, but nothing here asks for a stack yet.
    #
    # **A withdrawal carries the Compatibility field and not the label.**
    # RFC 8277 section 2.4: "Upon transmission, the Compatibility field
    # SHOULD be set to 0x800000", in the three octets the label took.
    # bgp4r reads that field back as a Compatibility and not as a label,
    # so a receiver's Adj-RIB-In can be checked empty.
    #
    # The label field is 20 bits, RFC 3032 section 2.1, which is the one
    # refusal: a larger value cannot be written. Labels 0 to 15 are
    # reserved by RFC 3032 section 2.1 and are sent anyway, since building
    # never validates.
    class Labelled < Unicast
      SAFI = IANA::SAFI::LABEL_NLRI
      LABEL_MAX = Spec::LABEL_MAX

      # What a withdrawal puts where the label was, as the hex
      # `Label_stack` reads.
      COMPATIBILITY = '800000'

      def initialize(spec, sender = nil)
        unless spec['label']
          raise SpecError, 'a labelled spec needs a label, a value or a pattern from 0 to ' \
                           "#{LABEL_MAX} (RFC 3032 section 2.1)"
        end
        @label = Vary.compile(spec['label'], 'label', :int, max: LABEL_MAX, seed: spec['seed'])
        super
      end

      # The i-th route's label.
      def label(i) ; @label.at(i) ; end

      def route(i) ; [prefix(i), path_id(i), label(i)] ; end

      def route_row(i) ; super.merge('label' => label(i)) ; end

      # Three more octets than unicast, the one label of RFC 8277 section
      # 2.2's Figure 2, and the Compatibility field of section 2.4 on a
      # withdrawal is the same three.
      def route_octets ; super + 3 ; end

      private

      def mp_nlris(batch)
        batch.collect do |p, id, l|
          h = { :prefix => p, :label => l }
          h[:path_id] = id if id
          h
        end
      end

      def mp_withdrawn_nlris(batch)
        batch.collect do |p, id, _l|
          h = { :prefix => p, :compatibility => COMPATIBILITY }
          h[:path_id] = id if id
          h
        end
      end
    end
  end
end
