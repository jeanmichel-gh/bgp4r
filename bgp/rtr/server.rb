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

require 'bgp/version'
require 'bgp/logging'
require 'bgp/rtr/cache'
require 'bgp/sim/http'

module BGP
  module Rtr

    # bgp4r-rtr's HTTP API: bgp4r-sim's server (bgp/sim/http.rb) with
    # its own paths. A POST needs X-BGP4R: routescope, and a refusal is
    # a 4xx with {"error": ...}, as bgp4r-sim's.
    class Http < Sim::Http
      READS = {
        '/api/status'  => :status,
        '/api/vrps'    => :vrps,
        '/api/routers' => :routers,
        '/api/events'  => :events_view,
      }.freeze

      ACTIONS = {
        '/api/vrps'      => 'vrps',
        '/api/fault'     => 'fault',
        '/api/behaviour' => 'behaviour',
      }.freeze

      DRY_RUNS = {}.freeze

      # A path is both a read and an action: GET /api/vrps reads the
      # table, POST /api/vrps changes it.
      def dispatch(method, path, headers, body)
        route = path.to_s.split('?', 2).first
        return super unless READS.key?(route) && ACTIONS.key?(route) && method == 'POST'
        # Sim::Http's names: Rtr::HEADER is the PDU header's length.
        name, value = Sim::Http::HEADER, Sim::Http::HEADER_VALUE
        return [403, { :error => "a POST needs #{name.upcase}: #{value}" }] unless headers[name].to_s == value
        [200, @injector.act(ACTIONS[route], parse_body(body))]
      end
    end

    # `bgp4r-rtr`, an RTR cache: the command line, the node file, the
    # Cache, its HTTP API, and the thread that watches the file and runs
    # the Cache's clock.
    #
    #   bgp4r-rtr /lab/rtr.yml --api 0.0.0.0:8080
    #
    # docs/rpki.md section 4 is the node file.
    class Server

      USAGE = <<-TEXT
Usage: bgp4r-rtr FILE [options]

  FILE                  the YAML node file (required): the VRPs and timers
  -f, --config FILE     the same, named
      --listen HOST:PORT where routers connect (default: 0.0.0.0:#{PORT})
      --api HOST:PORT    where the HTTP API listens (default: 127.0.0.1:8080)
  -l, --log FILE        log file, - for standard output
  -v, --version         print the bgp4r version
  -h, --help            this help

It serves the file's VRPs, and serves them again with a new serial when
the file changes. Drive it with HTTP on the loopback:

  curl 127.0.0.1:8080/api/vrps
  curl -X POST -H 'X-BGP4R: routescope' \\
       -d '{"announce":[{"prefix":"192.0.2.0/24","asn":65001}]}' \\
       127.0.0.1:8080/api/vrps

See docs/rpki.md.
TEXT

      # How often, in seconds, the clock runs and the file is looked at.
      TICK = 0.2
      WATCH = 1

      attr_reader :cache, :http, :watch

      def initialize(out = $stdout, err = $stderr)
        @out = out
        @err = err
      end

      # Parses argv, builds everything, and returns an exit status. With
      # wait: false it returns 0 once up, which is what a test runs.
      def start(argv, wait: true)
        opts = parse(argv)
        return 0 if opts[:version]
        return help(0) if opts[:help]
        return help(1) if opts[:error]
        config = load_config(opts[:config]) or return 1
        setup_log(opts)
        build(config, opts) or return 1
        return 0 unless wait
        wait_for_a_signal
        0
      end

      def build(config, opts = {})
        @file = opts[:config]
        @mtime = @file && File.mtime(@file)
        @watch = Float(config['watch'] || WATCH)
        @cache = Cache.new(config, :logger => @logger)
        listen = Server.listen_address(opts[:listen] || config['listen'] || "0.0.0.0:#{PORT}")
        @cache.listen(listen[:bind], listen[:port])
        @http = Http.new(@cache, @cache, Sim::Http.address(opts[:api] || config['api'] || '127.0.0.1:8080')
                                             .merge(:logger => @logger))
        @http.start
        @ticker = Thread.new { run_clock }
        log(:info, "bgp4r-rtr #{BGP::VERSION} up, session #{@cache.session_id}, serial #{@cache.serial}, " \
                   "#{@cache.vrp_keys.size} VRPs, routers on #{listen[:bind]}:#{@cache.port}, api #{@http.url}")
        self
      rescue Refused, ArgumentError, TypeError, SystemCallError => e
        @err.puts "bgp4r-rtr: #{e.message}"
        stop
        nil
      end

      def stop
        @ticker&.kill
        @http&.stop
        @cache&.stop
        self
      end

      # HOST:PORT as Sim::Http.address reads it, but a port alone listens
      # on every address, since routers connect from other nodes.
      def self.listen_address(text)
        return { :bind => '0.0.0.0', :port => Integer(text.to_s) } if text.to_s.strip =~ /\A\d+\z/
        Sim::Http.address(text)
      end

      def load_config(file)
        require 'yaml'
        config = YAML.safe_load(File.read(file))
        config = {} if config.nil?
        return config if config.is_a?(Hash)
        @err.puts "bgp4r-rtr: #{file} is not a YAML mapping"
        nil
      rescue Errno::ENOENT
        @err.puts "bgp4r-rtr: #{file}: no such file"
        nil
      rescue SystemCallError, Psych::SyntaxError => e
        @err.puts "bgp4r-rtr: #{file}: #{e.message}"
        nil
      end

      # The file again when it changed: its VRPs become the table. A file
      # that does not read keeps the table as it is, and says why.
      def reread
        return unless @file
        mtime = File.mtime(@file)
        return if mtime == @mtime
        @mtime = mtime
        config = load_config(@file) or return
        @cache.load(config['vrps'] || [], 'file')
      rescue Refused, SystemCallError => e
        log(:warn, "#{@file}: #{e.message}; the VRPs are as they were")
      end

      private

      def run_clock
        last = 0
        loop do
          sleep TICK
          begin
            @cache.tick
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if now - last >= @watch
              last = now
              reread
            end
          rescue StandardError => e
            log(:error, "clock: #{e.class}: #{e.message}")
          end
        end
      end

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      def parse(argv)
        opts = {}
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '-f', '--config' then opts[:config] = argv[i += 1]
          when '--listen' then opts[:listen] = argv[i += 1]
          when '--api' then opts[:api] = argv[i += 1]
          when '-l', '--log' then opts[:log] = argv[i += 1]
          when '-v', '--version'
            @out.puts BGP::VERSION
            opts[:version] = true
          else
            if argv[i].to_s.start_with?('-') || opts[:config]
              @err.puts "bgp4r-rtr: unknown argument #{argv[i].inspect}"
              opts[:error] = true
            else
              opts[:config] = argv[i]
            end
          end
          i += 1
        end
        opts[:error] = true if opts[:config].nil? && !opts[:version] && !opts[:help]
        opts
      end

      # One process, one log, as bgp4r-sim's (bgp/sim/server.rb).
      def setup_log(opts)
        io = if opts[:log].nil? || opts[:log] == '-'
               @out
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        Log.set_filename(io)
        Log.level = Logger::INFO
        @logger = BGP::Logging.to_log
      end

      def log(level, message) ; @logger&.call(level, message) ; end

      # INT and TERM stop. The file is read again on its own, so HUP is
      # not needed and does nothing but say so.
      def wait_for_a_signal
        signals = Queue.new
        %w[INT TERM HUP].each { |sig| trap(sig) { signals << sig } }
        loop do
          if signals.pop == 'HUP'
            log(:info, 'SIGHUP: the file is read again when it changes; nothing to do')
          else
            log(:info, 'bgp4r-rtr stopping')
            stop
            return
          end
        end
      end
    end
  end
end
