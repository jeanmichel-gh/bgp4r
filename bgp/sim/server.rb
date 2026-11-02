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

require 'bgp/sim/injector'
require 'bgp/sim/views'
require 'bgp/sim/http'

module BGP
  module Sim

    # `bgp4r-sim`, the route injector: the command line, the node file,
    # the Injector, the HTTP API and the loop that waits.
    #
    #   bgp4r-sim /lab/sim.yml --api 0.0.0.0:8080
    #   bgp4r sim /lab/sim.yml
    #
    # docs/daemon.md is the design, from its `bgp4r-sim, the injector`
    # heading on, and its Configuration section is this file's YAML.
    #
    # **It is `bgp/daemon/server.rb`'s shape with three differences**,
    # and reading the two together is the quickest way to see what an
    # injector is:
    #
    # * **No table.** `Speaker#rib?` is false for a node file with none
    #   of the four router keys, and `Injector.check_config` refuses
    #   those keys outright, so there is nothing here like the daemon's
    #   `with_defaults` turning a RIB on.
    # * **HTTP rather than a Unix socket**, because an injector is driven
    #   by a page and a scenario runner where a daemon is operated from a
    #   shell. docs/daemon.md records both halves of that.
    # * **The file is positional.** `bgp4rd -f FILE` is a daemon's
    #   ergonomics and `bgp4r sim /lab/sim.yml` is a container command;
    #   `-f` works too, so neither habit is wrong.
    #
    # Output goes to injected IOs, as the daemon's and
    # `BGP::Capture::CLI`'s do, so a test reads a String rather than
    # capturing a process.
    class Server

      USAGE = <<-TEXT
Usage: bgp4r-sim FILE [options]       (or: bgp4r sim FILE [options])

  FILE                the YAML node file (required)
  -f, --config FILE   the same, named
      --api HOST:PORT where the HTTP API listens (default: 127.0.0.1:8080)
  -l, --log FILE      log file, - for standard output
  -d, --debug         log every message too
  -v, --version       print the bgp4r version
  -h, --help          this help

It starts silent: nothing is announced until the API asks. Drive it with
HTTP on the loopback, which needs no client:

  curl #{Http::DEFAULT_BIND}:#{Http::DEFAULT_PORT}/api/status
  curl -X POST -H '#{Http::HEADER.upcase}: #{Http::HEADER_VALUE}' \\
       -d '{"prefixes":["10.1.0.0/24"],"med":100}' \\
       #{Http::DEFAULT_BIND}:#{Http::DEFAULT_PORT}/api/announce

See docs/daemon.md.
TEXT

      attr_reader :injector, :views, :http

      def initialize(out = $stdout, err = $stderr)
        @out = out
        @err = err
      end

      # Parses argv, builds everything, and returns an exit status. With
      # :wait => false it starts and returns 0 without waiting, which is
      # what a test runs.
      def start(argv, env = ENV, wait: true)
        opts = parse(argv, env)
        return 0 if opts[:version]
        return help(0) if opts[:help]
        return help(1) if opts[:error]
        config = load_config(opts) or return 1
        setup_log(opts, config)
        build(config, opts) or return 1
        return 0 unless wait
        wait_for_a_signal
        0
      end

      # Builds the Injector, the Views and the HTTP server and starts
      # all three. Answers nil and prints the reason on anything a person
      # can fix, which for an injector is mostly the node file.
      def build(config, opts = {})
        @injector = Injector.new(config)
        @views    = Views.new(@injector)
        @http     = Http.new(@views, @injector,
                             Http.address(opts[:api] || config['api'] ||
                                          "#{Http::DEFAULT_BIND}:#{Http::DEFAULT_PORT}")
                                 .merge(:logger => @logger))
        @injector.start
        @http.start
        log(:info, "bgp4r-sim #{BGP::VERSION} up, AS #{@injector.speaker.my_as}, " \
                   "router id #{@injector.speaker.router_id}, api #{@http.url}, " \
                   'silent until asked')
        self
      rescue Injector::Refused, ArgumentError, KeyError, SystemCallError => e
        @err.puts "bgp4r-sim: #{e.message}"
        stop
        nil
      end

      def stop
        @http.stop if @http
        @injector.stop if @injector
        self
      end

      # The YAML file, as a Hash, or nil with the reason printed. It
      # opens no log and starts nothing, so a caller and a test can read
      # a node file without touching the library's logger.
      def load_config(opts)
        require 'yaml'
        config = YAML.safe_load(File.read(opts[:config]))
        unless config.is_a?(Hash)
          @err.puts "bgp4r-sim: #{opts[:config]} is not a YAML mapping"
          return nil
        end
        config
      rescue Errno::ENOENT
        @err.puts "bgp4r-sim: #{opts[:config]}: no such file"
        nil
      rescue SystemCallError, Psych::SyntaxError => e
        @err.puts "bgp4r-sim: #{opts[:config]}: #{e.message}"
        nil
      end

      private

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      def parse(argv, env)
        opts = { :api => env['BGP4R_SIM_API'], :log => nil, :debug => false }
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '-f', '--config' then opts[:config] = argv[i += 1]
          when '--api' then opts[:api] = argv[i += 1]
          when '-l', '--log' then opts[:log] = argv[i += 1]
          when '-d', '--debug' then opts[:debug] = true
          when '-v', '--version'
            @out.puts BGP::VERSION
            opts[:version] = true
          else
            if argv[i].to_s.start_with?('-') || opts[:config]
              @err.puts "bgp4r-sim: unknown argument #{argv[i].inspect}"
              opts[:error] = true
            else
              opts[:config] = argv[i]
            end
          end
          i += 1
        end
        return opts if opts[:version] || opts[:help]
        opts[:error] = true if opts[:config].nil?
        opts
      end

      # `Log` is the library's logger and the Speaker's sessions already
      # write to it, so there is one place for a line to come out.
      #
      # **`Log.set_filename` and not `Log.create`**, for the reason
      # `bgp/daemon/server.rb` records: `Log.create` is `@@logger ||=
      # new(s)`, so against a logger that already exists it keeps the old
      # one and `--log FILE` writes nowhere.
      def setup_log(opts, config)
        io = if opts[:log].nil? || opts[:log] == '-'
               $stdout
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        Log.set_filename(io)
        Log.level = opts[:debug] ? Logger::DEBUG : Daemon::Speaker.log_level(config)
        @logger = ->(level, message) { Log.send(level, message) }
      end

      def log(level, message)
        @logger.call(level, message) if @logger
      end

      # INT and TERM stop. HUP is **not** a reload, for the reason
      # `bgp4rd` gives: a signal that silently did nothing would read as
      # a reload that worked. An injector has less to reload than a
      # daemon, since everything it does is an action.
      def wait_for_a_signal
        signals = Queue.new
        %w[INT TERM HUP].each { |sig| trap(sig) { signals << sig } }
        loop do
          case signals.pop
          when 'HUP'
            log(:warn, 'SIGHUP: reloading the node file is not implemented; nothing changed')
          else
            log(:info, 'bgp4r-sim stopping')
            stop
            return
          end
        end
      end

    end

  end
end
