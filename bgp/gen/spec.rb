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

      # The top level keys a spec takes.
      KEYS = %w[family afi count per_update start path_id seed group attributes].freeze

      # The announce block keys bgp4r already uses everywhere else, with
      # the kind of value each is, which says the patterns it takes, and
      # the largest value a field of it can hold. See bgp/gen/vary.rb.
      ATTRIBUTE_KINDS = {
        'origin'               => [:int, 0xff],
        'next_hop'             => [:addr, nil],
        'as_path'              => [:list, nil],
        'med'                  => [:int, 0xffffffff],
        'local_pref'           => [:int, 0xffffffff],
        'communities'          => [:strings, nil],
        'extended_communities' => [:strings, nil],
        'large_communities'    => [:strings, nil],
      }.freeze
      ATTRIBUTES = ATTRIBUTE_KINDS.keys.freeze

      U32 = 0xffffffff

      # The spec as plain data with String keys: a plain value in the
      # form it is sent in, a single community string as a list of one,
      # and a pattern as its Hash. Every value goes through Vary.compile
      # here, so a pattern bgp4r cannot read is refused when the spec is,
      # and `patterns` compiles the same values again for a generator.
      def read(spec)
        raise SpecError, "a spec is a Hash, not #{spec.class}" unless spec.is_a?(Hash)
        s = stringify(spec, 'spec')
        s.each_key do |k|
          raise SpecError, "unknown key '#{k}'; a spec takes #{KEYS.join(', ')}" unless KEYS.include?(k)
        end
        out = {}
        out['family'] = family(s.fetch('family', 'unicast'))
        out['start'] = string(s, 'start', true)
        out['count'] = integer(s, 'count', true, 1)
        out['per_update'] = integer(s, 'per_update', false, 1)
        out['afi'] = integer(s, 'afi', false, 0, 0xffff)
        out['seed'] = integer(s, 'seed', false, 0)
        out['group'] = integer(s, 'group', false, 1)
        out['path_id'] = value(s['path_id'], 'path_id', :int, U32, out['seed']) if s.key?('path_id')
        out['attributes'] = attributes(s.fetch('attributes', {}), out['seed'])
        out.reject { |_, v| v.nil? }
      end

      # The compiled patterns of a spec `read` answered: 'path_id' and
      # one per attribute given, each answering `at(i)`.
      def patterns(spec)
        out = {}
        out['path_id'] = Vary.compile(spec['path_id'], 'path_id', :int, max: U32, seed: spec['seed']) if spec['path_id']
        spec['attributes'].each do |k, v|
          kind, max = ATTRIBUTE_KINDS[k]
          out[k] = Vary.compile(v, "attributes.#{k}", kind, max: max, seed: spec['seed'])
        end
        out
      end

      def family(v)
        v = v.to_s if v.is_a?(Symbol)
        raise SpecError, "family is a name, not #{v.inspect}" unless v.is_a?(String)
        v
      end

      def attributes(a, seed)
        raise SpecError, "attributes is a Hash, not #{a.class}" unless a.is_a?(Hash)
        a = stringify(a, 'attributes')
        out = {}
        a.each do |k, v|
          raise SpecError, "unknown attribute '#{k}'; attributes take #{ATTRIBUTES.join(', ')}" unless ATTRIBUTES.include?(k)
          kind, max = ATTRIBUTE_KINDS[k]
          out[k] = value(v, "attributes.#{k}", kind, max, seed)
        end
        out
      end

      # One value, compiled to check it and kept as plain data: what a
      # fixed value is sent as, or the pattern's Hash with String keys.
      def value(v, name, kind, max, seed)
        p = Vary.compile(v, name, kind, max: max, seed: seed)
        p.is_a?(Vary::Fixed) ? p.value : deep_stringify(v, name)
      end

      def deep_stringify(v, name)
        case v
        when Hash then stringify(v, name).transform_values { |e| deep_stringify(e, name) }
        when Array then v.collect { |e| deep_stringify(e, name) }
        else v
        end
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

require 'bgp/gen/vary'
