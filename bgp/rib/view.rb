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

require 'bgp/rib/decision'

module BGP
  module Rib

    # The table's operational state as plain data: Hashes and Arrays with
    # Symbol keys, ready for JSON. No text and no formatting.
    #
    #   view = rib.view
    #   view.status                  # the router, its peers, a summary
    #   view.routes                  # one row per prefix, its best path
    #   view.rib                     # every candidate path, and the decision
    #   view.rib('10.0.0.0/8')       # one prefix
    #   view.json(:rib)              # the same as JSON text
    #
    # **Why this exists rather than a console parsing `rib.show`.** Show
    # prints three vendor styles and says of all three that no output has
    # been diffed against a real device, so nothing should depend on that
    # text byte for byte. A driver reading it would be exactly such a
    # dependency. So the data comes out here and the formatting stays
    # there, which is how ospfv2 splits the same problem: one shape serves
    # its Junos output, its IOS output and its JSON.
    #
    # Show reads +prefixes+, +paths+ and +usable?+ from here, so there is
    # one definition of "the paths to a prefix, best first, with why each
    # one lost". Those three answer Route objects rather than plain data
    # and are the shared basis, not part of the JSON surface.
    #
    # **The key rule, which is the whole contract.** A key is present when
    # this layer can answer it, and absent when another layer owns the
    # answer. A key present with nil means the answer is known and is
    # nothing: no MULTI_EXIT_DISC, no Path Identifier. So +med+ is nil
    # where Show prints 0, because printing 0 is a vendor convention and a
    # route with no MED is not a route with a MED of zero.
    #
    # What another layer owns, and so is not here: every session fact, so
    # a peer's state, uptime, flap count, last error and negotiated
    # capabilities, which belong to a Neighbor; and the daemon's own
    # uptime. docs/daemon.md names them under +show.status+, and the
    # daemon merges them onto what +status+ answers here rather than
    # renaming anything, which is why the keys here are its keys.
    #
    # **A prefix with no best route is not here either**, because the
    # Loc-RIB is what is walked and it holds only prefixes that have one
    # (see LocRib#update). A prefix whose every path is ineligible is
    # therefore invisible, where a prefix with one usable path shows its
    # ineligible paths beside it. Show has the same blind spot, from the
    # same line.
    class View

      # The views, which are docs/daemon.md's control API names with the
      # +show.+ dropped.
      VIEWS = %i[status routes rib].freeze

      # ORIGIN spelled out (RFC 4271 section 5.1.1: 0 IGP, 1 EGP, 2
      # INCOMPLETE). Lower case, which is docs/daemon.md's shape and not
      # Show::ORIGIN_WORDS, whose casing is IOS-XR's own.
      ORIGINS = { 0 => :igp, 1 => :egp, 2 => :incomplete }.freeze

      # Why a path is not the best one, in words for a person, one entry
      # per value Decision::Result#eliminated can carry.
      #
      # The ten tie breaks of Decision::STEPS, the four reasons of
      # Decision::INELIGIBLE, and :duplicate. **docs/daemon.md said
      # fourteen and the fifteenth is :duplicate**, which Decision#best
      # files when only identical routes are left. It cannot be reached
      # through a Table, because an imported route is keyed by its peer
      # and Path Identifier and a Peer is its address, so two candidates
      # always differ at :peer_address or :path_id; Decision#best is
      # public and pure, so it can be reached directly.
      #
      # The words are this library's, since no router prints them, and
      # they name the attribute rather than the step so a reader who does
      # not know bgp4r's symbols can still read them.
      LOST_WORDS = {
        :local_pref          => 'lower LOCAL_PREF',
        :as_path_length      => 'longer AS_PATH',
        :origin              => 'higher ORIGIN',
        :med                 => 'higher MED from the same neighbouring AS',
        :ebgp_over_ibgp      => 'learned from an internal peer, where another path came from an external one',
        :igp_cost            => 'higher interior cost to the next hop',
        :router_id           => 'higher BGP Identifier',
        :cluster_list_length => 'longer CLUSTER_LIST',
        :peer_address        => 'higher peer address',
        :path_id             => 'higher Path Identifier',
        :next_hop_unreachable => 'the next hop cannot be resolved',
        :as_loop             => 'our own AS is in the AS_PATH',
        :originator_id_loop  => 'the ORIGINATOR_ID is our own router ID',
        :cluster_list_loop   => 'our cluster ID is in the CLUSTER_LIST',
        :duplicate           => 'the same path arrived more than once'
      }.freeze

      # Why the best path won, for the two Decision::Result reasons that
      # are not a step. Every other reason is a step, and those read
      # "best path, decided at the <step> step" with bgp4r's own symbol
      # left in it on purpose, the way Show leaves a step name in
      # snake_case: it is greppable against Decision::STEPS, where an
      # invented phrase would read as a quote from a router.
      WON_WORDS = {
        :only_route => 'best path, the only usable path',
        :duplicate  => 'best path, chosen between identical paths'
      }.freeze

      attr_reader :table

      def initialize(table)
        @table = table
      end

      # The router, its peers and a summary. See the class comment for
      # what a session owns and this does not.
      def status
        @table.synchronize do
          { :router_id => @table.router_id,
            :as        => @table.local_as,
            :summary   => summary,
            :peers     => peer_rows }
        end
      end

      # One row per prefix, carrying its best path. With a prefix, that
      # one row or none. Table#best cannot answer nil here, since
      # each_prefix answers only prefixes the Loc-RIB holds and it holds
      # none without a best route.
      def routes(prefix = nil)
        @table.synchronize do
          each_prefix(prefix).map do |p|
            result = @table.result(p)
            { :prefix => p }.merge(fields(@table.best(p)))
                            .merge(:paths => @table.candidates(p).size, :best => true,
                                   :decided_by => result && result.reason)
          end
        end
      end

      # Every candidate path per prefix, with the decision: which one won,
      # where each other one lost, and why in words. This is the answer no
      # other implementation in a lab can give about itself, and it is a
      # serialisation of Decision::Result rather than a second decision.
      def rib(prefix = nil)
        @table.synchronize do
          each_prefix(prefix).map do |p|
            result = @table.result(p)
            step = result && result.reason
            { :prefix     => p,
              :decided_by => step,
              :paths      => paths(p).map { |route, lost_at| path(route, lost_at, step) } }
          end
        end
      end

      # A view as JSON text. prefix narrows :routes and :rib, and :status
      # takes none.
      #
      # The require is here and not at the top of the file on purpose.
      # json is a default gem today, measured on Ruby 3.3.6, but
      # Conventions records twice over that the local Ruby is not the CI
      # Ruby and that a bundled gem missing under Bundler kills the
      # *require*, so a top level one would take the whole library down at
      # load time on some future Ruby rather than failing in the one
      # method that wanted it.
      def json(what = :rib, prefix = nil, pretty: false)
        what = what.to_sym
        unless VIEWS.include?(what)
          raise ArgumentError, "unknown view #{what.inspect}, use #{VIEWS.inspect}"
        end
        raise ArgumentError, 'status takes no prefix' if what == :status && prefix
        require 'json'
        data = what == :status ? status : send(what, prefix)
        pretty ? JSON.pretty_generate(data) : JSON.generate(data)
      end

      # The Loc-RIB's prefixes, IPv4 before IPv6, then by address, then by
      # prefix length, which is near enough to what a router prints and is
      # at least stable. The family is in the key because an IPv6 address
      # is not always the larger integer: ::/0 is 0.
      def prefixes
        @table.synchronize { @table.loc_rib.prefixes.sort_by { |p| prefix_key(p) } }
      end

      # Every path to prefix as [route, lost_at], the best one first with a
      # nil lost_at, then the ones that lost. Empty when the prefix has no
      # best route. Route objects, so this is the basis Show shares and
      # not plain data.
      def paths(prefix)
        @table.synchronize do
          result = @table.result(prefix)
          next [] unless result
          rest = @table.candidates(prefix).reject { |r| result.best && r.equal?(result.best) }
          [[result.best, nil]] + rest.map { |r| [r, (result.eliminated || {})[r]] }
        end
      end

      # True when a path took part in the comparison at all: one that lost
      # at a step is a valid route that another path beat, where one
      # Decision::INELIGIBLE named was set aside before any comparison
      # (RFC 4271 section 9.1.2).
      def usable?(lost_at)
        !Decision::INELIGIBLE.include?(lost_at)
      end

      private

      def summary
        { :peers      => bgp_peers.size,
          :rib        => @table.loc_rib.size,
          :paths      => @table.loc_rib.prefixes.sum { |p| @table.candidates(p).size },
          :originated => @table.originated.size }
      end

      # The peers, by address, **without ourselves**. Table#peers answers
      # the Adj-RIB-Ins it holds, and Table#originate puts our own routes
      # in one keyed by LocalPeer, so we are in that list. A peer here
      # means a BGP peer, the thing docs/daemon.md gives a session state
      # and a capability list, and we have no session with ourselves. What
      # we originate is in summary, as originated.
      #
      # A peer we only send to has no Adj-RIB-In and so is not in
      # Table#peers at all, which is why the Router's peers are added:
      # without them a session that has sent us nothing would be missing
      # from a console's peer list.
      def bgp_peers
        router = @table.router
        both = @table.peers + (router ? router.peers : [])
        both.uniq.reject(&:local?).sort_by { |p| address_key(p.address) }
      end

      # One row per peer. received is its Adj-RIB-In and best is how many
      # of the Loc-RIB's routes came from it.
      #
      # sent is the Adj-RIB-Out, which belongs to a Router and not to a
      # Table, so the key is there in router mode and absent otherwise
      # rather than present and wrong.
      #
      # Every size is read without asking for a RIB that does not exist
      # yet, because Table#adj_rib_in and Router#adj_rib_out each create
      # one on first use and a read must not change what it reads.
      #
      # The best routes are tallied in one pass over the Loc-RIB rather
      # than counted per peer, because a full table is about a million
      # prefixes and counting per peer would walk it once for each of
      # them.
      def peer_rows
        best = Hash.new(0)
        @table.loc_rib.routes.each { |r| best[r.peer] += 1 }
        in_peers = @table.peers
        router = @table.router
        out_peers = router ? router.peers : []
        bgp_peers.map do |p|
          row = { :address   => p.address,
                  :remote_as => p.remote_as,
                  :router_id => p.router_id,
                  :type      => p.ebgp? ? :ebgp : :ibgp,
                  :received  => in_peers.include?(p) ? @table.adj_rib_in(p).size : 0,
                  :best      => best[p] }
          next row unless out_peers.include?(p)
          row.merge(:sent => router.adj_rib_out(p).size)
        end
      end

      # The value keys of one path, shared by both views.
      def fields(route)
        { :from       => route.peer.address,
          :next_hop   => route.next_hop,
          :as_path    => as_path(route),
          :origin     => ORIGINS[route.origin],
          :local_pref => route.local_pref,
          :med        => route.med,
          :path_id    => route.path_id,
          :local      => route.local? }
      end

      # One path in the rib view. lost_at is nil for the best one, and
      # step is the whole prefix's decision.
      def path(route, lost_at, step)
        fields(route).merge(:best   => lost_at.nil?,
                            :usable => usable?(lost_at),
                            :lost_at => lost_at,
                            :reason => reason(lost_at, step))
      end

      # Route#as_path answers the word "empty" when there is no AS_PATH,
      # which is a thing to print and not a value, so an empty path is an
      # empty String here. A route with no AS_PATH attribute at all and one
      # with an empty one are the same answer, as they are in Route.
      def as_path(route)
        path = route.as_path
        path == 'empty' ? '' : path
      end

      # Words for a person: why this path lost, or why the best one won.
      # A step with no entry in LOST_WORDS still answers its own name, so
      # a step added to Decision::STEPS reads as itself rather than as
      # nothing; view_test fails until it has words of its own.
      def reason(lost_at, step)
        return LOST_WORDS[lost_at] || lost_at.to_s if lost_at
        return nil unless step
        WON_WORDS[step] || "best path, decided at the #{step} step"
      end

      def each_prefix(prefix)
        return prefixes unless prefix
        p = Route.normalize(prefix)
        @table.loc_rib.prefixes.include?(p) ? [p] : []
      end

      def prefix_key(prefix)
        ip = IPAddr.new(prefix)
        [ip.family, ip.to_i, ip.prefix]
      end

      # IPv4 sorts before IPv6, as it does in Decision's peer address tie
      # break.
      def address_key(address)
        ip = IPAddr.new(address)
        [ip.ipv4? ? 4 : 6, ip.to_i]
      end
    end

  end
end
