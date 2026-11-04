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
    #   bgp4r console --back-to-back
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
    # **`--back-to-back` is two bgp4r speakers in this one process**, on
    # 127.0.0.1. `self` listens on a free port and `remote`, a second
    # Console, dials it. Each has one peer, so no second loopback address
    # is needed, which macOS does not have by default. Both offer every
    # family the build gate knows, so every specimen and every fault
    # crosses with no node file, which no router here can say.
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
      --back-to-back    a second bgp4r speaker in this process, on
                        127.0.0.1, reached as remote at the prompt.
                        --peer-as is its AS (default #{Console::DEFAULT_AS + 1}),
                        --port the port we listen on (default a free one)
      --families LIST   with --back-to-back, the families both offer:
                        ipv4, ipv6, or names from BGP::Specimen.families,
                        comma separated (default every one)
  -l, --log FILE        log file, - for standard output. The default is a
                        file in the temporary folder, named when it opens
  -d, --debug           log every message too
  -h, --help            this help
TEXT

      DEFAULT_TIMEOUT = 30

      # The remote side of --back-to-back, when the flags name nothing.
      REMOTE_AS = Console::DEFAULT_AS + 1
      REMOTE_ID = '10.0.0.2'
      LOOPBACK = '127.0.0.1'

      # The remote logger's levels, BGP::Logging::LEVELS as Logger's.
      SEVERITY = { :debug => Logger::DEBUG, :info => Logger::INFO, :warn => Logger::WARN,
                   :error => Logger::ERROR, :fatal => Logger::FATAL }.freeze

      # The families with an IPv6 form as well as the IPv4 one
      # BGP::Specimen.families names. RT-constrain has none: RFC 4684
      # section 4 gives it AFI 1 only. EVPN and BGP-LS have one AFI each,
      # 25 and 16388, and the specimen list carries it.
      IPV6 = %i[unicast multicast labelled mcast_vpn vpn vpn_multicast
                flow_spec flow_spec_vpn].freeze

      # Every [name, afi, safi] --back-to-back can offer.
      def self.families
        BGP::Specimen.families.flat_map do |name, afi, safi|
          IPV6.include?(name) ? [[name, afi, safi], [name, 2, safi]] : [[name, afi, safi]]
        end
      end

      # The capabilities both sides offer: a 4-octet AS, ROUTE-REFRESH so
      # `refresh` works, and one MBGP capability per family left after
      # list, the words of --families. nil is every family.
      def self.capabilities(list = nil)
        fams = families
        if list
          words = list.split(',').collect(&:strip).reject(&:empty?)
          raise ArgumentError, '--families names nothing' if words.empty?
          names = fams.collect(&:first).uniq
          fams = words.flat_map do |w|
            case w
            when 'ipv4' then fams.select { |f| f[1] == 1 }
            when 'ipv6' then fams.select { |f| f[1] == 2 }
            else
              unless names.include?(w.to_sym)
                raise ArgumentError, "--families: no family #{w}. The words are ipv4, ipv6, " +
                                     names.join(', ')
              end
              fams.select { |f| f[0] == w.to_sym }
            end
          end.uniq
        end
        ['as4_byte', 'route_refresh'] + fams.collect { |_, afi, safi| { 'mbgp' => [afi, safi] } }
      end

      attr_reader :console

      # arg[:console] builds the Console and arg[:interact] opens the
      # prompt on it. Both are seams for a test, which must never reach
      # irb: irb reads standard input, so a refusal that fell through to
      # it would hang the suite rather than fail it.
      def initialize(out = $stdout, err = $stderr, arg = {})
        @out = out
        @err = err
        @new_console = arg[:console] || ->(*a) { Console.new(nil, @out, Console::KEEP, a[0] || {}) }
        @remote_logger = arg[:remote_logger]
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
        b2b = back_to_back_args(opts)
        Console.load_irb if @load_irb
        setup_log(opts)
        @console = @new_console.call
        if b2b
          back_to_back(opts, b2b)
        elsif args
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
        @remote.stop if @remote
        @console.stop if @console
      end

      # What `--peer` and its flags hand to `Console#connect`, or nil with
      # no `--peer`.
      def connect_args(opts)
        if opts[:peer_as] && !opts[:peer] && !opts[:back_to_back]
          raise ArgumentError, '--peer-as needs --peer'
        end
        return nil unless opts[:peer]
        raise ArgumentError, '--peer needs --peer-as' unless opts[:peer_as]
        raise ArgumentError, '--peer and --back-to-back: one or the other' if opts[:back_to_back]
        kw = { :remote_as => Integer(opts[:peer_as]),
               :local_as  => Integer(opts[:my_as] || Console::DEFAULT_AS),
               :router_id => opts[:id] || Console::DEFAULT_ID,
               :wait      => Float(opts[:timeout] || DEFAULT_TIMEOUT) }
        kw[:port] = Integer(opts[:port]) if opts[:port]
        kw[:local_address] = opts[:local_address] if opts[:local_address]
        [opts[:peer], kw]
      end

      # What --back-to-back hands to `listen` on our side and to
      # `connect` on the remote one, as [near, remote] keyword Hashes, or
      # nil without it. Both on 127.0.0.1, so each has one peer.
      #
      # **eBGP unless the two AS numbers are equal**, which is how a
      # router reads it too: --my-as 65001 --peer-as 65001 is iBGP.
      def back_to_back_args(opts)
        if opts[:families] && !opts[:back_to_back]
          raise ArgumentError, '--families needs --back-to-back'
        end
        return nil unless opts[:back_to_back]
        if opts[:local_address]
          raise ArgumentError, '--local-address with --back-to-back: both ends are on 127.0.0.1'
        end
        caps = ConsoleCommand.capabilities(opts[:families])
        mine = Integer(opts[:my_as] || Console::DEFAULT_AS)
        theirs = Integer(opts[:peer_as] || REMOTE_AS)
        port = Integer(opts[:port] || free_port)
        wait = Float(opts[:timeout] || DEFAULT_TIMEOUT)
        near = { :remote_as => theirs, :local_as => mine,
                 :router_id => opts[:id] || Console::DEFAULT_ID,
                 :port => port, :local_address => LOOPBACK,
                 :capabilities => caps, :wait => 0 }
        remote = { :remote_as => mine, :local_as => theirs,
                   :router_id => opts[:id] == REMOTE_ID ? Console::DEFAULT_ID : REMOTE_ID,
                   :port => port, :capabilities => caps, :wait => wait }
        [near, remote]
      end

      # The remote Console, once --back-to-back has built it.
      attr_reader :remote

      private

      # Our side listens and the remote side dials. Listening first, with
      # no wait, so the remote's dial finds the port open.
      def back_to_back(opts, b2b)
        @console.listen(LOOPBACK, **b2b[0])
        logger = @remote_logger || remote_logger(opts)
        factory = ->(config) { Injector.new(config, :logger => logger) }
        @remote = @new_console.call(:factory => factory, :name => 'remote')
        @console.remote = @remote
        row = @remote.connect(LOOPBACK, **b2b[1])
        @out.puts "console: back to back on #{LOOPBACK} port #{b2b[0][:port]}, " \
                  "AS #{b2b[0][:local_as]} to AS #{b2b[0][:remote_as]}, " \
                  "#{b2b[0][:local_as] == b2b[0][:remote_as] ? 'iBGP' : 'eBGP'}, " \
                  "session #{row[:state].to_s.downcase}. remote is the other side."
      end

      # A port nothing holds right now. Closed before the listen takes it,
      # so something else could get there first; the listen then says the
      # port is taken and --port picks another.
      def free_port
        require 'socket'
        s = ::TCPServer.new(LOOPBACK, 0)
        s.addr[1]
      ensure
        s.close if s
      end

      # The remote side's own log, beside ours: the same name with
      # -remote before the extension, or standard output with a prefix
      # when -l is -. Its own Logger, so the level is set once, here.
      def remote_logger(opts)
        if opts[:log] == '-'
          io = $stdout
          prefix = 'remote '
        else
          path = opts[:log].sub(/(\.[^.\/]*)?\z/) { "-remote#{$1}" }
          io = File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o640)
          io.sync = true
          @out.puts "console: the remote side logs to #{path}"
          prefix = ''
        end
        lg = Logger.new(io)
        lg.level = opts[:debug] ? Logger::DEBUG : Logger::INFO
        ->(level, message) { lg.add(SEVERITY.fetch(level), "#{prefix}#{message}") }
      end

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
          o.on('--back-to-back') { opts[:back_to_back] = true }
          o.on('--families LIST') { |v| opts[:families] = v }
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
