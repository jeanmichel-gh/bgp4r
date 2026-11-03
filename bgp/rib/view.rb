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
    #   view.adj_in('10.0.0.2')      # that peer's Adj-RIB-In, as received
    #   view.adj_out('10.0.0.2')     # what went to it, and skipped why
    #   view.fib                     # what the forwarding table is believed to hold
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

      # The views +json+ can serialise, which are docs/daemon.md's control
      # API names with the +show.+ dropped, for the three that take a
      # prefix and nothing else.
      #
      # +adj_in+, +adj_out+ and +fib+ are deliberately not in it. The
      # first two take a **peer address** where json's second argument is
      # a prefix, so adding them would mean a second meaning for one
      # argument, and whatever serves them has a JSON layer of its own:
      # the daemon pages them, which json does not do for any view.
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

      # One peer's Adj-RIB-In, as received, one row per path (RFC 4271
      # section 3.2). With a prefix, only that prefix's paths.
      #
      # **As received, which is what no other view here answers.** The
      # Adj-RIB-In holds what the peer sent before import policy, so a
      # LOCAL_PREF an external peer sent is still in these rows where
      # Table#import has already dropped it from everything downstream
      # (RFC 4271 section 5.1.5). That is the whole reason to read it: a
      # route the decision process never saw is otherwise invisible.
      #
      # A peer the table has never seen answers no rows. It must not
      # answer by creating one: Table#adj_rib_in makes an Adj-RIB-In on
      # first use, and a read that changes what it reads would put an
      # empty RIB against every address anybody asked about. So the
      # address is looked up in Table#peers first.
      def adj_in(address, prefix = nil)
        @table.synchronize do
          ribin = adj_rib_in(address)
          next [] unless ribin
          routes = prefix ? ribin.paths(Route.normalize(prefix)) : ribin.routes
          routes.sort_by { |r| [prefix_key(r.prefix), r.path_id || -1] }
                .map { |r| received(r) }
        end
      end

      # The prefixes in one peer's Adj-RIB-In, sorted as +prefixes+ sorts
      # the Loc-RIB's. It is the key list a caller pages with, the way
      # +prefixes+ is for +routes+: that is what keeps an Adj-RIB-In of a
      # million prefixes from being built into one answer, which is the
      # recorded requirement.
      def adj_in_prefixes(address)
        @table.synchronize do
          ribin = adj_rib_in(address)
          ribin ? ribin.prefixes.sort_by { |p| prefix_key(p) } : []
        end
      end

      # What was advertised to one peer, one row per prefix and Path
      # Identifier, and why anything was not.
      #
      # **These are the attributes that went out and not the Loc-RIB's**,
      # which is the point: the export rules of RFC 4271 section 5.1 and
      # RFC 4456 rewrite AS_PATH, NEXT_HOP, LOCAL_PREF and MED per peer,
      # so a row here says what the peer was really told. An AdjRibOut
      # holds a Path_attribute and not a Route, so the keys are the
      # attributes it carries and there is no :from and no :local.
      #
      # Empty with no Router, since an Adj-RIB-Out belongs to router mode
      # and a speaker that advertises nothing has none. Same first-use
      # rule as adj_in: the peer is looked up in Router#peers.
      def adj_out(address, prefix = nil)
        @table.synchronize do
          out = adj_rib_out(address)
          next [] unless out
          want = prefix && Route.normalize(prefix)
          rows = []
          out.each do |p, path_id, pa|
            next if want && p != want
            rows << { :prefix => p, :path_id => path_id }.merge(sent(pa))
          end
          rows.sort_by { |r| [prefix_key(r[:prefix]), r[:path_id] || -1] }
        end
      end

      # The prefixes in one peer's Adj-RIB-Out, sorted, for the same
      # reason +adj_in_prefixes+ exists.
      def adj_out_prefixes(address)
        @table.synchronize do
          out = adj_rib_out(address)
          out ? out.prefixes.sort_by { |p| prefix_key(p) } : []
        end
      end

      # Why a prefix was not advertised to one peer, as [prefix, reason]
      # rows, from Router#skipped. A route silently not advertised is the
      # hardest kind of bug to see from outside, which is why Router
      # keeps it at all.
      def skipped(address)
        router = @table.router
        return [] unless router
        router.skipped
              .select { |(_prefix, peer, _reason)| peer && peer.address == address }
              .map { |(prefix, _peer, reason)| { :prefix => prefix, :reason => reason && reason.to_s } }
      end

      # What the forwarding table is believed to hold, one row per prefix,
      # and what the kernel refused.
      #
      # **Believed, not read back**, and the word is the honest one: Fib
      # records what a command that exited 0 did, so these rows are
      # bgp4r's own account and not an answer from the kernel. Reading
      # the table back is `ip route show`, which is a different question
      # and one a person asks with `ip`.
      #
      # :configured says whether anything is installing at all, so a
      # daemon with no fib: in its configuration is distinguishable from
      # one whose table happens to be empty. Both answer no rows.
      def fib
        @table.synchronize do
          installer = @table.fib_installer
          f = @table.fib
          { :configured => !installer.nil?,
            :backend    => installer && installer.backend.to_s,
            :total      => f ? f.size : 0,
            :failed     => (installer ? installer.failed : {})
                             .map { |prefix, result| { :prefix => prefix, :error => result.to_s } },
            :skipped    => (f ? f.skipped : {})
                             .map { |prefix, reason| { :prefix => prefix, :reason => reason.to_s } } }
        end
      end

      # The prefixes the forwarding table is believed to hold, sorted, for
      # the same reason +adj_in_prefixes+ exists.
      def fib_prefixes
        @table.synchronize do
          f = @table.fib
          f ? f.prefixes.sort_by { |p| prefix_key(p) } : []
        end
      end

      # One row per installed prefix, or that one prefix's row. The next
      # hop is the one that went to the command, not one read back from
      # the kernel; see +fib+.
      def fib_routes(prefix = nil)
        @table.synchronize do
          f = @table.fib
          next [] unless f
          keys = prefix ? [Route.normalize(prefix)].select { |p| f.prefixes.include?(p) } : fib_prefixes
          keys.map { |p| { :prefix => p, :next_hop => f[p] } }
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

      # The Adj-RIB-In of the peer with this address, or nil when the
      # table has never seen one.
      #
      # **The address is looked up in Table#peers first and that is not
      # tidiness.** Table#adj_rib_in makes an Adj-RIB-In on first use, so
      # asking it directly would answer an empty RIB for every address
      # anybody named and leave one behind in the table: a read that
      # changes what it reads. Router#adj_rib_out has the same shape, and
      # so does the peer row count in peer_rows, which is why that one
      # tests membership too.
      def adj_rib_in(address)
        peer = @table.peers.find { |p| !p.local? && p.address == address }
        peer && @table.adj_rib_in(peer)
      end

      # The Adj-RIB-Out of the peer with this address, or nil with no
      # Router or no such peer. An Adj-RIB-Out belongs to router mode, so
      # a speaker that advertises nothing has none at all.
      def adj_rib_out(address)
        router = @table.router
        peer = router && router.peers.find { |p| !p.local? && p.address == address }
        peer && router.adj_rib_out(peer)
      end

      # One row of an Adj-RIB-In: the route as received, and whether it is
      # the one that won.
      #
      # best is answered by the peer and the Path Identifier and not by
      # object identity, because Table#import builds a changed copy of an
      # external peer's route when it drops LOCAL_PREF, so the Loc-RIB's
      # winner is not the same object as the one in the Adj-RIB-In. Those
      # two fields are the key an imported route is stored under, so they
      # name one path exactly.
      def received(route)
        best = @table.best(route.prefix)
        { :prefix => route.prefix }.merge(fields(route))
                                   .merge(:best => !best.nil? && best.peer == route.peer &&
                                                   best.path_id == route.path_id)
      end

      # The attributes one Adj-RIB-Out entry carries, read off the
      # Path_attribute that went out. No :from and no :local: an
      # Adj-RIB-Out holds attributes and not a Route, so there is nothing
      # to answer them with and a key with a made up value would be
      # worse than no key.
      def sent(pa)
        # As_path#as_path answers the word "empty" for a path with no
        # segments, which is a thing to print and not a value, so the
        # same rule as View#as_path applies: an empty path is an empty
        # String, and no AS_PATH attribute at all is the same answer.
        path = value(pa, As_path) { |a| a.as_path }
        { :next_hop   => value(pa, Next_hop) { |a| a.next_hop },
          :as_path    => (path.nil? || path == 'empty' ? '' : path),
          :origin     => ORIGINS[value(pa, Origin) { |a| a.to_i }],
          :local_pref => value(pa, Local_pref) { |a| a.to_i },
          :med        => value(pa, Multi_exit_disc) { |a| a.to_i } }.merge(communities(pa))
      end

      # The three community attributes of a path, each a list, empty when
      # the path carries none. **The same three keys on every row of every
      # view**, so a console reads one shape whichever view it asked.
      #
      #   :communities           RFC 1997, "ASN:VALUE" in decimal, a
      #                          well-known one too: NO_EXPORT is
      #                          "65535:65281" and not a name, since a
      #                          name is a vendor's choice and the numbers
      #                          are the attribute
      #   :extended_communities  RFC 4360 and its successors, each its own
      #                          to_hash entry: {:route_target=>[65000, 7]}.
      #                          Data rather than text because the eight
      #                          octets have a layout per type and a string
      #                          would have to be parsed back into it
      #   :large_communities     RFC 8092, "GLOBAL:DATA1:DATA2"
      #
      # Until 2026-11-03 only adj_out answered communities, and as the one
      # String the attribute prints, "65000:1 65000:2". A list is what the
      # other two have to be, so the first is one too.
      def communities(pa)
        { :communities => value(pa, Communities) { |a| a.communities.split } || [],
          :extended_communities => value(pa, Extended_communities) { |a| a.to_hash[:extended_communities] } || [],
          :large_communities => value(pa, Large_communities) { |a| a.communities.collect { |c| c.to_s } } || [] }
      end

      # One attribute of a Path_attribute, or nil when it carries none.
      # Route#attr does the same thing for a Route; this is the same rule
      # one layer down, for an Adj-RIB-Out entry that has no Route.
      def value(pa, klass)
        return nil unless pa && pa.has?(klass)
        yield pa[klass]
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
          :local      => route.local? }.merge(communities(route.path_attribute))
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
