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

require 'bgp/daemon/client'
require 'bgp/version'

module BGP
  module Daemon

    # `bgp4r-cli`, the client command for `bgp4rd`.
    #
    #   bgp4r-cli -c 'show bgp summary'        text, for a person
    #   bgp4r-cli show.peers                   JSON, for a script
    #   bgp4r-cli show.rib '{"prefix":"10.0.0.0/8"}'
    #
    # **Two forms on purpose, which is docs/daemon.md's decision.** `-c`
    # takes an operator command and prints what a person would read at a
    # router; a bare method name prints the JSON a driver or a script
    # wants. Neither is a wrapper around the other: the method form is
    # one line of socket work, and the text form renders through
    # `bgp/rib/show.rb`.
    #
    # **`show bgp` asks the daemon for the text and does not render it
    # here, and that is a departure from ospfv2 with a reason.**
    # `ospf-cli` renders every view client side from the data, and
    # copying that would mean a second IOS, Junos and IOS-XR renderer in
    # this file beside `bgp/rib/show.rb`, which already has samples
    # behind its three styles and a column test per style. Two renderers
    # of one format is the shape CLAUDE.md records drifting three times.
    # `Show` takes a Rib::Table and the Table is in the daemon, so the
    # daemon renders: `show.text` is the one API method this adds beyond
    # the read list, and it is `rib.show(style, prefix)` and nothing
    # else.
    #
    # `show bgp summary` is the exception and is rendered here, because
    # `Show` has **no** summary form: there is no vendor sample behind
    # one, so adding a fourth thing to those three styles would be
    # inventing a format inside the file that says it never does. The
    # columns below are this file's own and no test depends on them.
    #
    # Output goes to injected IOs, as `BGP::Capture::CLI`'s does, so a
    # test reads a String rather than capturing a process.
    class CLI

      # The operator commands `-c` takes. Anything else is refused with
      # this list, rather than guessed at.
      #
      # `clear bgp PEER` is the one that changes something, and it is
      # here because docs/daemon.md gives it as an example a person
      # types. The rest of the write side is the method form: `peer.stop`
      # and `route.originate` take parameters a one line command grammar
      # would have to invent a syntax for, and this file is a string
      # match against a short list and not a parser.
      COMMANDS = ['show bgp summary', 'show bgp', 'show bgp PREFIX',
                  'show fib', 'show link-state', 'show configuration', 'show configuration candidate',
                  'clear bgp PEER'].freeze

      STYLES = %w[ios junos iosxr].freeze

      # The methods that answer many lines rather than one, so the method
      # form reads until it is stopped instead of printing one line and
      # leaving.
      #
      # **The client's own list and not `Api::STREAM_METHODS`.** This file
      # requires `bgp/daemon/client` and nothing else, so `bgp4r-cli`
      # loads a socket and a JSON parser rather than the whole library and
      # a Speaker, and `events.unsubscribe` is in the server's list and
      # is not something a caller starts. cli_test.rb holds this list
      # inside the server's so the two cannot disagree about a name.
      STREAMS = %w[events.subscribe].freeze

      USAGE = <<-TEXT
Usage: bgp4r-cli [options] [METHOD [JSON]]

  bgp4r-cli -c 'show bgp summary'      an operator command, as text
  bgp4r-cli -c 'show bgp'              the Loc-RIB, as a router prints it
  bgp4r-cli -c 'show bgp 10.0.0.0/8'   one prefix, in detail
  bgp4r-cli -c 'show link-state'       BGP-LS routes, sent and received
  bgp4r-cli -c 'show configuration'    its configuration, as set lines
  bgp4r-cli -c 'clear bgp 10.0.10.1'   reset one session
  bgp4r-cli show.peers                 an API method, as JSON
  bgp4r-cli show.rib '{"prefix":"10.0.0.0/8"}'
  bgp4r-cli peer.stop '{"peer":"10.0.10.1"}'
  bgp4r-cli events.subscribe           a stream, one event per line

Options:
  -s, --socket PATH   bgp4rd's socket (default: $BGP4R_SOCKET, else
                      /run/bgp4r/bgp4rd.sock or $XDG_RUNTIME_DIR/bgp4r)
  -c, --command CMD   run an operator command and print text
      --style NAME    ios (the default), junos or iosxr
      --pretty        indent the JSON
  -h, --help          this help
TEXT

      # `client` is the seam that keeps the tests free of a daemon: with
      # none, `start` builds a Client from `--socket` and the
      # environment.
      def initialize(out = $stdout, err = $stderr, client = nil)
        @out = out
        @err = err
        @client = client
      end

      # Returns an exit status.
      def start(argv, env = ENV)
        opts = parse(argv, env)
        return 0 if opts[:version]
        return help(0) if opts[:help]
        return help(1) if opts[:error]
        client = @client || Client.new(opts[:socket], env)
        begin
          opts[:command] ? command(client, opts) : method_call(client, opts)
        rescue Client::Error => e
          @err.puts "bgp4r-cli: #{e.message}"
          1
        ensure
          client.close
        end
      end

      private

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      # The option parsing, by hand rather than through OptionParser,
      # because the method form takes a bare argument and an argument
      # that looks like JSON, and OptionParser's `parse!` would try to
      # read a leading `{` as a flag.
      def parse(argv, env)
        opts = { :socket => env['BGP4R_SOCKET'], :style => 'ios', :pretty => false }
        rest = []
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '-s', '--socket' then opts[:socket] = argv[i += 1]
          when '-c', '--command' then opts[:command] = argv[i += 1]
          when '--style' then opts[:style] = argv[i += 1]
          when '--pretty' then opts[:pretty] = true
          when '-v', '--version' then opts[:version] = true
          else rest << argv[i]
          end
          i += 1
        end
        opts[:method], opts[:params] = rest[0], rest[1]
        if opts[:version]
          @out.puts BGP::VERSION
          return opts
        end
        return opts if opts[:help]
        opts[:error] = true if opts[:command].nil? && opts[:method].nil?
        opts[:error] = true if opts[:command] && opts[:method]
        opts[:error] = true unless STYLES.include?(opts[:style].to_s)
        opts
      end

      # The method form: one call, the result as JSON.
      def method_call(client, opts)
        require 'json'
        params = opts[:params] ? JSON.parse(opts[:params]) : {}
        unless params.is_a?(Hash)
          @err.puts 'bgp4r-cli: the second argument is a JSON object of parameters'
          return 1
        end
        return subscribe(client, opts[:method], params) if STREAMS.include?(opts[:method])
        result = client.call(opts[:method], params)
        @out.puts(opts[:pretty] ? JSON.pretty_generate(result) : JSON.generate(result))
        0
      rescue JSON::ParserError => e
        @err.puts "bgp4r-cli: the second argument is not JSON: #{e.message[0, 120]}"
        1
      end

      # A stream, one JSON object per line, until the daemon closes it or
      # the person interrupts. Each line is printed as it arrives rather
      # than collected, which is the whole point of a stream, so there is
      # no --pretty here: a line a reader pipes into `jq` has to be one
      # line.
      #
      # INT is caught so the connection is ended with
      # `events.unsubscribe` rather than dropped, which is what leaves
      # the daemon with no subscriber behind.
      def subscribe(client, method, params)
        client.stream(method, params) { |line| @out.puts(JSON.generate(line)) }
        0
      rescue Interrupt
        client.unsubscribe
        0
      end

      # The text form.
      def command(client, opts)
        cmd = opts[:command].to_s.strip.squeeze(' ')
        case cmd
        when 'show bgp summary' then @out.print summary(client)
        when 'show bgp' then @out.print routes(client, opts[:style], nil)
        when /\Ashow bgp (\S+)\z/ then @out.print routes(client, opts[:style], $1)
        when 'show fib' then @out.print fib(client)
        when 'show link-state' then @out.print link_state(client)
        when 'show configuration' then @out.print configuration(client, false)
        when 'show configuration candidate' then @out.print configuration(client, true)
        when /\Aclear bgp (\S+)\z/ then @out.print cleared(client, $1)
        else
          @err.puts "bgp4r-cli: #{opts[:command].inspect} is not one of: #{COMMANDS.join(', ')}"
          return 1
        end
        0
      end

      # `show configuration`, which is the one operator command here
      # whose text is not in the style of anybody's router: it is
      # bgp4rd's own configuration, in the set lines
      # `bgp/daemon/config.rb` defines, so a person can read what a
      # driver diffs. `show.configuration` with no `format` answers YAML
      # instead, which is the form the file is in.
      def configuration(client, candidate)
        params = { 'format' => 'set' }
        params['candidate'] = true if candidate
        client.call('show.configuration', params).to_s
      end

      # `show bgp summary`, in the shape of the command every router has.
      # The column widths are this file's; see the class comment on what
      # is quoted and what is not.
      def summary(client)
        s = client.call('show.status')
        sum = s['summary'] || {}
        out = +''
        out << format("BGP router identifier %s, local AS number %s\n", s['router_id'], s['as'])
        out << format("%d peer(s), %d established, %d prefix(es) in the Loc-RIB\n\n",
                      sum['peers'].to_i, sum['established'].to_i, sum['rib'].to_i)
        out << format("%-20s %-8s %-14s %10s %8s %8s %s\n",
                      'Neighbor', 'AS', 'State', 'Up/Down', 'PfxRcd', 'PfxSnt', 'Description')
        Array(s['peers']).each do |p|
          out << format("%-20s %-8s %-14s %10s %8s %8s %s\n",
                        p['address'], p['remote_as'], p['state'],
                        p['uptime'] ? "#{p['uptime']}s" : 'never',
                        p['received'] || 0, p['sent'] || 0, p['description'])
        end
        out
      end

      # `show fib`, what this daemon put in the kernel's forwarding table,
      # and what it did not: a prefix it skipped with the reason, and a
      # prefix the kernel refused with its error. The layout is this
      # file's own, as the summary's is. Every page of `show.fib` is read,
      # so a large table prints whole rather than its first page.
      #
      # It is bgp4rd's account and not the kernel's. `ip route show table
      # N` is the other question, and the header names the table to ask.
      def fib(client)
        rows, offset, info = [], 0, {}
        loop do
          page = client.call('show.fib', 'offset' => offset)
          info = page['fib'] || {}
          rows.concat(Array(page['rows']))
          offset = page['next_offset'] or break
        end
        return "No FIB: this daemon has no fib: block, so it installs nothing.\n" unless info['configured']
        out = +''
        out << format("FIB: %s, %d route(s) installed\n\n", info['backend'], rows.size)
        out << format("%-20s %s\n", 'Prefix', 'Next hop')
        rows.each { |r| out << format("%-20s %s\n", r['prefix'], r['next_hop']) }
        skipped = Array(info['skipped'])
        unless skipped.empty?
          out << "\nNot installed:\n"
          skipped.each { |r| out << format("%-20s %s\n", r['prefix'], r['reason']) }
        end
        failed = Array(info['failed'])
        unless failed.empty?
          out << "\nRefused by the kernel:\n"
          failed.each { |r| out << format("%-20s %s\n", r['prefix'], r['error']) }
        end
        out
      end

      # `show link-state`, the rows of `show.link_state` as a table: what
      # this daemon sent as a BGP-LS Producer, under peer `-`, and what it
      # received, per peer. Every page is read. The layout is this
      # file's own, as the summary's is.
      def link_state(client)
        rows, offset = [], 0
        loop do
          page = client.call('show.link_state', 'offset' => offset)
          rows.concat(Array(page['rows']))
          offset = page['next_offset'] or break
        end
        return "No BGP-LS routes.\n" if rows.empty?
        out = +''
        out << format("%d BGP-LS route(s)\n\n", rows.size)
        line = "%-15s %-6s %2s %-20s %-20s %6s %s\n"
        out << format(line, 'Peer', 'Type', 'L', 'Local', 'Remote or prefix', 'Metric', 'Node')
        rows.each do |r|
          node = [r['name'], *Array(r['flags']), *Array(r['areas'])].compact.join(' ')
          out << format(line, r['peer'] || '-', r['type'], r['protocol_id'], r['local'],
                        r['remote'] || r['prefix'], r['metric'], node).sub(/ +\n\z/, "\n")
        end
        out
      end

      # `clear bgp PEER`, which resets one session. The line it prints is
      # this file's own, as the summary's columns are.
      def cleared(client, peer)
        r = client.call('peer.clear', 'peer' => peer)
        format("Cleared %s: was %s, now %s\n", r['peer'], r['was'], r['state'])
      end

      # `show bgp` and `show bgp PREFIX`, rendered by the daemon through
      # bgp/rib/show.rb's three styles.
      def routes(client, style, prefix)
        params = { 'style' => style }
        params['prefix'] = prefix if prefix
        client.call('show.text', params).to_s
      end

    end

  end
end
