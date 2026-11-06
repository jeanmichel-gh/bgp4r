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

require 'bgp/daemon/speaker'
require 'bgp/daemon/log_ring'

module BGP
  module Daemon

    # What `bgp4rd` answers, as plain data with Symbol keys, ready for
    # JSON. One method per `show.` method of docs/daemon.md's control API.
    #
    # **It merges two halves and that split is the whole of this file.**
    # `bgp/rib/view.rb` answers everything a Rib::Table knows: the
    # Loc-RIB, the candidate paths and the decision, and the four peer
    # keys a Table has. Everything else about a peer is a **session**
    # fact, which a Table has none of: its state, its uptime, its flap
    # count, its last error, its negotiated capabilities and what the
    # node file calls it. Those come from the Speaker's own Peers. The
    # view's keys are docs/daemon.md's keys, so nothing is renamed on the
    # way through.
    #
    # Two consequences a reader will meet:
    #
    # * **The peer list is configuration driven here and table driven
    #   there.** A neighbor configured but never up has no Adj-RIB-In and
    #   no Adj-RIB-Out, so `rib.view` does not list it at all, while a
    #   daemon must list every neighbor it is configured to have or its
    #   peer table hides the ones that are down, which are the
    #   interesting ones. So this walks `speaker.peers` and merges the
    #   view's row where there is one.
    # * **`summary.peers` is the configured count** for the same reason,
    #   where the view's is the number of peers the table has seen.
    #
    # Nothing here validates and nothing here decides: every number is
    # read from the Table under its own lock or from a Recorder under
    # its own.
    class Views

      # One page of an unbounded view, and the cap on one.
      #
      # **`show.routes` and `show.rib` are paged and `show.peers` is
      # not**, which is a scale decision rather than a style: a full
      # table is about a million prefixes and the recorded requirement
      # is that no endpoint builds a million element array, while a peer
      # list is bounded by the configuration file and is tens of rows.
      # docs/daemon.md has the envelope.
      PAGE_LIMIT = 500
      MAX_LIMIT  = 10_000

      attr_reader :speaker, :log_ring

      # :log is the LogRing `show.log` answers from, which only the
      # program that set up logging can have: see `Server#setup_log`.
      # With none, `show.log` answers no lines and says it keeps none.
      def initialize(speaker, arg = {})
        @speaker  = speaker
        @log_ring = arg[:log]
      end

      # The router, its peers and a summary, which is the shape
      # routescope's `#bgp(container)` wants.
      def status
        # One read of the table's status, shared with the peer rows, so
        # the summary and the rows under it are the same snapshot.
        base = rib_view && rib_view.status
        rows = peer_rows(base)
        { :router_id => @speaker.router_id,
          :as        => @speaker.my_as,
          :route_reflector => !reflector.nil?,
          :cluster_id      => reflector && reflector.cluster_id,
          :uptime    => uptime(@speaker.started_at),
          :peers     => rows,
          :summary   => ((base && base[:summary]) || {}).merge(
                          :peers       => rows.size,
                          :established => rows.count { |r| r[:state] == 'established' }) }
      end

      # One row per configured neighbor: the session half from the
      # Speaker, the table half from `rib.view`.
      def peers
        peer_rows(rib_view && rib_view.status)
      end

      # The Loc-RIB, one row per prefix, its best path. One page of it;
      # see PAGE_LIMIT.
      def routes(params = {})
        page(params) { |prefix| rib_view.routes(prefix) }
      end

      # Every candidate path per prefix, with the decision. One page of
      # it; see PAGE_LIMIT.
      def rib(params = {})
        page(params) { |prefix| rib_view.rib(prefix) }
      end

      # One peer's Adj-RIB-In, as received, one page of it.
      #
      # **A `peer` parameter is required and an unknown one is refused by
      # name.** A per peer view with no peer has no sensible default: the
      # first configured neighbor would be an answer about a peer nobody
      # asked about, and every peer at once is the thing the page
      # envelope exists to prevent.
      def adj_in(params = {})
        address = peer_param(params)
        keyed(params, -> { rib_view.adj_in_prefixes(address) }) do |prefix|
          rib_view.adj_in(address, prefix)
        end
      end

      # What was advertised to one peer, one page of it, and what was not
      # advertised to it and why.
      #
      # **`skipped` rides beside the page rather than in it**, because it
      # is not keyed by the prefixes this page walks: a prefix that was
      # skipped is by definition not in the Adj-RIB-Out. It carries its
      # own total and is capped at the same limit, so a caller can see
      # there is more than it got. `Router#skipped` builds its whole list
      # either way, which is the library's own shape and is bounded by
      # the number of refusals rather than by the table.
      #
      # **`hand` rides beside it the same way and only when there is
      # something in it**: the prefixes sent to this peer by hand, whose
      # state at the peer the daemon does not know, with the verb and the
      # time. The rows above it are never patched for those; see
      # bgp/daemon/hand.rb.
      def adj_out(params = {})
        address = peer_param(params)
        snapshot do
          page = keyed(params, -> { rib_view.adj_out_prefixes(address) }) do |prefix|
            rib_view.adj_out(address, prefix)
          end
          skipped = rib_view ? rib_view.skipped(address) : []
          page = page.merge(:skipped => { :total => skipped.size,
                                          :rows => skipped.first(page[:limit]) })
          hand = @speaker.hand.rows(address)
          next page if hand.empty?
          page.merge(:hand => { :total => hand.size, :rows => hand.first(page[:limit]) })
        end
      end

      # What the daemon believes is in the kernel table, one page of it,
      # and what the kernel refused.
      #
      # **Believed and not read back.** `Fib` records what a command that
      # exited 0 did, so these rows are bgp4r's own account; `ip route
      # show` is the other question and a person asks it with `ip`.
      #
      # The facts that are not per prefix ride beside the page under
      # `fib`, for the reason `adj_out`'s `skipped` does, and `fib
      # .configured` is what tells a daemon with no `fib:` in its
      # configuration from one whose table happens to be empty: both
      # answer no rows.
      def fib(params = {})
        snapshot do
          page = keyed(params, -> { rib_view.fib_prefixes }) { |prefix| rib_view.fib_routes(prefix) }
          page.merge(:fib => rib_view ? rib_view.fib : no_fib)
        end
      end

      # The last lines this daemon logged, oldest first.
      #
      # `count` is how many, clamped. `kept` is how many the ring holds
      # and `keeps` its capacity, so a reader can tell the whole log from
      # the tail of one; `keeps` 0 says nothing is kept at all, which is a
      # Views built without one rather than a daemon with an empty log.
      #
      # **Text and not structure, which is where this parts company with
      # ospfv2's `show.log`**: see `bgp/daemon/log_ring.rb`, which has the
      # decision and the three things it rejected. A program wanting
      # structure reads `events.subscribe`.
      def log(params = {})
        count = integer(params, 'count', 100)
        ring  = @log_ring
        { :lines => ring ? ring.lines(count) : [],
          :kept  => ring ? ring.size : 0,
          :keeps => ring ? ring.keeps : 0 }
      end

      # The Loc-RIB the way a router prints it, through
      # `bgp/rib/show.rb`'s three styles, as one String.
      #
      # **The only method here that answers text, and the only reason it
      # does is that `Show` takes a Rib::Table.** `bgp/rib/view.rb`
      # exists so that nothing outside has to parse those styles, and
      # this does not change that: a driver reads `show.routes` and
      # `show.rib`, and this is for a person at `bgp4r-cli -c 'show
      # bgp'`. The three styles are **in the style of** those commands
      # and not copies, so no test may depend on this text byte for
      # byte.
      #
      # It is **not paged**, which is honest rather than tidy: a
      # vendor's `show bgp` prints the table and this prints the table.
      # A million prefixes of it is a million prefixes of it, which is
      # what `| head` is for, and a paged vendor style would be a
      # format no router has.
      # **It checks no style of its own, and the first draft did.** A
      # guard here against `Rib::Show::STYLES` passed every sabotage,
      # because `Show.new` already refuses an unknown style and names
      # the ones there are: the guard was a second statement of a check
      # the library makes, which is the shape #223 found as a constant
      # nothing read. One place refuses a style and it is `Show`.
      def text(params = {})
        return '' unless @speaker.rib
        style = (params['style'] || params[:style] || 'ios').to_s
        prefix = params['prefix'] || params[:prefix]
        @speaker.rib.show(style.to_sym, prefix)
      end

      private

      # The configured peers, each with the table's row merged on where
      # there is one.
      #
      # **A peer the table has never seen still answers `received`,
      # `sent` and `best`, as 0**, and that is the key rule
      # bgp/rib/view.rb states rather than a convenience: a key present
      # with a value is an answer, and a peer with no session holds no
      # routes, which is a known answer and not a missing one. Leaving
      # the keys out would make routescope's `bgp_peers` row, which is
      # `address remote_as state description uptime received sent`, show
      # blanks for the peers that are down, which are the interesting
      # ones. `sent` appears only in router mode, where `rib.view` puts
      # it, because a speaker that advertises nothing has no Adj-RIB-Out
      # to count.
      def peer_rows(table_status)
        from_table = ((table_status && table_status[:peers]) || []).to_h { |r| [r[:address], r] }
        @speaker.peers.map do |peer|
          defaults = { :received => 0, :best => 0 }
          defaults[:sent] = 0 if @speaker.router
          row = defaults.merge(from_table[peer.address] || {}).merge(session_row(peer))
          # How many prefixes were sent to this peer by hand, present only
          # when there are some, so a row reads as it always has until
          # something is. See bgp/daemon/hand.rb.
          hand = @speaker.hand.count(peer.address)
          row = row.merge(:hand => hand) unless hand.zero?
          # Whether this peer is a client of ours, RFC 4456 section 6,
          # present only on a reflector, as `hand` is present only when
          # there is some: a row on a speaker that reflects nothing reads
          # as it always has.
          reflector ? row.merge(:route_reflector_client => client?(peer)) : row
        end
      end

      # The export rules when this speaker reflects, or nil.
      def reflector
        e = @speaker.router && @speaker.router.export
        e && e.route_reflector? ? e : nil
      end

      # Export#client? asks a Rib::Peer, and reads only its address and
      # whether it is internal, so the router ID here is a placeholder
      # nothing reads: the peer's own may not have arrived yet.
      def client?(peer)
        reflector.client?(BGP::Rib::Peer.new(address: peer.address, remote_as: peer.remote_as,
                                             router_id: '0.0.0.0', local_as: @speaker.my_as))
      end

      def rib_view
        rib = @speaker.rib
        rib && rib.view
      end

      # A page of a per prefix view.
      #
      # `prefix` answers that one prefix and ignores `offset`, because a
      # caller naming a prefix is asking a question with one answer.
      #
      # **The whole page is built inside one `Table#synchronize`**, which
      # is what makes it a coherent snapshot rather than N reads of a RIB
      # that may be deciding in between. The lock is reentrant, so the
      # view's own `synchronize` nests inside it. What is still
      # materialised is the sorted prefix list, because that is where
      # `View#prefixes` sorts; the rows, which are the expensive part,
      # are built for one page only.
      def page(params, &block)
        keyed(params, -> { rib_view.prefixes }, &block)
      end

      # A page of a view keyed by prefix, given the sorted key list and a
      # block that builds one key's rows.
      #
      # **One envelope builder and one window, read by every paged view**,
      # which is why `page` is three lines: `show.routes` and `show.rib`
      # walk the Loc-RIB's prefixes, `show.adj_in` and `show.adj_out` one
      # peer's, and `show.fib` the installed ones, and all five answer the
      # same shape because they come through here. A second envelope would
      # be a second set of rules about what `next_offset` nil means.
      def keyed(params, keys_fn)
        return empty_page(params) unless rib_view
        prefix = params['prefix'] || params[:prefix]
        offset, limit = window(params)
        snapshot do
          keys = keys_fn.call
          if prefix
            rows = yield(prefix)
            envelope(rows, rows.size, 0, limit)
          else
            rows = keys[offset, limit].to_a.flat_map { |p| yield(p) }
            nxt = offset + limit
            envelope(rows, keys.size, offset, limit, nxt < keys.size ? nxt : nil)
          end
        end
      end

      # The page envelope, and the one place it is built.
      #
      # **`next_offset` nil is what says the walk is over**, which is why
      # the envelope exists at all: a caller handed a short list cannot
      # tell the end of the table from a truncated answer, and `total`
      # beside it says which. One builder, so a view added later cannot
      # answer a page that means something slightly different.
      def envelope(rows, total, offset, limit, next_offset = nil)
        { :rows => rows, :total => total, :offset => offset,
          :limit => limit, :next_offset => next_offset }
      end

      def empty_page(params)
        _offset, limit = window(params)
        envelope([], 0, 0, limit)
      end

      # Runs the block holding the table's lock, so everything in one
      # answer is one state rather than N reads of a RIB that may be
      # deciding in between. The lock is reentrant and public for exactly
      # this, so a view's own synchronize and a nested page both nest
      # inside it. With no table there is no lock and nothing to protect.
      def snapshot
        return yield unless @speaker.rib
        @speaker.rib.synchronize { yield }
      end

      # The `peer` parameter of a per peer view: an address this bgp4rd is
      # configured to have, or an ArgumentError naming the ones it has.
      # `Speaker#peer!` does the refusal, so one place names them and a
      # control method and a view answer the same message.
      def peer_param(params)
        address = params['peer'] || params[:peer]
        raise ArgumentError, 'peer is required: the address of one neighbor' if address.nil?
        @speaker.peer!(address).address
      end

      # What `show.fib` says when there is no table at all, so the answer
      # has the same keys either way.
      def no_fib
        { :configured => false, :backend => nil, :total => 0, :failed => [], :skipped => [] }
      end

      # `offset` and `limit` from a request, clamped. A limit of 0 or
      # less, or one above MAX_LIMIT, is the caller asking for something
      # this cannot answer, so it is clamped rather than refused: the
      # answer carries the limit it used, so a caller can see what it
      # got.
      def window(params)
        offset = integer(params, 'offset', 0)
        limit  = integer(params, 'limit', PAGE_LIMIT)
        [offset.negative? ? 0 : offset, limit.clamp(1, MAX_LIMIT)]
      end

      def integer(params, name, default)
        v = params[name]
        v = params[name.to_sym] if v.nil?
        return default if v.nil?
        Integer(v)
      rescue ArgumentError, TypeError
        # Both, because Integer('lots') raises ArgumentError and
        # Integer([]) raises TypeError, and the refusal has to name the
        # key either way: "invalid value for Integer()" says nothing
        # about which parameter the caller got wrong.
        raise ArgumentError, "#{name} must be an integer, got #{v.inspect}"
      end

      # The session half of a peer row.
      #
      # **The state is lowercased here and that is a contract rather than
      # a style.** routescope validates against a closed list,
      # `idle connect active opensent openconfirm established`, and drops
      # a value outside it, so a capitalised state shows as an empty peer
      # list and not as an error. Measured on 2026-11-02: the states
      # bgp4r's FSM actually reaches are `:Idle`, `:Active`, `:OpenSent`,
      # `:OpenConfirm` and `:Established`, and all five are in that list
      # once downcased. bgp4r never enters `:Connect`, going straight to
      # `:Active` when it opens the socket, and `:OpenRecv` appears in
      # Neighbor's `is_*?` helpers and is never set.
      #
      # **`capabilities` is the structured form and not a list of
      # names**, which departs from docs/daemon.md's example. A name like
      # `as4_byte` is what a script *asks* for, and
      # `Neighbor::CAPABILITIES` maps six such spellings onto `CAP::As4`
      # alone, so there is no reverse mapping to answer with. What is
      # here is the capability's class name and its own `to_hash`, which
      # is what the lab state file already carries and is strictly more
      # information than a name.
      def session_row(peer)
        d = peer.recorder.data
        { :address      => peer.address,
          :remote_as    => peer.remote_as,
          :router_id    => d['peer_router_id'],
          :description  => peer.description,
          :type         => peer.ebgp? ? :ebgp : :ibgp,
          :state        => peer.state.to_s.downcase,
          :uptime       => uptime(peer.recorder.established_at),
          :flaps        => peer.recorder.flaps,
          :inq          => inq(peer),
          :outq         => outq(peer),
          :held         => held(peer),
          :last_error   => d['last_error'],
          :updates      => d['updates_received'],
          :capabilities => d['peer_capabilities'] }
      end

      # What is left to do for one session, which is what a console
      # asks to say whether this speaker is done with its work (routescope's
      # `bgp_drained`). Three counts and not one, because they are three
      # different waits:
      #
      #   inq   received and not yet in the table: events the session has
      #         not dispatched, plus its UPDATEs the RIB worker has not
      #         applied
      #   outq  not yet on the wire: messages in the session's output
      #         queue, plus the RIB worker's items that send something,
      #         which belong to no one peer and so count against each
      #   held  routes the MinRouteAdvertisementInterval is holding back
      #         for this peer on purpose (RFC 4271 section 9.2.1.1). They
      #         still have to go, so a speaker holding one is not done
      #
      # nil is not reported: a session with no Neighbor yet has no queues,
      # and a speaker with no table has no worker and no router.
      def inq(peer)
        n = peer.neighbor
        return nil unless n
        feed = @speaker.rib && @speaker.rib.feed
        n.inq + (feed ? feed.unapplied(n) : 0)
      end

      def outq(peer)
        n = peer.neighbor
        return nil unless n
        feed = @speaker.rib && @speaker.rib.feed
        n.pending + (feed ? feed.unsent : 0)
      end

      def held(peer)
        r = @speaker.router
        return nil unless r
        r.waiting.count { |p, _| p.address == peer.address }
      end

      # Whole seconds since t, or nil when there is no t. nil means the
      # session is not up, which is the key rule bgp/rib/view.rb states:
      # a key present with nil is an answer and not a gap.
      def uptime(t)
        t && (Time.now - t).round
      end

    end

  end
end
