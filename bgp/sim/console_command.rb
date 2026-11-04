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


require 'bgp/sim/console'

module BGP
  module Sim

    # `bgp4r console`: an irb prompt with the library loaded, and a
    # session only when one is asked for.
    #
    #   bgp4r console
    #   bgp4r console --peer 10.0.0.2 --peer-as 65002
    #
    # With no `--peer` it opens on no session at all, so a person can
    # build and parse objects, and open a session with `connect` or
    # `listen` at the prompt. `--peer` is a `connect` done before the
    # prompt opens, so the two cannot differ: both go through
    # `Console#connect`.
    #
    # **It takes routegen's session flags and none of the ones that
    # generate routes.** A prompt starts silent, which is the injector's
    # rule; `announce` with a `generate:` block does a range from there.
    #
    # docs/console.md section 9 is the guide.
    class ConsoleCommand

      USAGE = <<-TEXT
Usage: bgp4r console [options]

An irb prompt with bgp4r loaded. With no --peer there is no session:
open one at the prompt with connect or listen. 'verbs' lists what to
type, 'guide' prints docs/console.md, exit quits.

      --peer ADDR       dial this peer before the prompt opens
      --peer-as AS      its AS (required with --peer)
      --my-as AS        our AS (default #{Console::DEFAULT_AS})
      --id ID           our router id (default #{Console::DEFAULT_ID})
      --port PORT       the peer's port (default 179)
      --local-address A the address to dial from
      --timeout SECS    how long to wait for the session (default 30)
  -l, --log FILE        log file, - for standard output. The default is a
                        file in the temporary folder, named when it opens
  -d, --debug           log every message too
  -h, --help            this help
TEXT

      DEFAULT_TIMEOUT = 30

      attr_reader :console

      # arg[:console] builds the Console and arg[:interact] opens the
      # prompt on it. Both are seams for a test, which must never reach
      # irb: irb reads standard input, so a refusal that fell through to
      # it would hang the suite rather than fail it.
      def initialize(out = $stdout, err = $stderr, arg = {})
        @out = out
        @err = err
        @new_console = arg[:console] || -> { Console.new(nil, @out) }
        @interact = arg[:interact] || ->(console) { console.interact }
        @load_irb = arg.fetch(:load_irb, true)
      end

      def start(argv)
        opts = parse(argv)
        return 0 if opts[:help]
        return 1 if opts[:error]
        # The flags first and irb second, so neither a bad flag nor a
        # missing irb opens a session.
        args = connect_args(opts)
        Console.load_irb if @load_irb
        setup_log(opts)
        @console = @new_console.call
        if args
          row = @console.connect(args[0], **args[1])
          @out.puts "console: session to #{row[:address]} is #{row[:state].to_s.downcase}" \
                    "#{row[:state].to_s == 'Established' ? '' : ', still trying'}"
        end
        @interact.call(@console)
        0
      rescue ArgumentError, KeyError, SystemCallError, LoadError => e
        @err.puts "console: #{e.message}"
        1
      ensure
        @console.stop if @console
      end

      # What `--peer` and its flags hand to `Console#connect`, or nil with
      # no `--peer`.
      def connect_args(opts)
        if opts[:peer_as] && !opts[:peer]
          raise ArgumentError, '--peer-as needs --peer'
        end
        return nil unless opts[:peer]
        raise ArgumentError, '--peer needs --peer-as' unless opts[:peer_as]
        kw = { :remote_as => Integer(opts[:peer_as]),
               :local_as  => Integer(opts[:my_as] || Console::DEFAULT_AS),
               :router_id => opts[:id] || Console::DEFAULT_ID,
               :wait      => Float(opts[:timeout] || DEFAULT_TIMEOUT) }
        kw[:port] = Integer(opts[:port]) if opts[:port]
        kw[:local_address] = opts[:local_address] if opts[:local_address]
        [opts[:peer], kw]
      end

      private

      # **The log goes to a file unless -l names one**, because a session
      # logs from its own threads and every line would land in the
      # middle of what the person is typing. routegen --interact does
      # the same.
      def setup_log(opts)
        if opts[:log].nil?
          require 'tmpdir'
          opts[:log] = File.join(Dir.tmpdir, "bgp4r-console-#{Process.pid}.log")
          @out.puts "console: logging to #{opts[:log]}"
        end
        io = if opts[:log] == '-'
               $stdout
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        Log.set_filename(io)
        Log.level = opts[:debug] ? Logger::DEBUG : Logger::INFO
      end

      # OptionParser, required here for the reason routegen gives.
      def parse(argv)
        require 'optparse'
        opts = {}
        parser = OptionParser.new do |o|
          o.on('--peer ADDR') { |v| opts[:peer] = v }
          o.on('--peer-as AS') { |v| opts[:peer_as] = v }
          o.on('--my-as AS') { |v| opts[:my_as] = v }
          o.on('--id ID') { |v| opts[:id] = v }
          o.on('--port PORT') { |v| opts[:port] = v }
          o.on('--local-address ADDR') { |v| opts[:local_address] = v }
          o.on('--timeout SECS') { |v| opts[:timeout] = v }
          o.on('-l', '--log FILE') { |v| opts[:log] = v }
          o.on('-d', '--debug') { opts[:debug] = true }
          o.on('-h', '--help') { opts[:help] = true }
        end
        rest = parser.parse(argv)
        unless rest.empty?
          @err.puts "console: unexpected #{rest.join(' ')}"
          @err.print USAGE
          return { :error => true }
        end
        @out.print USAGE if opts[:help]
        opts
      rescue OptionParser::ParseError => e
        @err.puts "console: #{e.message}"
        @err.print USAGE
        { :error => true }
      end

    end

  end
end
