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

require 'ipaddr'
require 'socket'
require 'bgp/gen/spec'

module BGP
  class Gen
    # Patterns: how a value changes from one route to the next.
    #
    # A pattern is a **function of the route number and the seed and of
    # nothing else**, so the same spec gives the same octets every time,
    # withdrawals regenerate exactly what was announced, and no state is
    # carried between routes. docs/route-generation.md section 11 left
    # that open for `every`; it holds, because `every` is a division.
    #
    #   plain value         the same every time
    #   fixed:  v           the same every time
    #   cycle:  [a, b, c]   walk the list and start again
    #   step:   {start, by, wrap}  add `by` each time, back to start at wrap
    #   random: {min, max}  a value in the range, from the spec's seed
    #   every:  {n, values} the next value every n routes
    #
    # A value is one of four kinds, and a kind says which patterns it
    # takes. `:int` and `:addr` take all five. `:list`, an AS_PATH, and
    # `:strings`, a community list, take fixed, cycle and every over
    # whole lists, plus a property pattern of their own: `prepend` and
    # `length` for an AS_PATH, `count` with a `base` for a community list.
    # `step` and `random` over whole lists mean nothing and are refused.
    #
    # **Random is a fresh generator per route**, seeded from the spec's
    # seed, the value's name and the route number through FNV-1a. It
    # costs a Random per draw, and it is what makes route i's value not
    # depend on how many draws came before it, so a later pattern added
    # to a spec does not move the values of an earlier one. Array#hash
    # would be shorter and is seeded per process, so it is not used.
    module Vary
      module_function

      PATTERNS = %w[fixed cycle step random every].freeze
      LIST_PATTERNS = %w[fixed cycle every].freeze

      # Compiles `v`, a plain value or a one key Hash, into an object
      # answering `at(i)`. `name` is where it sits in the spec, for the
      # refusal and as the random salt; `kind` is above; `max` bounds an
      # :int. Raises SpecError for what it cannot read, and NeedsSeed is
      # raised as a SpecError when a random pattern has no seed.
      def compile(v, name, kind, max: nil, seed: nil)
        c = Context.new(name, kind, max, seed)
        c.compile(v)
      end

      # Whether a compiled value can differ from route to route. A fixed
      # one lets a generator build its attribute set once.
      def varies?(p) ; !p.is_a?(Fixed) ; end

      FNV_OFFSET = 0xcbf29ce484222325
      FNV_PRIME = 0x100000001b3
      MASK = 0xffffffffffffffff

      # FNV-1a over the octets of a string, 64 bits. Here rather than
      # Zlib's crc32 because zlib is a gem, and stable across every Ruby.
      def fnv(s)
        h = FNV_OFFSET
        s.each_byte { |b| h = ((h ^ b) * FNV_PRIME) & MASK }
        h
      end

      def rng(seed, name, i)
        Random.new(fnv("#{seed}:#{name}:#{i}"))
      end

      Fixed = Struct.new(:value) do
        def at(_i) ; value ; end
      end

      Cycle = Struct.new(:values) do
        def at(i) ; values[i % values.size] ; end
      end

      Every = Struct.new(:n, :values) do
        def at(i) ; values[(i / n) % values.size] ; end
      end

      # Integers and addresses both step as integers; an address is
      # turned back into text in its own family.
      Step = Struct.new(:start, :by, :wrap, :family) do
        def at(i)
          v = wrap ? start + (i * by) % (wrap - start) : start + i * by
          family ? IPAddr.new(v, family).to_s : v
        end
      end

      Rand = Struct.new(:min, :max, :family, :seed, :name) do
        def at(i)
          v = Vary.rng(seed, name, i).rand(min..max)
          family ? IPAddr.new(v, family).to_s : v
        end
      end

      # AS_PATH: `as` repeated `count` times in front of `path`.
      Prepend = Struct.new(:as, :count, :path) do
        def at(i) ; [as] * count.at(i) + path ; end
      end

      # AS_PATH: `length` AS numbers picked from a range.
      Random_path = Struct.new(:length, :min, :max, :seed, :name) do
        def at(i)
          r = Vary.rng(seed, name, i)
          Array.new(length.at(i)) { r.rand(min..max) }
        end
      end

      # A community list of `count` entries from `base`, the last number
      # of each one past the base counting up: 65000:1, 65000:2, ...
      Counted = Struct.new(:count, :head, :first) do
        def at(i) ; Array.new(count.at(i)) { |k| "#{head}#{first + k}" } ; end
      end

      class Context
        def initialize(name, kind, max, seed)
          @name, @kind, @max, @seed = name, kind, max, seed
        end

        def compile(v)
          return Fixed.new(plain(v)) unless v.is_a?(Hash)
          h = Spec.stringify(v, @name)
          unless h.size == 1
            raise SpecError, "#{@name} is a pattern of one key, not #{h.keys.inspect}"
          end
          key, arg = h.first
          case @kind
          when :int, :addr then scalar_pattern(key, arg)
          when :list then list_pattern(key, arg)
          when :strings then strings_pattern(key, arg)
          end
        end

        private

        def refuse(why) ; raise SpecError, "#{@name}: #{why}" ; end

        def scalar_pattern(key, arg)
          case key
          when 'fixed' then Fixed.new(scalar(arg))
          when 'cycle' then Cycle.new(list_of(arg) { |e| scalar(e) })
          when 'every' then every(arg) { |e| scalar(e) }
          when 'step'
            a = args(arg, %w[start by], %w[wrap])
            by = a['by']
            refuse("step.by is an integer, not #{by.inspect}") unless by.is_a?(Integer)
            start, wrap = number(a['start']), a['wrap'] && number(a['wrap'])
            refuse("step.wrap #{a['wrap']} is not above start #{a['start']}") if wrap && wrap <= start
            Step.new(start, by, wrap, family)
          when 'random'
            a = args(arg, %w[min max], [])
            min, max = number(a['min']), number(a['max'])
            refuse("random.min is above random.max") if min > max
            Rand.new(min, max, family, seed!, @name)
          else
            refuse("unknown pattern '#{key}'; a pattern is one of #{PATTERNS.join(', ')}")
          end
        end

        def list_pattern(key, arg)
          case key
          when 'fixed' then Fixed.new(path(arg))
          when 'cycle' then Cycle.new(list_of(arg) { |e| path(e) })
          when 'every' then every(arg) { |e| path(e) }
          when 'prepend'
            a = args(arg, %w[as count], %w[path])
            Prepend.new(asn(a['as']), count(a['count'], 'prepend.count'), path(a.fetch('path', [])))
          when 'length'
            a = args(arg, %w[count min max], [])
            min, max = asn(a['min']), asn(a['max'])
            refuse("length.min is above length.max") if min > max
            Random_path.new(count(a['count'], 'length.count'), min, max, seed!, @name)
          else
            refuse("unknown pattern '#{key}'; an AS_PATH takes #{(LIST_PATTERNS + %w[prepend length]).join(', ')}")
          end
        end

        def strings_pattern(key, arg)
          case key
          when 'fixed' then Fixed.new(strings(arg))
          when 'cycle' then Cycle.new(list_of(arg) { |e| strings(e) })
          when 'every' then every(arg) { |e| strings(e) }
          when 'count'
            a = args(arg, %w[base n], [])
            base = a['base']
            m = base.is_a?(String) && base.match(/\A(.*?)(\d+)\z/)
            refuse("count.base is a community ending in a number, not #{base.inspect}") unless m
            Counted.new(count(a['n'], 'count.n'), m[1], m[2].to_i)
          else
            refuse("unknown pattern '#{key}'; a community list takes #{(LIST_PATTERNS + %w[count]).join(', ')}")
          end
        end

        def family
          return nil unless @kind == :addr
          @family
        end

        def every(arg)
          a = args(arg, %w[n values], [])
          n = a['n']
          refuse("every.n is an integer of at least 1, not #{n.inspect}") unless n.is_a?(Integer) && n >= 1
          Every.new(n, list_of(a['values']) { |e| yield e })
        end

        def args(arg, required, optional)
          refuse("its argument is a Hash, not #{arg.inspect}") unless arg.is_a?(Hash)
          a = Spec.stringify(arg, @name)
          a.each_key { |k| refuse("unknown key '#{k}'; it takes #{(required + optional).join(', ')}") unless (required + optional).include?(k) }
          required.each { |k| refuse("#{k} is required") unless a.key?(k) }
          a
        end

        def list_of(arg)
          refuse("a list of values, not #{arg.inspect}") unless arg.is_a?(Array) && !arg.empty?
          arg.collect { |e| yield e }
        end

        # A count inside a property pattern is itself an :int value.
        def count(v, where)
          Context.new("#{@name}.#{where}", :int, 0xffff, @seed).compile(v)
        end

        def seed!
          refuse("a random pattern needs the spec's seed") unless @seed
          @seed
        end

        def plain(v)
          case @kind
          when :list then path(v)
          when :strings then strings(v)
          else scalar(v)
          end
        end

        def scalar(v)
          @kind == :addr ? address(v) : int(v)
        end

        def int(v)
          refuse("#{v.inspect} is not an integer") unless v.is_a?(Integer)
          refuse("#{v} is below 0") if v < 0
          refuse("#{v} does not fit its field, whose largest value is #{@max}") if @max && v > @max
          v
        end

        def address(v)
          a = ip(v)
          refuse("#{v} is not the family of the first address in this pattern") if @family && a.family != @family
          @family ||= a.family
          v
        end

        def ip(v)
          refuse("#{v.inspect} is not an address") unless v.is_a?(String)
          IPAddr.new(v)
        rescue IPAddr::Error
          refuse("#{v.inspect} is not an address")
        end

        # A step or random bound: an integer for :int, an address for
        # :addr, read as the integer it steps by.
        def number(v)
          return int(v) unless @kind == :addr
          address(v)
          ip(v).to_i
        end

        def asn(v)
          refuse("#{v.inspect} is not an AS number of 4 octets or fewer") unless v.is_a?(Integer) && (0..Spec::U32) === v
          v
        end

        def path(v)
          refuse("an AS_PATH is a list of AS numbers, not #{v.inspect}") unless v.is_a?(Array)
          v.collect { |as| asn(as) }
        end

        def strings(v)
          v = [v] if v.is_a?(String)
          refuse("a list of strings, not #{v.inspect}") unless v.is_a?(Array) && v.all? { |e| e.is_a?(String) }
          v.dup
        end
      end
    end
  end
end
