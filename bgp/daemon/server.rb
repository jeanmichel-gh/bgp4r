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
require 'bgp/daemon/views'
require 'bgp/daemon/log_ring'
require 'bgp/daemon/candidate'
require 'bgp/daemon/api'
require 'bgp/daemon/client'

module BGP
  module Daemon

    # `bgp4rd`, the daemon: the command line, the configuration file, the
    # Speaker, the control socket, and the loop that waits.
    #
    #   bgp4rd -f /etc/bgp4r/bgp4rd.yml
    #   bgp4r-cli -c 'show bgp summary'
    #
    # docs/daemon.md is the design and its Configuration section is this
    # file's YAML. The keys are `lab/speaker.rb`'s node file keys plus
    # `socket`, because that daemon's configuration is the node file with
    # more in it.
    #
    # **Three things it does that the lab speaker does not.**
    #
    # * **A table is always on.** `Speaker#rib?` makes one only when the
    #   node file asks, because every topology written before #231 would
    #   otherwise start deciding routes. A daemon is a router by
    #   definition and `show.routes` has to answer, so `rib` defaults to
    #   true here and a configuration saying `rib: false` turns it off
    #   deliberately.
    # * **A control socket**, which is the whole point, and the socket
    #   path is worked out the same way `bgp4r-cli` works it out, in
    #   `Client.default_socket`, so neither end has to be told.
    # * **Its own logging**, `--log FILE` with `-` for standard output,
    #   which is what a container wants.
    #
    # Output goes to injected IOs, as `BGP::Capture::CLI`'s does, so a
    # test reads a String rather than capturing a process.
    class Server

      USAGE = <<-TEXT
Usage: bgp4rd -f FILE [options]

  -f, --config FILE   the YAML configuration (required)
  -s, --socket PATH   the control socket (default: $BGP4R_SOCKET, else
                      /run/bgp4r/bgp4rd.sock or $XDG_RUNTIME_DIR/bgp4r)
      --state FILE    write the state file here as well
  -l, --log FILE      log file, - for standard output
  -d, --debug         log every message too
  -v, --version       print the bgp4r version
  -h, --help          this help

Talk to it with bgp4r-cli. See docs/daemon.md.
TEXT

      attr_reader :speaker, :api, :views, :log_ring, :candidate

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
        build(Server.with_defaults(config), opts) or return 1
        return 0 unless wait
        wait_for_a_signal
        0
      end

      # The keys the daemon decides rather than reads.
      #
      # **A table is always on, where `Speaker#rib?` makes one only when
      # the node file asks.** That difference is deliberate: in the lab
      # a table has to be asked for or every topology written before
      # #231 would start deciding routes, and in a daemon a table is
      # what the program is. A file saying `rib: false` turns it off,
      # and then `show.routes` answers an empty page rather than
      # failing, which is the honest answer for a speaker with no table.
      def self.with_defaults(config)
        { 'rib' => true }.merge(config)
      end

      # Builds the Speaker, the Views and the Api and starts all three.
      # Answers nil and prints the reason on anything a person can fix.
      def build(config, opts = {})
        @speaker = Speaker.new(config)
        @views   = Views.new(@speaker, :log => @log_ring)
        # The candidate is built here rather than left to `Api#candidate`
        # so that it carries the logger and so that `--config`'s path is
        # known to the reload: one of it, with one history.
        @candidate = Candidate.new(@speaker, config, :logger => @logger)
        @config_path = opts[:config]
        @api     = Api.new(@views, :path => opts[:socket] || Client.default_socket,
                                   :logger => @logger, :candidate => @candidate)
        @speaker.start
        @api.start
        log(:info, "bgp4rd #{BGP::VERSION} up, AS #{@speaker.my_as}, " \
                   "router id #{@speaker.router_id}, socket #{@api.path}")
        self
      rescue ArgumentError, KeyError, Api::InUse, SystemCallError => e
        @err.puts "bgp4rd: #{e.message}"
        stop
        nil
      end

      def stop
        @api.stop if @api
        @speaker.stop if @speaker
        self
      end

      # The YAML file, as a Hash, or nil with the reason printed. It
      # opens no log and starts nothing, so a caller and a test can read
      # a configuration without touching the library's logger.
      def load_config(opts)
        require 'yaml'
        config = YAML.safe_load(File.read(opts[:config]))
        unless config.is_a?(Hash)
          @err.puts "bgp4rd: #{opts[:config]} is not a YAML mapping"
          return nil
        end
        config['state_file'] = opts[:state] if opts[:state]
        config
      rescue Errno::ENOENT
        @err.puts "bgp4rd: #{opts[:config]}: no such file"
        nil
      rescue SystemCallError, Psych::SyntaxError => e
        @err.puts "bgp4rd: #{opts[:config]}: #{e.message}"
        nil
      end

      # SIGHUP **is** a reload now, which is what the candidate
      # configuration bought: the file becomes the candidate and is
      # committed, so a reload is the same code path as
      # `config.replace` followed by `config.commit` and cannot drift
      # from it.
      #
      # **A reload that cannot be done changes nothing and says so.** A
      # key that needs a restart is refused by the commit, so the lines
      # go in the log with the reason and the running configuration stays
      # true; that is the whole of docs/daemon.md's function 9, "reload
      # its configuration without dropping sessions it need not drop",
      # and the sessions it need not drop are the ones whose keys did not
      # change.
      def reload
        return log(:warn, 'SIGHUP: there is no configuration file to reload') unless @config_path
        config = load_config(:config => @config_path) or
          return log(:warn, 'SIGHUP: the configuration file could not be read; nothing changed')
        errors = @candidate.replace(:lines => Config.to_set(config))[:errors]
        unless errors.empty?
          @candidate.discard
          return log(:warn, "SIGHUP: #{errors.join('; ')}; nothing changed")
        end
        r = @candidate.commit(:comment => 'SIGHUP')
        if r[:ok]
          log(:info, "SIGHUP: #{r[:changes].size} change(s) committed")
          r[:warnings].each { |w| log(:warn, "SIGHUP: #{w}") }
        else
          @candidate.discard
          r[:errors].each { |e| log(:warn, "SIGHUP: #{e}") }
          log(:warn, 'SIGHUP: nothing changed')
        end
      rescue Config::Error => e
        @candidate.discard
        log(:warn, "SIGHUP: #{e.message}; nothing changed")
      end

      private

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      def parse(argv, env)
        opts = { :socket => env['BGP4R_SOCKET'], :log => nil, :debug => false }
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '-f', '--config' then opts[:config] = argv[i += 1]
          when '-s', '--socket' then opts[:socket] = argv[i += 1]
          when '--state' then opts[:state] = argv[i += 1]
          when '-l', '--log' then opts[:log] = argv[i += 1]
          when '-d', '--debug' then opts[:debug] = true
          when '-v', '--version'
            @out.puts BGP::VERSION
            opts[:version] = true
          else
            @err.puts "bgp4rd: unknown argument #{argv[i].inspect}"
            opts[:error] = true
          end
          i += 1
        end
        return opts if opts[:version] || opts[:help]
        opts[:error] = true if opts[:config].nil?
        opts
      end

      # `Log` is the library's logger and the Speaker's sessions already
      # write to it, so there is one place for a line to come out. The
      # `--log` file is opened unbuffered because a container reads it as
      # it happens.
      #
      # **`Log.set_filename` and not `Log.create`, which is the one that
      # reads right and does nothing.** `Log.create` is `@@logger ||=
      # new(s)`, so against a logger that already exists it keeps the old
      # one and `--log FILE` writes nowhere. In a fresh process the two
      # agree, which is why `lab/speaker.rb` has used `create` for as
      # long as it has; a daemon told where to log must not depend on
      # being the first thing to ask.
      def setup_log(opts, config)
        io = if opts[:log].nil? || opts[:log] == '-'
               $stdout
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        # **The ring goes in front of the real destination, which is the
        # only place it can go.** `show.log` answers the last N lines, and
        # the lines are written by `Log` from every session thread rather
        # than through the `@logger` below, which only this file and the
        # Api use. A ring fed from that lambda would answer the daemon's
        # own handful of lines and call them the log.
        # `bgp/daemon/log_ring.rb` has the decision and what it rejected.
        @log_ring = LogRing.new(io)
        Log.set_filename(@log_ring)
        Log.level = opts[:debug] ? Logger::DEBUG : Speaker.log_level(config)
        @logger = ->(level, message) { Log.send(level, message) }
      end

      def log(level, message)
        @logger.call(level, message) if @logger
      end

      # INT and TERM stop. HUP reloads, above.
      def wait_for_a_signal
        signals = Queue.new
        %w[INT TERM HUP].each { |sig| trap(sig) { signals << sig } }
        loop do
          case signals.pop
          when 'HUP'
            reload
          else
            log(:info, 'bgp4rd stopping')
            stop
            return
          end
        end
      end

    end

  end
end
