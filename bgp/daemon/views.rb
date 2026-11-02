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

      attr_reader :speaker

      def initialize(speaker)
        @speaker = speaker
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
          defaults.merge(from_table[peer.address] || {}).merge(session_row(peer))
        end
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
      def page(params)
        return empty_page(params) unless rib_view
        prefix = params['prefix'] || params[:prefix]
        offset, limit = window(params)
        @speaker.rib.synchronize do
          if prefix
            rows = yield(prefix)
            { :rows => rows, :total => rows.size, :offset => 0,
              :limit => limit, :next_offset => nil }
          else
            all = rib_view.prefixes
            rows = all[offset, limit].to_a.flat_map { |p| yield(p) }
            nxt = offset + limit
            { :rows => rows, :total => all.size, :offset => offset,
              :limit => limit, :next_offset => nxt < all.size ? nxt : nil }
          end
        end
      end

      def empty_page(params)
        _offset, limit = window(params)
        { :rows => [], :total => 0, :offset => 0, :limit => limit, :next_offset => nil }
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
          :last_error   => d['last_error'],
          :updates      => d['updates_received'],
          :capabilities => d['peer_capabilities'] }
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
