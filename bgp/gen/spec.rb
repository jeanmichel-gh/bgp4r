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

require 'bgp4r'

module BGP
  class Gen
    # A spec bgp4r cannot read: an unknown key, a family with no
    # generator, a value of the wrong type, or one a field cannot hold.
    # It is an ArgumentError because it is the caller's input that is
    # wrong. It is never raised for a route no RFC allows.
    class SpecError < ArgumentError ; end

    # A spec that reads but cannot be carried out: one route and its
    # attributes do not fit in one message.
    class Unpackable < SpecError ; end

    # The packer's arithmetic disagreed with a message it measured. That
    # is a bug in bgp4r and never the caller's fault, so it is not an
    # ArgumentError.
    class PackingError < StandardError ; end

    # Reads a spec into plain data with String keys, refusing what it
    # cannot read. **It checks types and nothing else**, which is the
    # first Conventions rule in CLAUDE.md: a spec may ask for a route no
    # RFC allows, and that is the point of a protocol testing tool. What
    # it refuses is a key it does not know, a value of the wrong JSON
    # type, and a number too large for the field it goes in, since
    # packing that would silently send a different value.
    #
    # Keys may be Strings or Symbols, so a Hash in a test and a parsed
    # JSON body read the same.
    module Spec
      module_function

      # The top level keys this phase reads.
      KEYS = %w[family afi count per_update start path_id attributes].freeze

      # Keys the spec format has that bgp4r does not read yet, with the
      # step of docs/route-generation.md section 12 that adds each. They
      # are refused by name rather than ignored: an ignored `seed` would
      # answer the same octets as a different seed, which is a wrong
      # answer and not a missing one.
      LATER = { 'seed' => 'phase 2', 'group' => 'phase 2' }.freeze

      # The announce block keys bgp4r already uses everywhere else.
      ATTRIBUTES = %w[origin next_hop as_path med local_pref
                      communities extended_communities large_communities].freeze

      U32 = 0xffffffff

      def read(spec)
        raise SpecError, "a spec is a Hash, not #{spec.class}" unless spec.is_a?(Hash)
        s = stringify(spec, 'spec')
        s.each_key do |k|
          raise SpecError, "'#{k}' is in the spec format and bgp4r does not read it yet (#{LATER[k]})" if LATER[k]
          raise SpecError, "unknown key '#{k}'; a spec takes #{KEYS.join(', ')}" unless KEYS.include?(k)
        end
        out = {}
        out['family'] = family(s.fetch('family', 'unicast'))
        out['start'] = string(s, 'start', true)
        out['count'] = integer(s, 'count', true, 1)
        out['per_update'] = integer(s, 'per_update', false, 1)
        out['afi'] = integer(s, 'afi', false, 0, 0xffff)
        out['path_id'] = integer(s, 'path_id', false, 0, U32)
        out['attributes'] = attributes(s.fetch('attributes', {}))
        out.reject { |_, v| v.nil? }
      end

      def family(v)
        v = v.to_s if v.is_a?(Symbol)
        raise SpecError, "family is a name, not #{v.inspect}" unless v.is_a?(String)
        v
      end

      def attributes(a)
        raise SpecError, "attributes is a Hash, not #{a.class}" unless a.is_a?(Hash)
        a = stringify(a, 'attributes')
        a.each_key do |k|
          raise SpecError, "unknown attribute '#{k}'; attributes take #{ATTRIBUTES.join(', ')}" unless ATTRIBUTES.include?(k)
          if a[k].is_a?(Hash)
            raise SpecError, "attributes.#{k} is a pattern, and bgp4r does not read patterns yet (phase 2)"
          end
        end
        out = {}
        out['origin'] = integer(a, 'origin', false, 0, 0xff, 'attributes.')
        out['next_hop'] = string(a, 'next_hop', false, 'attributes.')
        out['as_path'] = as_path(a['as_path']) if a.key?('as_path')
        out['med'] = integer(a, 'med', false, 0, U32, 'attributes.')
        out['local_pref'] = integer(a, 'local_pref', false, 0, U32, 'attributes.')
        %w[communities extended_communities large_communities].each do |k|
          out[k] = strings(a[k], k) if a.key?(k)
        end
        out.reject { |_, v| v.nil? }
      end

      def as_path(v)
        raise SpecError, "attributes.as_path is a list of AS numbers, not #{v.inspect}" unless v.is_a?(Array)
        v.each do |as|
          unless as.is_a?(Integer) && (0..U32) === as
            raise SpecError, "attributes.as_path holds #{as.inspect}, which is not an AS number of 4 octets or fewer"
          end
        end
        v.dup
      end

      def strings(v, k)
        v = [v] if v.is_a?(String)
        unless v.is_a?(Array) && v.all? { |e| e.is_a?(String) }
          raise SpecError, "attributes.#{k} is a list of strings, not #{v.inspect}"
        end
        v.dup
      end

      def string(h, k, required, path = '')
        v = h[k]
        raise SpecError, "#{path}#{k} is required" if v.nil? && required
        return nil if v.nil?
        raise SpecError, "#{path}#{k} is a string, not #{v.inspect}" unless v.is_a?(String)
        v
      end

      def integer(h, k, required, min, max = nil, path = '')
        v = h[k]
        raise SpecError, "#{path}#{k} is required" if v.nil? && required
        return nil if v.nil?
        raise SpecError, "#{path}#{k} is an integer, not #{v.inspect}" unless v.is_a?(Integer)
        raise SpecError, "#{path}#{k} is at least #{min}, not #{v}" if v < min
        raise SpecError, "#{path}#{k} #{v} does not fit its field, whose largest value is #{max}" if max && v > max
        v
      end

      def stringify(h, where)
        out = {}
        h.each do |k, v|
          key = k.is_a?(Symbol) ? k.to_s : k
          raise SpecError, "#{where} keys are names, not #{k.inspect}" unless key.is_a?(String)
          raise SpecError, "#{where} has '#{key}' twice, once as a String and once as a Symbol" if out.key?(key)
          out[key] = v
        end
        out
      end
    end
  end
end
