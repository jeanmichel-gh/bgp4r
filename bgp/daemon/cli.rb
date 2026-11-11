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
require 'bgp/daemon/shell'
require 'bgp/version'

module BGP
  module Daemon

    # `bgp4r-cli`, the client command for `bgp4rd`.
    #
    #   bgp4r-cli                              a prompt, on a terminal
    #   bgp4r-cli -c 'show bgp summary'        text, for a person
    #   bgp4r-cli show bgp summary             the same, without quotes
    #   bgp4r-cli show.peers                   JSON, for a script
    #   bgp4r-cli show.rib '{"prefix":"10.0.0.0/8"}'
    #
    # **Two forms on purpose, which is docs/daemon.md's decision.** An
    # operator command prints what a person would read at a router; a
    # method name prints the JSON a driver or a script wants. Neither is
    # a wrapper around the other: the method form is one line of socket
    # work, and the operator commands are `Shell`'s, in
    # bgp/daemon/shell.rb, which renders them.
    #
    # **On the command line, a first word with a dot is a method, and any
    # other first word starts an operator command.** No method name is a
    # command word and no command word has a dot, so the rule is never
    # ambiguous, and `-c` is still there for a script that quotes.
    #
    # **With no command and no method, a terminal gets the prompt** and
    # anything else gets the usage and status 1, as before the prompt
    # existed. docs/design/bgp4r-cli-shell.md left that open; reading
    # commands from a pipe would change what `bgp4r-cli </dev/null`
    # answers, and `-c` already covers a script.
    #
    # Output goes to injected IOs, as `BGP::Capture::CLI`'s does, so a
    # test reads a String rather than capturing a process.
    class CLI

      # The operator commands, each with its arguments by name. Anything
      # else is refused with this list, rather than guessed at. They are
      # the Shell's grammar, so this list cannot drift from it.
      #
      # `clear bgp PEER` is the one that changes something, and it is
      # here because docs/daemon.md gives it as an example a person
      # types. The rest of the write side is the method form.
      COMMANDS = Shell::COMMANDS

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
Usage: bgp4r-cli [options] [METHOD [JSON] | COMMAND...]

  bgp4r-cli                            a prompt: ? lists the commands
  bgp4r-cli show bgp summary           an operator command, no quotes
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
      # environment. `input` is where the prompt reads, and whether it is
      # a terminal decides whether bare `bgp4r-cli` opens one.
      def initialize(out = $stdout, err = $stderr, client = nil, input = $stdin)
        @out = out
        @err = err
        @client = client
        @input = input
      end

      # Returns an exit status.
      def start(argv, env = ENV)
        opts = parse(argv, env)
        return 0 if opts[:version]
        return help(0) if opts[:help]
        return help(1) if opts[:error]
        client = @client || Client.new(opts[:socket], env)
        begin
          if opts[:prompt] then prompt(client, opts)
          elsif opts[:command] then command(client, opts)
          else method_call(client, opts)
          end
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
        if rest[0] && !rest[0].include?('.')
          opts[:error] = true if opts[:command]
          opts[:command] = rest.join(' ')
        else
          opts[:method], opts[:params] = rest[0], rest[1]
        end
        if opts[:version]
          @out.puts BGP::VERSION
          return opts
        end
        return opts if opts[:help]
        if opts[:command].nil? && opts[:method].nil?
          @input.respond_to?(:tty?) && @input.tty? ? opts[:prompt] = true : opts[:error] = true
        end
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

      def shell(client, opts)
        require 'socket'
        Shell.new(client, :style => opts[:style], :hostname => Socket.gethostname.split('.').first)
      end

      # An operator command, from `-c` or the bare words: its text, or
      # its refusal and status 1.
      def command(client, opts)
        r = shell(client, opts).execute(opts[:command])
        @out.print r.text
        return 0 unless r.error
        @err.puts "bgp4r-cli: #{r.error}"
        1
      end

      # The prompt, until `exit`, `quit` or Ctrl-D.
      def prompt(client, opts)
        shell(client, opts).interactive(@input, @out)
        0
      end

    end

  end
end
