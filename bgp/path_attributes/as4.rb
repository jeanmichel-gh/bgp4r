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

require 'bgp/path_attributes/path_attribute'

module BGP

  # 4-octet AS numbers between a NEW and an OLD speaker (RFC 6793).
  #
  # Both helpers are explicit. Encoding never changes what was built,
  # so a test can still send a truncated AS number on purpose.
  #
  #   as4_fixup   what a NEW speaker sends to an OLD one (section 4.2.2)
  #   as4_merge   what a NEW speaker rebuilds from an OLD one (section 4.2.3)
  #
  # Both return a new Path_attribute and leave the attributes of the
  # receiver as they are. The bang versions replace the attributes in place.
  class Path_attribute

    # RFC 6793 section 4.2.2. Every AS number above 65535 in AS_PATH and
    # AGGREGATOR becomes AS_TRANS. The real numbers go in AS4_PATH and
    # AS4_AGGREGATOR. AS4_PATH leaves out the confederation segments.
    # An AS4_PATH or AS4_AGGREGATOR the caller already added is kept.
    def as4_fixup
      attrs = attributes.dup
      # A raw or malformed AS_PATH or AGGREGATOR is passed through as it
      # is: bgp4r must be able to send one to a router under test.
      as_path = attrs.find { |a| a.type == AS_PATH and a.respond_to?(:segments) }
      if as_path and As4.large?(as_path)
        unless attrs.find { |a| a.type == AS4_PATH }
          segs = as_path.segments.reject { |seg| As4.confed?(seg) }
          attrs << As4_path.new(*segs.collect { |seg| As4.copy(seg, seg.as) }) unless segs.empty?
        end
        attrs[As4.index(attrs, as_path)] = As4.with_as_trans(as_path)
      end
      aggregator = attrs.find { |a| a.type == AGGREGATOR and a.respond_to?(:asn) }
      if aggregator and aggregator.asn > 0xffff
        unless attrs.find { |a| a.type == AS4_AGGREGATOR }
          attrs << As4_aggregator.new(aggregator.address, aggregator.asn)
        end
        attrs[As4.index(attrs, aggregator)] = Aggregator.new(aggregator.address, AS_TRANS)
      end
      Path_attribute.new(*attrs)
    end

    def as4_fixup!
      @attributes = as4_fixup.attributes
      self
    end

    # RFC 6793 section 4.2.3. Rebuilds the 4-octet AS_PATH and AGGREGATOR
    # from what an OLD speaker sent, and drops AS4_PATH and AS4_AGGREGATOR.
    #
    # * AGGREGATOR with a real AS number (not AS_TRANS): AS4_AGGREGATOR and
    #   AS4_PATH are ignored.
    # * AS_PATH with fewer AS numbers than AS4_PATH: AS4_PATH is ignored.
    # * Otherwise the leading AS numbers of AS_PATH that AS4_PATH lacks are
    #   put in front of AS4_PATH.
    #
    # AS numbers are counted as in RFC 4271 section 9.1.2.2: a SET counts
    # as one, a confederation segment as zero (RFC 5065 section 5.3).
    def as4_merge
      attrs = attributes.dup
      as4_path = attrs.find { |a| a.type == AS4_PATH and a.respond_to?(:segments) }
      as4_aggregator = attrs.find { |a| a.type == AS4_AGGREGATOR and a.respond_to?(:asn) }
      aggregator = attrs.find { |a| a.type == AGGREGATOR and a.respond_to?(:asn) }
      attrs.reject! { |a| a.equal?(as4_path) or a.equal?(as4_aggregator) }
      if aggregator and aggregator.asn != AS_TRANS and as4_aggregator
        return Path_attribute.new(*attrs)
      end
      if aggregator and as4_aggregator
        attrs[As4.index(attrs, aggregator)] = Aggregator.new(as4_aggregator.address, as4_aggregator.asn)
      end
      as_path = attrs.find { |a| a.type == AS_PATH }
      if as_path and as4_path
        merged = As4.merge(as_path, as4_path)
        attrs[As4.index(attrs, as_path)] = merged if merged
      end
      Path_attribute.new(*attrs)
    end

    def as4_merge!
      @attributes = as4_merge.attributes
      self
    end

    module As4

      CONFED = [ATTR::CONFED_SEQUENCE, ATTR::CONFED_SET]

      class << self

        # Attr compares by type code, so find the object itself.
        def index(attrs, attr)
          attrs.index { |a| a.equal?(attr) }
        end

        def large?(as_path)
          as_path.segments.any? { |seg| seg.as.any? { |as| as > 0xffff } }
        end

        def confed?(seg)
          CONFED.include?(seg.seg_type)
        end

        # A new segment of the same type holding as. A segment built from
        # values needs at least one AS number, so an empty one, as parsed
        # from the wire, is rebuilt from its two header octets.
        def copy(seg, as)
          return seg.class.new(*as) unless as.empty?
          seg.class.new([seg.seg_type, 0].pack('CC'))
        end

        def with_as_trans(as_path)
          segs = as_path.segments.collect { |seg|
            copy(seg, seg.as.collect { |as| as > 0xffff ? ATTR::AS_TRANS : as })
          }
          As_path.new(*segs)
        end

        # RFC 4271 section 9.1.2.2 and RFC 5065 section 5.3.
        def count(seg)
          case seg.seg_type
          when ATTR::SEQUENCE ; seg.as.size
          when ATTR::SET      ; 1
          else                ; 0
          end
        end

        # RFC 6793 section 4.2.3. Returns the merged AS_PATH, or nil when
        # AS4_PATH is to be ignored.
        def merge(as_path, as4_path)
          need = as_path.segments.sum { |seg| count(seg) } -
                 as4_path.segments.sum { |seg| count(seg) }
          return nil if need < 0
          lead = []
          as_path.segments.each do |seg|
            break if need == 0 and not confed?(seg)
            if seg.seg_type == ATTR::SEQUENCE
              take = [need, seg.as.size].min
              lead << copy(seg, seg.as[0, take])
              need -= take
            else
              need -= count(seg)
              lead << copy(seg, seg.as)
            end
          end
          tail = as4_path.segments.collect { |seg| copy(seg, seg.as) }
          # Join the cut sequence with the first AS4_PATH sequence.
          if lead.last and tail.first and
             lead.last.seg_type == ATTR::SEQUENCE and tail.first.seg_type == ATTR::SEQUENCE
            joined = copy(lead.last, lead.last.as + tail.first.as)
            lead[-1] = joined
            tail.shift
          end
          merged = As_path.new(*(lead + tail))
          merged.as4byte = true
          merged
        end

      end
    end

  end

end
