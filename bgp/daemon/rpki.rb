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

require 'bgp/events'
require 'bgp/rtr/client'
require 'bgp/rtr/vrps'

module BGP
  module Daemon

    # Origin validation in bgp4rd, RFC 6811, from the VRPs of RPKI caches
    # over RTR (RFC 8210). The `rpki:` key:
    #
    #   rpki:
    #     caches: [{ address: 10.0.0.9, port: 323, preference: 1 }]
    #     invalid: accept      # accept | prefer_less | reject
    #     mark_ibgp: false     # RFC 8097's community toward internal peers
    #
    # One Rtr::Client per cache. The VRPs used are those of the most
    # preferred caches that have data: the lowest `preference` among the
    # caches synchronised and not expired, all of them at that
    # preference together (RFC 8210 sections 4 and 10). Each IPv4 and
    # IPv6 unicast route has a state, Valid, Invalid or NotFound, read
    # from them whenever it is asked for, so it follows each VRP change.
    # `invalid` is what the decision does with an Invalid route
    # (Rib::Decision), and a VRP change decides again the prefixes whose
    # routes it moved (RFC 6811 section 4).
    #
    # docs/design/bgp-operations.md 7c, docs/rpki.md.
    class Rpki

      KIND = BGP::Events.register_kind(:rpki)

      KEYS = %w[caches invalid mark_ibgp].freeze

      # RFC 6811 section 2: a route is not excluded "as a side effect of
      # its validation state, unless explicitly configured to do so".
      # prefer_less: an Invalid route loses to any Valid or NotFound one.
      # reject: an Invalid route is not used.
      INVALID = %w[accept prefer_less reject].freeze

      # How many routes an event names when a VRP change moves them.
      EXAMPLES = 10

      def self.check(config)
        raise ArgumentError, "rpki: a mapping with #{KEYS.join(', ')}, got #{config.inspect}" unless config.is_a?(Hash)
        unknown = config.keys.collect(&:to_s) - KEYS
        raise ArgumentError, "rpki: unknown key(s) #{unknown.join(', ')}: use #{KEYS.join(', ')}" unless unknown.empty?
        caches = config['caches']
        raise ArgumentError, 'rpki: caches is a list of at least one cache' unless caches.is_a?(Array) && !caches.empty?
        caches.each { |c| Rtr::Client.check(c) }
        names = caches.collect { |c| [IPAddr.new(c['address'].to_s).to_s, Integer(c.fetch('port', Rtr::PORT))] }
        raise ArgumentError, 'rpki: a cache is listed twice' unless names.uniq.size == names.size
        invalid = config.fetch('invalid', 'accept').to_s
        raise ArgumentError, "rpki: invalid #{invalid.inspect}: use #{INVALID.join(', ')}" unless INVALID.include?(invalid)
        unless [nil, true, false].include?(config['mark_ibgp'])
          raise ArgumentError, "rpki: mark_ibgp is true or false, got #{config['mark_ibgp'].inspect}"
        end
        config
      end

      attr_reader :clients, :invalid

      # speaker: what the states are for: its AS, its table and its
      # events. arg[:clock] goes to every Rtr::Client.
      def initialize(speaker, config, arg = {})
        Rpki.check(config)
        @speaker = speaker
        @invalid = config.fetch('invalid', 'accept').to_s
        @mark_ibgp = config['mark_ibgp'] ? true : false
        @logger = arg[:logger]
        @lock = Mutex.new
        @changing = Mutex.new
        @vrps = Rtr::Vrps.new
        events = ->(what, message, data) { publish(what, message, data) }
        @clients = config['caches'].collect do |c|
          Rtr::Client.new(c, :clock => arg[:clock], :logger => @logger, :events => events)
                     .on_change { changed }
        end
      end

      # True when routes to internal peers carry RFC 8097's community.
      def mark_ibgp? ; @mark_ibgp ; end

      def start ; @clients.each(&:start) ; self ; end
      def stop ; @clients.each(&:stop) ; self ; end

      # The VRPs used now.
      def vrps ; @lock.synchronize { @vrps } ; end

      # :valid, :invalid or :not_found for a unicast route, RFC 6811
      # section 2, with our AS for an empty AS_PATH.
      def state(route) ; vrps.state(route.prefix, route.origin_asn(@speaker.my_as)) ; end

      # The word the views use.
      def word(route) ; Rtr::Vrps::WORDS.fetch(state(route)) ; end

      # The caches, one row each, routescope's `rpki_caches` columns.
      def cache_rows ; @clients.collect(&:to_h) ; end

      # The VRPs used now, one row each, sorted.
      def vrp_rows
        vrps.to_a.sort_by { |a, l, m, asn| [a.include?(':') ? 1 : 0, IPAddr.new(a).to_i, l, m, asn] }
            .collect { |a, l, m, asn| { :prefix => "#{a}/#{l}", :max_length => m, :asn => asn } }
      end

      # What show.status says.
      def summary
        c = vrps.counts
        { :caches => @clients.size, :synced => @clients.count(&:synced?), :vrps_v4 => c[:v4], :vrps_v6 => c[:v6],
          :invalid => @invalid, :mark_ibgp => @mark_ibgp }
      end

      # A cache's VRPs changed: the set used now may change, and with it
      # the state of the routes those VRPs cover.
      #
      # One at a time, since each cache's thread calls it.
      def changed
        @changing.synchronize do
          now = chosen
          old = @lock.synchronize { was = @vrps ; @vrps = now ; was }
          next if now == old
          added, removed = old.diff(now)
          publish('vrps', "#{now.size} VRPs: #{added.size} added, #{removed.size} removed",
                  :vrps => now.size, :added => added.size, :removed => removed.size)
          moved(old, now, added, removed)
        end
      end

      private

      # The VRPs of the most preferred caches that have data.
      def chosen
        synced = @clients.select(&:synced?)
        best = synced.collect(&:preference).min
        Rtr::Vrps.new(synced.select { |c| c.preference == best }.flat_map { |c| c.vrps.to_a })
      end

      # RFC 6811 section 4: "the implementation MUST re-validate any
      # affected prefixes". The state is read from the VRPs each time,
      # so this says which routes moved, decides their prefixes again,
      # and, with mark_ibgp, sends internal peers the prefixes whose best
      # route kept its place and changed its state.
      def moved(old, now, added, removed)
        table = @speaker.rib
        return unless table
        local_as = @speaker.my_as
        moves = table.imported_routes { |prefix| added.covers?(prefix) || removed.covers?(prefix) }.filter_map do |r|
          asn = r.origin_asn(local_as)
          from, to = old.state(r.prefix, asn), now.state(r.prefix, asn)
          next if from == to
          { :prefix => r.prefix, :from => r.peer.address, :was => Rtr::Vrps::WORDS[from], :now => Rtr::Vrps::WORDS[to] }
        end
        return if moves.empty?
        publish('routes', "#{moves.size} route(s) changed state", :changed => moves.size, :routes => moves.first(EXAMPLES))
        prefixes = moves.collect { |m| m[:prefix] }.uniq
        decided = table.revalidate(prefixes).collect(&:prefix)
        mark(table, prefixes - decided) if @mark_ibgp
      end

      # The Router sends a prefix whose best route changed. One whose
      # best route stayed and changed state goes again to each internal
      # peer, with the community it now carries.
      def mark(table, prefixes)
        router = table.router
        return if router.nil?
        router.peers.select(&:ibgp?).each do |peer|
          table.resend(peer.address, prefixes)
        rescue StandardError => e
          @logger&.call(:warn, "bgp4r: rpki: resend to #{peer.address}: #{e.message}")
        end
      end

      def publish(what, message, data)
        @speaker.events.publish(:kind => KIND, :message => "RPKI #{message}", :data => { :event => what }.merge(data))
      end
    end
  end
end
