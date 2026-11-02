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

module BGP
  module Sim

    # `bgp4r routegen`: one session, a generated range, a report, exit.
    #
    #   bgp4r routegen examples/sim.yml
    #   bgp4r routegen --peer 10.0.0.2 --peer-as 65002 --count 200000 --per-update 127
    #
    # **It is the third way into one implementation and not a second
    # one**, which docs/daemon.md states as a requirement: the generator
    # is reachable as the `generate` block of `POST /api/announce`, as
    # this subcommand, and as a node file's `announce` block, with
    # `BGP::RouteGenerator` under all three. So this builds an announce
    # body and hands it to `Injector#act`, which is the same code path
    # the HTTP action takes, with async off so it blocks and can
    # report what it did.
    #
    # **The node file's `announce` blocks are moved out of the config and
    # run as actions**, which reads like a detour and is the opposite:
    # `Speaker#announce` sends `announcements` by itself on every
    # establishment, so leaving them in would send each block twice, once
    # by the Speaker and once here, and the report would count one of
    # them. Moving them is what keeps one implementation and one count.
    #
    # **`examples/routegen` is untouched and keeps working.** Its YAML is
    # its own format, with `neighbor:` and `routes:` sections and loosely
    # matched key names, and it has its own loader for them. This reads
    # the **node file**, which is the one vocabulary docs/daemon.md and
    # `lab/README.md` document for every other bgp4r program, so there is
    # one thing to learn here and the old script stays for whoever has
    # the old file. docs/daemon.md's example named `examples/routegen.yml`
    # and now names `examples/sim.yml`, which is a node file.
    class Routegen

      # Where a generated range starts with no `--start`. Every example
      # in the repository uses it, `lab/README.md`'s generate block and
      # docs/daemon.md's both, so it is the number a reader expects
      # rather than one invented here.
      DEFAULT_START = '11.0.0.0/28'
      DEFAULT_ID    = '10.0.0.1'
      DEFAULT_AS    = 65_001

      USAGE = <<-TEXT
Usage: bgp4r routegen FILE [options]
       bgp4r routegen --peer ADDR --peer-as AS [options]

FILE is a bgp4r node file, as bgp4r-sim reads: see docs/daemon.md. Its
announce blocks are sent once and then this exits. With no file, the
flags below build one in memory.

      --peer ADDR       the peer to dial (required with no FILE)
      --peer-as AS      the peer AS (required with no FILE)
      --my-as AS        our AS (default #{DEFAULT_AS})
      --id ID           our router id (default #{DEFAULT_ID})
      --port PORT       the peer's port (default 179)
      --local-address A the address to dial from
      --start PREFIX    the first prefix (default #{DEFAULT_START})
      --count N         how many prefixes (default 1)
      --per-update N    prefixes per UPDATE (default 1)
      --next-hop ADDR   NEXT_HOP (default our address on the session)
      --med N           MULTI_EXIT_DISC
      --as-path "A B"   ASes after our own
      --communities "X" communities, as "100:1 200:1"
      --timeout SECS    how long to wait for the session (default 30)
      --keep            keep the session up until Ctrl-C
  -l, --log FILE        log file, - for standard output
  -d, --debug           log every message too
  -h, --help            this help

ROUTEGEN_COUNT and ROUTEGEN_PER_UPDATE override count and per_update of
every generate block, which is how one lab run changes the feed size.
TEXT

      attr_reader :injector

      def initialize(out = $stdout, err = $stderr)
        @out = out
        @err = err
      end

      def start(argv, env = ENV)
        opts = parse(argv)
        return 0 if opts[:help]
        return 1 if opts[:error]
        config, blocks = plan(opts, env)
        return 1 if config.nil?
        run(config, blocks, opts)
      rescue Injector::Refused, ArgumentError, KeyError, SystemCallError => e
        @err.puts "routegen: #{e.message}"
        1
      end

      # The node file and the announce blocks taken out of it, or the
      # pair the flags describe.
      def plan(opts, env = ENV)
        if opts[:config]
          require 'yaml'
          config = YAML.safe_load(File.read(opts[:config]))
          unless config.is_a?(Hash)
            @err.puts "routegen: #{opts[:config]} is not a YAML mapping"
            return [nil, nil]
          end
          blocks = Array(config['announce'])
          if blocks.empty?
            @err.puts "routegen: #{opts[:config]} has no announce block, so there is " \
                      'nothing to send. Add one, or use the flags.'
            return [nil, nil]
          end
          [config.reject { |k, _v| k == 'announce' }, blocks]
        else
          [from_flags(opts, env), [generate_block(opts)]]
        end
      rescue Errno::ENOENT
        @err.puts "routegen: #{opts[:config]}: no such file"
        [nil, nil]
      rescue Psych::SyntaxError => e
        @err.puts "routegen: #{opts[:config]}: #{e.message}"
        [nil, nil]
      end

      private

      def from_flags(opts, _env)
        unless opts[:peer] && opts[:peer_as]
          raise Injector::Refused, 'give a node file, or --peer ADDR and --peer-as AS'
        end
        neighbor = { 'address' => opts[:peer], 'as' => Integer(opts[:peer_as]),
                     'connect' => true }
        neighbor['port'] = Integer(opts[:port]) if opts[:port]
        config = { 'router_id' => opts[:id] || DEFAULT_ID,
                   'as' => Integer(opts[:my_as] || DEFAULT_AS),
                   'neighbors' => [neighbor] }
        config['local_address'] = opts[:local_address] if opts[:local_address]
        config
      end

      def generate_block(opts)
        block = { 'generate' => { 'start' => opts[:start] || DEFAULT_START,
                                  'count' => Integer(opts[:count] || 1),
                                  'per_update' => Integer(opts[:per_update] || 1) } }
        block['next_hop'] = opts[:next_hop] if opts[:next_hop]
        block['med'] = Integer(opts[:med]) if opts[:med]
        block['as_path'] = opts[:as_path].to_s.split.collect { |a| Integer(a) } if opts[:as_path]
        block['communities'] = opts[:communities].to_s.split if opts[:communities]
        block
      end

      def run(config, blocks, opts)
        setup_log(opts, config)
        @injector = Injector.new(config)
        @injector.start
        peer = wait_for_a_session(opts)
        return 1 if peer.nil?
        @out.puts "routegen: session to #{peer.address} up"
        blocks.each { |b| send_block(b) }
        # **Before the report and before the stop**, because
        # `send_message` queues and stopping drops what is still queued:
        # see `Injector#drain`, which this found by losing the last
        # UPDATE of every range.
        @err.puts 'routegen: the session did not take everything' unless @injector.drain
        report
        keep(opts) if opts[:keep]
        0
      ensure
        @injector.stop if @injector
      end

      # One block, through the action, so what this sends is what
      # `POST /api/announce` sends.
      def send_block(block)
        answer = @injector.act('announce', block, false)
        return unless answer[:feeds]
        answer[:feeds].each do |f|
          @err.puts "routegen: feed #{f[:id]} failed: #{f[:error]}" if f[:error]
        end
      end

      def report
        s = @injector.sent.summary
        @injector.sent.feeds.each do |f|
          @out.puts format('routegen: %s, %d prefixes in %d updates%s',
                           f[:range], f[:prefixes_sent], f[:updates_sent],
                           f[:prefixes_per_second] ? format(', %.1f prefixes/s',
                                                            f[:prefixes_per_second]) : '')
        end
        @out.puts format('routegen: %d prefixes in %d updates, %s to %s',
                         s[:prefixes_sent], s[:updates_sent],
                         s[:started_at], s[:finished_at])
      end

      def wait_for_a_session(opts)
        deadline = Time.now + Float(opts[:timeout] || 30)
        loop do
          peer = @injector.speaker.established_peers.first
          return peer if peer
          if Time.now > deadline
            states = @injector.speaker.peers.collect { |p| "#{p.address} #{p.state.downcase}" }
            @err.puts "routegen: no session after #{opts[:timeout] || 30}s: #{states.join(', ')}"
            return nil
          end
          sleep 0.1
        end
      end

      def keep(_opts)
        @out.puts 'routegen: session up, press Ctrl-C to stop'
        stop = false
        %w[INT TERM].each { |sig| trap(sig) { stop = true } }
        sleep 0.2 until stop || @injector.speaker.established_peers.empty?
      end

      def setup_log(opts, config)
        io = if opts[:log].nil? || opts[:log] == '-'
               $stdout
             else
               File.open(opts[:log], File::WRONLY | File::APPEND | File::CREAT, 0o640)
             end
        io.sync = true if io.respond_to?(:sync=)
        Log.set_filename(io)
        Log.level = opts[:debug] ? Logger::DEBUG : Daemon::Speaker.log_level(config)
      end

      # OptionParser, lazily required, which is `bgp/capture/cli.rb`'s
      # arrangement: `optparse` is a default gem today and Conventions
      # says to check that before requiring one, so the require sits in
      # the one method that needs it. Answers nil when it printed help.
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
          o.on('--start PREFIX') { |v| opts[:start] = v }
          o.on('--count N') { |v| opts[:count] = v }
          o.on('--per-update N') { |v| opts[:per_update] = v }
          o.on('--next-hop ADDR') { |v| opts[:next_hop] = v }
          o.on('--med N') { |v| opts[:med] = v }
          o.on('--as-path PATH') { |v| opts[:as_path] = v }
          o.on('--communities LIST') { |v| opts[:communities] = v }
          o.on('--timeout SECS') { |v| opts[:timeout] = v }
          o.on('--keep') { opts[:keep] = true }
          o.on('-l', '--log FILE') { |v| opts[:log] = v }
          o.on('-d', '--debug') { opts[:debug] = true }
          o.on('-h', '--help') { opts[:help] = true }
        end
        rest = parser.parse(argv)
        @out.print USAGE if opts[:help]
        opts[:config] = rest.first if rest.first
        opts
      rescue OptionParser::ParseError => e
        @err.puts "routegen: #{e.message}"
        @err.print USAGE
        { :error => true }
      end

    end

  end
end
