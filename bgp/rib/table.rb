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

require 'bgp/rib/adj_rib_in'
require 'bgp/rib/loc_rib'
require 'bgp/rib/peer_feed'
require 'bgp/rib/router'
require 'bgp/rib/show'

module BGP
  module Rib

    # The routing information bases of one BGP speaker, tied together:
    # an Adj-RIB-In per peer, import, the decision process and the Loc-RIB.
    #
    #   rib = BGP::Rib.new(local_as: 65001, router_id: '1.1.1.1')
    #   rib.on_change { |c| puts "#{c.type} #{c.prefix}" }
    #   rib.announce(route)
    #   rib.withdraw(peer, '192.168.1.0/24')
    #   rib.peer_down(peer)
    #
    # Every change returns the Loc-RIB changes it caused, and also hands them
    # to the on_change blocks. Only the prefixes a change touches are decided
    # again.
    #
    # A Table is thread safe: every method here takes one lock, so several
    # sessions can feed it while a console thread reads it. Three things
    # follow from that, and they are the whole of what a caller must know.
    #
    # The on_change blocks run on the thread that made the change, while the
    # lock is held, so the changes a listener sees are in the order they
    # happened. A listener may call back into the table, because the lock is
    # reentrant for the thread that holds it. A listener that blocks holds
    # every other thread up, so do the work elsewhere: put the change on a
    # Queue and let another thread have it.
    #
    # The decision and loc_rib readers, and the AdjRibIn that adj_rib_in
    # returns, are the objects themselves and have no lock of their own.
    # Reading one while another thread is feeding the table can read a half
    # finished change, and writing to one goes behind the table's back.
    # Hold the lock for those:
    #
    #   rib.synchronize { rib.loc_rib.each { |prefix, r| puts "#{prefix} #{r}" } }
    #
    # The methods on Table need no such care: best, result, candidates and
    # peers each take the lock themselves and copy what they return.
    class Table
      attr_reader :decision, :loc_rib

      # import: a block that takes a Route and returns the Route to use, a
      #   changed copy, or nil to reject it. It runs after the built in rules.
      # Other options go to Decision.new: resolver, default_local_pref,
      #   always_compare_med, missing_med_worst, cluster_id.
      def initialize(local_as:, router_id:, import: nil, **decision_options)
        @decision = Decision.new(local_as: local_as, router_id: router_id, **decision_options)
        @loc_rib = LocRib.new(@decision)
        @import = import
        @adj_in = {}     # peer => AdjRibIn
        @imported = {}   # prefix => { [peer, path_id] => imported route }
        @listeners = []
        @lock = Mutex.new
      end

      def local_as ; @decision.local_as ; end
      def router_id ; @decision.router_id ; end

      # Runs the block holding the table's lock, so a read of several things
      # sees one state, and nothing else changes the table meanwhile. It
      # nests: a block that calls a Table method, or synchronize again, does
      # not deadlock.
      def synchronize(&block)
        sync(&block)
      end

      def on_change(&block)
        sync { @listeners << block }
        self
      end

      # The Adj-RIB-In of peer, created on first use.
      def adj_rib_in(peer)
        sync { @adj_in[peer] ||= AdjRibIn.new(peer) }
      end

      def peers ; sync { @adj_in.keys } ; end

      # Stores route in its peer's Adj-RIB-In, imports it, and decides its
      # prefix again. Returns the Loc-RIB changes, an empty Array or one.
      def announce(route)
        sync do
          adj_rib_in(route.peer).announce(route)
          set_imported(route.prefix, route.peer, route.path_id, import(route))
          decide(route.prefix)
        end
      end

      # Removes a route peer sent. Returns the Loc-RIB changes.
      def withdraw(peer, prefix, path_id=nil)
        sync do
          old = adj_rib_in(peer).withdraw(prefix, path_id)
          next [] unless old
          set_imported(old.prefix, peer, old.path_id, nil)
          decide(old.prefix)
        end
      end

      # Removes every route from peer, as when its session goes down. RFC
      # 4271 section 6: closing a connection means "the associated
      # Adj-RIB-In has been cleared", then "Entries in the Loc-RIB
      # associated with the remote peer are marked as invalid" and "The
      # local system recalculates its best routes for the destinations of
      # the routes marked as invalid". Returning the changes is the rest of
      # that sentence: the speaker advertises "either withdraws for the
      # routes marked as invalid, or the new best routes", which is what
      # Router#run_changes does with them. Returns the Loc-RIB changes.
      def peer_down(peer)
        sync do
          ribin = @adj_in[peer]
          next [] unless ribin
          removed = ribin.flush
          removed.each { |r| set_imported(r.prefix, peer, r.path_id, nil) }
          removed.map(&:prefix).uniq.flat_map { |prefix| decide(prefix) }
        end
      end

      # Runs import and the decision again for every route, for example
      # after the import block or the resolver changed what it returns.
      def refresh
        sync do
          @imported.clear
          @adj_in.each_value do |ribin|
            ribin.each { |r| set_imported(r.prefix, r.peer, r.path_id, import(r)) }
          end
          (@loc_rib.prefixes | @imported.keys).flat_map { |prefix| decide(prefix) }
        end
      end

      # The imported routes to prefix that the decision chooses from.
      def candidates(prefix)
        sync { (@imported[Route.normalize(prefix)] || {}).values }
      end

      def best(prefix) ; sync { @loc_rib.best(prefix) } ; end
      def result(prefix) ; sync { @loc_rib.result(prefix) } ; end

      # Feeding from live sessions. The PeerFeed holds one worker thread and
      # is built on the first attach, so a table nobody attached to costs no
      # thread. See PeerFeed and PeerAdapter.
      #
      #   rib.attach(neighbor)
      #   neighbor.start
      #   rib.drain
      #   rib.best('10.0.0.0/8')
      def attach(neighbor) ; feed.attach(neighbor) ; end

      # Stops feeding from neighbor and removes the routes it sent.
      def detach(neighbor) ; feed.detach(neighbor) ; end

      # Waits for what the sessions have already sent to reach the table,
      # since the worker runs behind them. True, or false on timeout.
      def drain(timeout = PeerFeed::DEFAULT_TIMEOUT)
        @feed ? @feed.drain(timeout) : true
      end

      def feed ; sync { @feed ||= PeerFeed.new(self) } ; end

      # Us, as the source of the routes we originate. One object, so every
      # originated route shares a peer and withdraw(local_peer, prefix)
      # takes one back.
      def local_peer
        sync { @local_peer ||= LocalPeer.new(:local_as => local_as, :router_id => router_id) }
      end

      # Announces a prefix of our own. Returns the Loc-RIB changes, as
      # announce does, and withdraw(local_peer, prefix) removes it.
      #
      #   rib.originate('10.0.0.0/8')
      #   rib.originate('10.1.0.0/16', :origin => 2)
      #   rib.withdraw(rib.local_peer, '10.0.0.0/8')
      #
      # The attributes it builds are the ones RFC 4271 asks an originating
      # speaker for, and the AS_PATH is the interesting one. Section 5.1.2
      # wants an **empty** AS_PATH toward an internal peer, "one whose
      # length field contains the value zero", and toward an external peer
      # our own AS as "the only entry the path segment, and this path
      # segment will be the only segment". Both fall out of starting empty:
      # the export step leaves an internal peer's AS_PATH alone, and
      # prepending our AS onto an empty one gives exactly one segment with
      # exactly one AS in it.
      #
      # NEXT_HOP is a placeholder here, because the export step replaces it
      # with our address on each session (section 5.1.3). It is set at all
      # because NEXT_HOP is well known mandatory.
      #
      # origin: section 5.1.1 says "The ORIGIN attribute is generated by the
      # speaker that originates the associated routing information" and does
      # not say which value, so this is the caller's. 0 is IGP.
      #
      # path_attribute: used as it stands instead, for a script that wants
      # communities or a MED on what it originates. Nothing is added to it.
      def originate(prefix, origin: 0, path_attribute: nil, path_id: nil)
        pa = path_attribute || Path_attribute.new(Origin.new(origin), As_path.new,
                                                  Next_hop.new(router_id))
        announce(Route.new(prefix, pa, local_peer, :path_id => path_id))
      end

      # The Loc-RIB written out the way a router prints it. See Show: the
      # output is in the style of those commands and not a copy of them.
      #
      #   puts rib.show                        # IOS, show ip bgp
      #   puts rib.show(:junos)                # Junos, show route detail
      #   puts rib.show(:junos, '10.0.0.0/8')  # one prefix, and why paths lost
      #   puts rib.show(:iosxr)                # IOS-XR, show bgp
      #   puts rib.show(:iosxr, '10.0.0.0/8')  # one prefix, the detail form
      def show(style = :ios, prefix = nil)
        Show.new(self, :style => style).to_s(prefix)
      end

      # Every prefix we originated, as the Loc-RIB knows them.
      def originated
        sync { @loc_rib.routes.select { |r| r.local? }.map(&:prefix) }
      end

      # Router mode: advertise the Loc-RIB to the peers this table is
      # attached to. Off until asked for, because a table that only listens
      # is the normal use and a router is the other one.
      #
      #   rib.attach(neighbor)   # receive from it
      #   rib.advertise          # and advertise to it
      #
      # Options go to Router.new: export, next_hops. Returns the Router,
      # the same one on a second call.
      def advertise(**options)
        r = sync { @router ||= Router.new(self, feed, **options) }
        r.start
      end

      # The Router, or nil when router mode was never turned on.
      def router ; sync { @router } ; end

      # Put the Loc-RIB in a forwarding table and keep it there. Off until
      # asked for, like router mode, and for the same reason: a table that
      # only decides is the normal use.
      #
      #   rib.install(table: 100)                  # the local routing table
      #   rib.install(table: 100, netns: 'lab')    # one in a namespace
      #   rib.fib                                  # what it believes is in
      #   rib.uninstall                            # and take it out again
      #
      # table: is required and has no default, because a route in the main
      # routing table changes where this machine sends its own traffic.
      # Options go to Fib::IpRoute: proto, netns, dev, bin, runner. Pass
      # backend: instead to install somewhere that is not an iproute2
      # table at all. Returns the FibInstaller, the same one on a second
      # call.
      def install(backend: nil, **options)
        i = sync do
          @fib_installer ||=
            FibInstaller.new(self, feed,
                             :backend => backend || Fib::IpRoute.new(**options))
        end
        i.start
      end

      # The FibInstaller, or nil when nothing was installed.
      def fib_installer ; sync { @fib_installer } ; end

      # What the forwarding table is believed to hold, or nil when nothing
      # was installed.
      def fib ; sync { @fib_installer&.fib } ; end

      # Takes this table's routes back out of the forwarding table. Returns
      # the results of the commands, or nil when nothing was installed.
      def uninstall(timeout = PeerFeed::DEFAULT_TIMEOUT)
        i = sync { @fib_installer }
        i&.stop(timeout)
      end

      private

      # The table's lock, reentrant for the thread that holds it.
      #
      # Mutex is not reentrant, and a plain synchronize here deadlocks at
      # once: announce calls adj_rib_in, which takes the lock again on the
      # same thread. The listeners need it too, since decide runs them while
      # the lock is held and a listener may read or change the table.
      #
      # Mutex#owned? is core Ruby, so this needs no require. The monitor
      # library would do the same thing, but it is one more standard library
      # that could become a bundled gem, which is the trade this file's
      # neighbours make too (see Conventions in CLAUDE.md).
      def sync
        return yield if @lock.owned?
        @lock.synchronize { yield }
      end

      # RFC 4271 section 5.1.5: LOCAL_PREF received from an eBGP peer must be
      # ignored. Then the import block, if any.
      def import(route)
        if route.peer.ebgp? && route.path_attribute.has?(Local_pref)
          pa = Path_attribute.new(route.path_attribute.encode(true), true)
          pa.delete(Local_pref)
          route = route.with_path_attribute(pa)
        end
        @import ? @import.call(route) : route
      end

      def set_imported(prefix, peer, path_id, route)
        paths = (@imported[prefix] ||= {})
        if route
          paths[[peer, path_id]] = route
        else
          paths.delete([peer, path_id])
          @imported.delete(prefix) if paths.empty?
        end
      end

      def decide(prefix)
        change = @loc_rib.update(prefix, candidates(prefix))
        return [] unless change
        @listeners.each { |l| l.call(change) }
        [change]
      end
    end

    # Shortcut for Table.new.
    def self.new(**options)
      Table.new(**options)
    end

  end
end
