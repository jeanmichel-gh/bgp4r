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

require 'json'
require 'bgp/prompt'
require 'bgp/daemon/speaker'
require 'bgp/daemon/community_keys'

module BGP
  module Daemon

    # The irb prompt of `bgp4rd --interact`:
    #
    #   bgp4rd -f rtr.yml --interact
    #
    #   rtr> peers
    #   rtr> why '10.10.0.0/24'
    #   rtr> originate '10.255.1.0/24', communities: ['65000:100']
    #
    # **Every verb is a control socket method**, called through
    # `Api#handle`, which is the one entry point the socket uses. So the
    # prompt and `bgp4r-cli` cannot disagree: same method, same refusals,
    # same answer. The answer goes through a JSON round trip first, so a
    # verb that returns data returns what the socket would have sent,
    # String keys and all. `api` reaches any method by name.
    #
    # **No verb sends octets around the records.** A daemon keeps a
    # Loc-RIB and an Adj-RIB-Out per peer, and a message put on the wire
    # behind their back would make its own answers wrong. Sending by hand
    # on a daemon is the next step, with a list of what was sent beside
    # the Adj-RIB-Out; docs/console.md section 10 has it.
    #
    # `received`, `last`, `watch`, `guide` and `verbs` come from
    # `BGP::Prompt`, which is why this file does not load the injector.
    class Console
      include BGP
      include BGP::Prompt

      # RFC 4486 section 4: the Cease subcodes a router sends for
      # `neighbor shutdown` and for `clear bgp`.
      CEASE = 6
      ADMIN_SHUTDOWN = 2
      ADMIN_RESET = 4

      VERBS = <<~TEXT
        Reading
          peers                         every configured peer and its state
          rib [STYLE [, PFX]]           show bgp, in ios, junos or iosxr style
          why PFX                       each path to one prefix, and why it won
                                        or lost
          adj_in PEER [, PFX]           what PEER sent us, as received
          adj_out PEER [, PFX]          what we sent PEER, and what we did not
          fib                           what the forwarding table is believed
                                        to hold
        Acting
          originate PFX..., med: 10     route.originate. Also origin, as_path,
                                        local_pref, communities,
                                        extended_communities, large_communities,
                                        path_id. The mark key is added
          announce PFX...               originate under another name
          withdraw PFX...               route.withdraw
          clear [PEER]                  Cease 6/4, reset, and it comes back
          shutdown [PEER]               Cease 6/2, down, and it stays down
          no_shutdown [PEER]            let it come back up
          refresh [PEER], afi: 1, safi: 1, subtype: nil
                                        a ROUTE-REFRESH
          api 'METHOD', {...}           any control socket method by name
        Watching
          received [N]                  the last N messages in
          last                          the last message in, as an object
          watch / quiet                 print messages as they arrive, or not
          state [PEER]                  one peer's FSM state
          n, neighbor [PEER]            the BGP::Neighbor, the whole API
        Help
          verbs                         this list
          guide [N or WORD]             docs/console.md, or one section of it
        exit sends Cease 6/2 to each peer and stops bgp4rd.
      TEXT

      attr_reader :api_server

      # api is the daemon's running `Api`, which holds its Views and so
      # its Speaker.
      def initialize(api, out = $stdout, keep = KEEP)
        initialize_prompt(out, keep)
        @api_server = api
        speaker.on_established { |peer| tap(peer) }
        speaker.established_peers.each { |peer| tap(peer) }
      end

      def speaker ; @api_server.views.speaker ; end

      def banner
        "bgp4rd console: self is the daemon. 'verbs' lists what to type, " \
        'exit stops the daemon.'
      end

      def to_s ; 'bgp4rd' ; end
      def inspect ; "#<BGP::Daemon::Console #{speaker.peers.size} peer(s)>" ; end

      # Any control socket method by name, with the params the socket
      # takes, answered as the socket would answer it. A refusal raises
      # ArgumentError with the daemon's own message.
      def api(method, params = {})
        r = @api_server.handle('method' => method.to_s, 'params' => stringify(params))
        raise ArgumentError, r[:error] if r.key?(:error)
        JSON.parse(JSON.generate(r[:result]))
      end

      # ---- reading -------------------------------------------------------

      PEER_HEADING = format('%-15s %-7s %-12s %-9s %5s %5s %5s',
                            'peer', 'as', 'state', 'uptime', 'rcvd', 'sent', 'best')

      def peers
        rows = api('show.peers')
        @out.puts PEER_HEADING
        rows.each do |r|
          @out.puts format('%-15s %-7s %-12s %-9s %5s %5s %5s',
                           r['address'], r['remote_as'], r['state'], clock(r['uptime']),
                           r['received'], r['sent'] || '-', r['best'])
        end
        nil
      end

      # `show bgp` in one of bgp/rib/show.rb's three styles, which are in
      # the style of those commands and not copies.
      def rib(style = :ios, prefix = nil)
        params = { 'style' => style.to_s }
        params['prefix'] = prefix if prefix
        @out.print api('show.text', params)
        nil
      end

      # Every path to one prefix, the one that won and each one that
      # lost, with `show.rib`'s own words.
      def why(prefix)
        rows = api('show.rib', 'prefix' => prefix.to_s)['rows']
        if rows.empty?
          @out.puts "#{prefix} is not in the Loc-RIB"
          return nil
        end
        rows.each do |r|
          paths = r['paths']
          @out.puts "#{r['prefix']}, #{paths.size} path#{paths.size == 1 ? '' : 's'}, " \
                    "decided at the #{r['decided_by'] || 'only path'} step"
          width = paths.collect { |p| p['as_path'].to_s.size }.max
          paths.each do |p|
            @out.puts format("  %-4s  from %-15s as path %-#{width}s  %s",
                             p['best'] ? 'best' : 'lost', p['from'], p['as_path'], p['reason'])
          end
        end
        nil
      end

      def adj_in(peer, prefix = nil)
        page = api('show.adj_in', paged(peer, prefix))
        table(page, %w[from])
        nil
      end

      def adj_out(peer, prefix = nil)
        page = api('show.adj_out', paged(peer, prefix))
        table(page, [])
        skipped = page['skipped']
        if skipped && skipped['total'] > 0
          @out.puts "\nnot advertised:"
          skipped['rows'].each { |s| @out.puts format('%-18s %s', s['prefix'], s['reason']) }
        end
        nil
      end

      def fib
        page = api('show.fib')
        f = page['fib']
        unless f['configured']
          @out.puts 'no fib: key in the configuration, so nothing is installed'
          return nil
        end
        @out.puts format('%-18s %s', 'prefix', 'next hop')
        page['rows'].each { |r| @out.puts format('%-18s %s', r['prefix'], r['next_hop']) }
        f['failed'].each { |r| @out.puts "refused  #{r['prefix']}  #{r['error']}" }
        more(page, 'show.fib')
        nil
      end

      # ---- acting --------------------------------------------------------

      # `route.originate`. The `mark` key of the configuration is added
      # by the method itself, so a route made through `bgp4r-cli` carries
      # it too.
      def originate(*prefixes, **attrs)
        api('route.originate', body(prefixes, attrs))
      end
      alias announce originate

      def withdraw(*prefixes, **opts)
        api('route.withdraw', body(prefixes, opts))
      end

      # `clear bgp PEER`: Cease, Administrative Reset, then `peer.clear`.
      def clear(address = nil)
        p = peer(address)
        cease(p, ADMIN_RESET)
        api('peer.clear', 'peer' => p.address)
      end

      # `neighbor PEER shutdown`: Cease, Administrative Shutdown, then
      # `peer.stop`, so it stays down.
      def shutdown(address = nil)
        p = peer(address)
        cease(p, ADMIN_SHUTDOWN)
        api('peer.stop', 'peer' => p.address)
      end

      def no_shutdown(address = nil)
        api('peer.start', 'peer' => peer(address).address)
      end

      def refresh(address = nil, **opts)
        api('peer.refresh', stringify(opts).merge('peer' => peer(address).address))
      end

      def state(address = nil) ; peer(address).state ; end

      def neighbor(address = nil)
        p = peer(address)
        p.neighbor or raise ArgumentError, "#{p.address} has no session yet (state #{p.state})"
      end
      alias n neighbor

      # What leaving does before the daemon stops: Cease 6/2 to every
      # peer that is up, which is RFC 4486 section 4's Administrative
      # Shutdown. Answers how many were sent. `Neighbor#stop` drains its
      # output queue, so the Cease reaches the wire before the socket
      # closes.
      def stop
        speaker.established_peers.count { |p| cease(p, ADMIN_SHUTDOWN) }
      end

      private

      # The peer a verb goes to: the one named, or the only one
      # configured, or the only one up.
      def peer(address = nil)
        s = speaker
        return s.peer!(address) if address
        list = s.peers
        raise ArgumentError, 'no neighbor is configured' if list.empty?
        return list.first if list.size == 1
        up = s.established_peers
        return up.first if up.size == 1
        raise ArgumentError, "#{list.size} peers; name one. The peers are " \
                             "#{list.collect(&:address).join(', ')}"
      end

      # A Cease with that subcode when the session is up. True when one
      # was sent.
      def cease(p, subcode)
        return false unless p.established?
        p.send_message(BGP::Notification.new(CEASE, subcode))
        true
      rescue NoSession
        false
      end

      def paged(peer, prefix)
        h = { 'peer' => peer.to_s }
        h['prefix'] = prefix.to_s if prefix
        h
      end

      # One page of Adj-RIB rows as a table.
      def table(page, lead)
        cols = lead + %w[prefix next_hop as_path communities extended_communities large_communities]
        heads = cols.collect { |c| c.tr('_', ' ') }
        rows = page['rows'].collect do |r|
          cols.collect do |c|
            v = r[c]
            case c
            when 'extended_communities' then Array(v).collect { |h| CommunityKeys.extended_community_text(h) }.join(' ')
            else v.is_a?(Array) ? v.join(' ') : v.to_s
            end
          end
        end
        widths = cols.each_index.collect { |i| ([heads[i]] + rows.collect { |r| r[i] }).collect(&:size).max }
        line = ->(cells) { cells.each_with_index.collect { |c, i| c.ljust(widths[i]) }.join('  ').rstrip }
        @out.puts line.call(heads)
        rows.each { |r| @out.puts line.call(r) }
        more(page, nil)
      end

      def more(page, _method)
        return unless page['next_offset']
        @out.puts "... #{page['total'] - page['next_offset']} more; " \
                  "api with offset: #{page['next_offset']} for the next page"
      end

      # Seconds as hh:mm:ss, or '-' when the session is not up.
      def clock(s)
        return '-' if s.nil?
        format('%02d:%02d:%02d', s / 3600, s / 60 % 60, s % 60)
      end

      def body(prefixes, opts)
        b = {}
        prefixes = prefixes.flatten.collect(&:to_s)
        b['prefixes'] = prefixes unless prefixes.empty?
        b.merge(stringify(opts))
      end

      def stringify(h)
        (h || {}).each_with_object({}) { |(k, v), o| o[k.to_s] = v }
      end

    end

  end
end
