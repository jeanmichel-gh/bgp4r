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
require 'bgp/gen/spec'
require 'bgp/gen/vary'

module BGP
  class Gen
    # Churn: a sequence of changes to routes a spec has already
    # announced, which is what tests a receiver's decision process and
    # its MRAI handling. docs/route-generation.md section 8.
    #
    #   g = BGP::Gen.new(spec)
    #   c = g.churn('events' => 1000, 'routes' => 10, 'withdraw' => 0.2,
    #               'attributes' => { 'med' => { 'step' => { 'start' => 1 } } })
    #   c.events.each { |e| neighbor.send_message e.update }
    #   c.expected   # what the receiver should hold afterwards
    #
    # **Each event is one route in one UPDATE**, picked from the first
    # `routes` of the spec. It is one of three kinds:
    #
    # * `withdraw`: an explicit withdrawal (RFC 4271 section 4.3).
    # * `replace`: the route announced again, which replaces the one the
    #   receiver holds, the implicit withdrawal of RFC 4271 section 3.1.
    #   It carries the churn's `attributes`, read at the event number, so
    #   a `step` on `med` makes every replacement differ. **With no
    #   `attributes` a replacement repeats the route's attributes**,
    #   which is still a replacement on the wire and is a case of its
    #   own: a receiver that does work for a duplicate shows it here.
    # * `announce`: a route the churn withdrew, announced again, with the
    #   churn's attributes at that event.
    #
    # A route that is held is withdrawn with probability `withdraw` and
    # replaced otherwise; a route that is not held is announced. So the
    # share is of explicit withdrawals against implicit ones, which is
    # what section 8 asks for.
    #
    # **It is pure like the rest of bgp/gen.** The picks come from one
    # Random seeded from `seed` through FNV-1a, two draws per event
    # whatever the kind, so the same churn gives the same events every
    # time and a change to `withdraw` does not move which routes are
    # picked. `rate` and `duration` are read and kept, and nothing here
    # sleeps: pacing is the sender's, which is `bgp4r-sim`'s `churn`
    # action. With `duration` and no `events`, the count is
    # rate x duration, rounded.
    #
    # **It starts from the spec announced in full.** It does not know
    # what a receiver holds, so a churn sent before the spec's own
    # UPDATEs withdraws routes the receiver never had, and `expected`
    # is then wrong. That is the caller's order to keep.
    class Churn
      KEYS = %w[events routes withdraw seed attributes rate duration].freeze

      KINDS = %w[withdraw replace announce].freeze

      # One change: its number from 0, its kind, the route's number in
      # the spec, and the UPDATE that makes it.
      Event = Struct.new(:number, :kind, :route, :update)

      attr_reader :events_count, :routes, :withdraw, :seed, :rate, :duration, :spec

      # `gen` is a BGP::Gen and `generator` its family generator, which
      # Gen#churn hands over; `churn` a Hash of KEYS, String or Symbol.
      def initialize(gen, generator, churn)
        @gen, @generator = gen, generator
        read(churn, gen.spec)
      end

      # How many events, which `events` gave or rate x duration made.
      def count ; @events_count ; end

      # Seconds between two events at `rate`, or nil to send at once.
      def interval ; @rate && 1.0 / @rate ; end

      # The events, as an Enumerator, each with its UPDATE built.
      def events
        Enumerator.new(@events_count) do |y|
          walk do |k, kind, i|
            msg = if kind == 'withdraw'
                    @generator.withdrawal_for(i)
                  else
                    @generator.with_overlay(@overlay, k) { @generator.update_for(i) }
                  end
            y << Event.new(k, kind, i, msg)
          end
        end
      end

      # How many events of each kind, and how many routes are held at
      # the end, with no UPDATE built.
      def summary
        tally = KINDS.to_h { |k| [k, 0] }
        state = walk { |_, kind, _| tally[kind] += 1 }
        withdrawn = state.count { |_, s| s == :withdrawn }
        { 'events' => @events_count, 'kinds' => tally,
          'withdrawn' => withdrawn, 'held' => @gen.total - withdrawn }
      end

      # One row per route held after every event, in the spec's order:
      # the spec's own row for a route the churn left alone, and the
      # churn's attributes at the last event that announced it for one
      # it did not. A route it withdrew last has no row.
      def expected
        state = walk { }
        Enumerator.new do |y|
          @gen.expected.each_with_index do |row, i|
            s = state[i]
            next y << row if s.nil?
            next if s == :withdrawn
            y << @generator.with_overlay(@overlay, s) { @generator.expected_for(i) }
          end
        end
      end

      private

      # Yields each event as [number, kind, route] and answers the state
      # at the end: route => :withdrawn, or the number of the event that
      # last announced it. A route absent from it holds the spec's row.
      def walk
        rng = Random.new(Vary.fnv("#{@seed}:churn"))
        state = {}
        @events_count.times do |k|
          i = rng.rand(@routes)
          coin = rng.rand
          kind = if state[i] == :withdrawn then 'announce'
                 elsif coin < @withdraw then 'withdraw'
                 else 'replace'
                 end
          state[i] = kind == 'withdraw' ? :withdrawn : k
          yield k, kind, i
        end
        state
      end

      def read(churn, spec)
        raise SpecError, "a churn is a Hash, not #{churn.class}" unless churn.is_a?(Hash)
        c = Spec.stringify(churn, 'churn')
        c.each_key do |k|
          raise SpecError, "unknown churn key '#{k}'; a churn takes #{KEYS.join(', ')}" unless KEYS.include?(k)
        end
        @seed = Spec.integer(c, 'seed', false, 0, nil, 'churn.') || spec['seed'] || 0
        @rate = number(c, 'rate')
        @duration = number(c, 'duration')
        events = Spec.integer(c, 'events', false, 1, nil, 'churn.')
        if events && @duration
          raise SpecError, 'churn takes events or duration, not both: duration counts its events from rate'
        elsif @duration
          raise SpecError, 'churn duration needs a rate, events per second' unless @rate
          events = [(@rate * @duration).round, 1].max
        end
        raise SpecError, 'churn needs events, or rate and duration' unless events
        @events_count = events
        @routes = Spec.integer(c, 'routes', false, 1, @gen.total, 'churn.') || @gen.total
        w = c.fetch('withdraw', 0.5)
        unless w.is_a?(Numeric) && w >= 0 && w <= 1
          raise SpecError, "churn.withdraw is a share from 0 to 1, not #{w.inspect}"
        end
        @withdraw = w
        a = c.fetch('attributes', {})
        raise SpecError, "churn.attributes is a Hash, not #{a.class}" unless a.is_a?(Hash)
        a = Spec.stringify(a, 'churn.attributes')
        @overlay = a.to_h { |k, v|
          unless Spec::ATTRIBUTES.include?(k)
            raise SpecError, "unknown churn attribute '#{k}'; attributes take #{Spec::ATTRIBUTES.join(', ')}"
          end
          kind, max = Spec::ATTRIBUTE_KINDS[k]
          [k, Vary.compile(v, "churn.attributes.#{k}", kind, max: max, seed: @seed)]
        }
        a = a.to_h { |k, v| [k, Spec.value(v, "churn.attributes.#{k}", *Spec::ATTRIBUTE_KINDS[k], @seed)] }
        @overlay = nil if @overlay.empty?
        @spec = { 'events' => @events_count, 'routes' => @routes, 'withdraw' => @withdraw,
                  'seed' => @seed, 'attributes' => a }
        @spec['rate'] = @rate if @rate
        @spec['duration'] = @duration if @duration
      end

      def number(c, k)
        v = c[k]
        return nil if v.nil?
        unless v.is_a?(Numeric) && v > 0
          raise SpecError, "churn.#{k} is a number above 0, not #{v.inspect}"
        end
        v
      end
    end

    # A Churn of the routes this spec announces. See bgp/gen/churn.rb.
    def churn(c) ; Churn.new(self, @generator, c) ; end
  end
end
