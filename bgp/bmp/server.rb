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
require 'bgp/bmp/station'
require 'bgp/sim/http'

module BGP
  module Bmp

    # bgp4r-bmp's HTTP API: bgp4r-sim's server (bgp/sim/http.rb) with
    # its own paths. A station only reads, so it has no actions, and a
    # POST is refused.
    class Http < Sim::Http
      READS = {
        '/api/status'  => :status,
        '/api/routers' => :routers,
        '/api/peers'   => :peers,
        '/api/routes'  => :routes,
        '/api/lines'   => :lines,
        '/api/events'  => :events_view,
      }.freeze

      ACTIONS = {}.freeze
      DRY_RUNS = {}.freeze
    end

    # `bgp4r-bmp`, a BMP station: the command line, the Station, and its
    # HTTP API.
    #
    #   bgp4r-bmp --listen 0.0.0.0:5000 --api 0.0.0.0:8080
    #
    # docs/bmp.md section 5.
    class Server

      USAGE = <<-TEXT
Usage: bgp4r-bmp [options]

      --listen HOST:PORT  where routers dial in (default: 0.0.0.0:#{Station::PORT})
      --connect HOST:PORT dial a router that listens, again and again; may repeat
      --no-listen         dial only
      --api HOST:PORT     where the HTTP API listens (default: 127.0.0.1:8080)
      --lines FILE        the JSON lines, - for standard output (the default)
  -l, --log FILE          log file, - for standard error (the default)
  -v, --version           print the bgp4r version
  -h, --help              this help

  curl 127.0.0.1:8080/api/peers
  curl '127.0.0.1:8080/api/routes?view=post_policy'

See docs/bmp.md.
TEXT

      attr_reader :station, :http

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
        setup_log(opts)
        # Before it is up, so a signal sent once the log says so is caught.
        signals = wait && catch_signals
        build(opts) or return 1
        return 0 unless wait
        signals.pop
        log(:info, 'bgp4r-bmp stopping')
        stop
        0
      end

      def build(opts = {})
        @lines_io = lines_io(opts[:lines])
        @station = Station.new(:lines => @lines_io, :logger => @logger)
        where = []
        unless opts[:no_listen]
          listen = Server.listen_address(opts[:listen] || "0.0.0.0:#{Station::PORT}")
          port = @station.listen(listen[:bind], listen[:port])
          where << "routers on #{listen[:bind]}:#{port}"
        end
        (opts[:connect] || []).each do |c|
          a = Sim::Http.address(c)
          @station.connect(a[:bind], a[:port])
          where << "dialing #{c}"
        end
        @http = Http.new(@station, @station, Sim::Http.address(opts[:api] || '127.0.0.1:8080').merge(:logger => @logger))
        @http.start
        log(:info, "bgp4r-bmp #{BGP::VERSION} up, #{where.join(', ')}, api #{@http.url}")
        self
      rescue ArgumentError, TypeError, SystemCallError => e
        @err.puts "bgp4r-bmp: #{e.message}"
        stop
        nil
      end

      def stop
        @http&.stop
        @station&.stop
        @lines_io.close if @lines_io.is_a?(File) && !@lines_io.closed?
        self
      end

      # HOST:PORT as Sim::Http.address reads it, but a port alone listens
      # on every address, since routers dial in from other nodes.
      def self.listen_address(text)
        return { :bind => '0.0.0.0', :port => Integer(text.to_s) } if text.to_s.strip =~ /\A\d+\z/
        Sim::Http.address(text)
      end

      private

      def lines_io(name)
        return @out if name.nil? || name == '-'
        File.open(name, File::WRONLY | File::APPEND | File::CREAT, 0o644).tap { |f| f.sync = true }
      end

      def help(status)
        (status.zero? ? @out : @err).print USAGE
        status
      end

      def parse(argv)
        opts = { :connect => [] }
        i = 0
        while i < argv.size
          case argv[i]
          when '-h', '--help' then opts[:help] = true
          when '--listen' then opts[:listen] = argv[i += 1]
          when '--connect' then opts[:connect] << argv[i += 1]
          when '--no-listen' then opts[:no_listen] = true
          when '--api' then opts[:api] = argv[i += 1]
          when '--lines' then opts[:lines] = argv[i += 1]
          when '-l', '--log' then opts[:log] = argv[i += 1]
          when '-v', '--version'
            @out.puts BGP::VERSION
            opts[:version] = true
          else
            @err.puts "bgp4r-bmp: unknown argument #{argv[i].inspect}"
            opts[:error] = true
          end
          i += 1
        end
        if opts[:no_listen] && opts[:connect].empty?
          @err.puts 'bgp4r-bmp: --no-listen needs a --connect'
          opts[:error] = true
        end
        opts
      end

      # The log goes to standard error by default, since the JSON lines
      # have standard output.
      def setup_log(opts)
        io = if opts[:log].nil? || opts[:log] == '-'
               @err
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        Log.set_filename(io)
        @logger = BGP::Logging.to_log
      end

      def log(level, message) ; @logger&.call(level, message) ; end

      # INT and TERM, each put on the Queue it returns.
      def catch_signals
        signals = Queue.new
        %w[INT TERM].each { |sig| trap(sig) { signals << sig } }
        signals
      end
    end
  end
end
