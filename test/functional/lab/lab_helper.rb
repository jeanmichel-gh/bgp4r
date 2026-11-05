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

# Helpers for lab tests: run speakers, read their state files, wait.
#
# Compose runs a topology from lab/topologies/<name>/compose.yml.
# Local runs lab/speaker.rb as plain processes on loopback, no Docker.
# Gobgpd runs a real router the same way, also no Docker, and Frr runs
# FRR's bgpd standalone for a second opinion.

require 'json'
require 'open3'
require 'rbconfig'
require 'socket'
require 'timeout'
require 'tmpdir'
require 'fileutils'
require 'yaml'

module LabHelper
  ROOT = File.expand_path('../../..', __dir__)
  STATE_FILE = '/tmp/bgp4r-state.json'

  class Compose
    # True when the compose plugin is installed and the daemon answers.
    def self.available?
      [%w[docker compose version], %w[docker info]].all? do |cmd|
        _, status = Open3.capture2e(*cmd)
        status.success?
      end
    rescue SystemCallError
      false
    end

    # env: extra environment for docker compose, e.g. ROUTEGEN_COUNT. The
    # compose file passes the variables it names on to the containers.
    def initialize(topology, env: {})
      @file = File.join(ROOT, 'lab', 'topologies', topology, 'compose.yml')
      @env = env.to_h { |k, v| [k.to_s, v.to_s] }
    end

    def up ; compose('up', '--detach', '--build') ; end
    def down ; compose('down', '--volumes', '--remove-orphans', '--timeout', '5') ; end

    # For a topology whose point is one container running to completion:
    # runs in the foreground until service exits and returns [output,
    # that service's exit status]. Never raises on a non-zero status, the
    # status is the answer.
    def up_until_exit(service, timeout: 900)
      out, status = Timeout.timeout(timeout) do
        Open3.capture2e(@env, 'docker', 'compose', '-f', @file, 'up', '--build',
                        '--abort-on-container-exit', '--exit-code-from', service)
      end
      [out, status.exitstatus]
    end

    # Copies a file out of a service's container into dir. Works after
    # the container has exited, which is when a one-shot run is read.
    def cp(service, path, dir)
      compose('cp', "#{service}:#{path}", dir)
    end

    def stop(node) ; compose('stop', '--timeout', '5', node) ; end
    def start(node) ; compose('start', node) ; end
    def logs ; compose('logs', '--no-color', check: false) ; end

    # The node's state as written by lab/speaker.rb, or nil if not there yet.
    def state(node)
      JSON.parse(compose('exec', '-T', node, 'cat', STATE_FILE, check: false))
    rescue JSON::ParserError
      nil
    end

    private

    def compose(*args, check: true)
      out, status = Open3.capture2e(@env, 'docker', 'compose', '-f', @file, *args)
      raise "docker compose #{args.join(' ')} failed:\n#{out}" if check && !status.success?
      out
    end
  end

  class Local
    # nodes: name => speaker config (a Hash). state_file is filled in here.
    # env: extra environment for every speaker process, e.g. LAB_LOG_LEVEL.
    def initialize(nodes, env: {})
      @env = env
      @dir = Dir.mktmpdir('bgp4r-lab')
      @nodes = nodes.to_h { |name, conf| [name, conf.merge('state_file' => File.join(@dir, "#{name}.json"))] }
      @pids = {}
    end

    # A port nothing is listening on, on the address the caller is about
    # to bind. **This is time-of-check to time-of-use and cannot be made
    # otherwise**: the socket has to be closed before the port can be
    # handed to a child process, and anything may take it in between.
    # So a caller that spawns a daemon has to survive losing the race,
    # which is what Gobgpd#up's retry is for.
    #
    # The host argument is not decoration. Binding 0 on 127.0.0.1 asks
    # the kernel for a port free **there**, and gobgpd's API listens on
    # 127.0.0.2, so the probe was answering a different question than
    # the one its caller asked. Found on 2026-10-31 when CI failed with
    # "listen tcp 127.0.0.2:37903: bind: address already in use".
    def self.free_port(host = '127.0.0.1')
      s = TCPServer.new(host, 0)
      s.addr[1]
    ensure
      s.close if s
    end

    def up ; @nodes.each_key { |n| start(n) ; sleep 0.3 } ; end

    def down
      @pids.each_key { |n| stop(n) }
      FileUtils.rm_rf(@dir)
    end

    def start(node)
      conf = File.join(@dir, "#{node}.yml")
      File.write(conf, @nodes.fetch(node).to_yaml)
      log = File.join(@dir, "#{node}.log")
      # One open file for both streams. out: log, err: log opened it twice,
      # and lines from stderr overwrote lines from stdout.
      @pids[node] = Process.spawn(@env, RbConfig.ruby, File.join(ROOT, 'lab', 'speaker.rb'), conf,
                                  out: log, err: [:child, :out])
    end

    def stop(node)
      pid = @pids.delete(node) or return
      Process.kill('TERM', pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
    end

    def log(node)
      File.read(File.join(@dir, "#{node}.log"))
    rescue Errno::ENOENT
      ''
    end

    def logs
      Dir[File.join(@dir, '*.log')].sort.map { |f| "== #{File.basename(f)}\n#{File.read(f)}" }.join("\n")
    end

    def state(node)
      JSON.parse(File.read(@nodes.fetch(node)['state_file']))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end
  end

  # A real router as a plain process on loopback, no Docker. GoBGP is the
  # one implementation in the lab that needs no privilege and no container
  # to peer with bgp4r, so a test can have a second implementation's
  # opinion wherever the binary is installed.
  #
  # docs/protocol-testing.md runs one by hand on the standard port, with
  # lab/conformance/gobgpd.conf. This writes its own config instead, on
  # ports of its own, for two reasons: a test must not collide with a
  # daemon somebody is already running, and neither side then needs root
  # or net.ipv4.ip_unprivileged_port_start to use port 179. GoBGP listens
  # on 179 by default even when it only dials out, so the generated config
  # moves that too.
  #
  # GOBGPD and GOBGP name the binaries when they are not on PATH.
  class Gobgpd
    def self.bin ; ENV['GOBGPD'] || 'gobgpd' ; end
    def self.client ; ENV['GOBGP'] || 'gobgp' ; end

    # The daemon's own version line, or nil when it is not installed.
    def self.version
      out, status = Open3.capture2e(bin, '--version')
      status.success? ? out.strip : nil
    rescue SystemCallError
      nil
    end

    def self.available? ; !version.nil? ; end

    # The major version, which is what a conformance expectation turns on:
    # GoBGP 4 fixed a case GoBGP 3 answers with a session reset. nil when
    # the daemon is missing or its version line does not parse, and a
    # caller that cannot name the version must not guess at the answers.
    def self.major
      v = version or return nil
      v[/\bversion\s+v?(\d+)\./, 1]&.to_i
    end

    # listen_port is the daemon's own BGP port, which is what
    # fault_matrix.rb --dial needs. Frr exposes it too.
    attr_reader :local, :as, :router_id, :peer, :peer_as, :port, :listen_port

    # The flow spec families, by the name the **config file** wants.
    #
    # **The config and the client disagree about these names in 3.23.0**,
    # measured on 2026-10-30 and not a typo here: the config file takes
    # `l3vpn-ipv4-flowspec` and rejects `ipv4-l3vpn-flowspec` with
    # "isn't a valid route family name", while the client takes
    # `ipv4-l3vpn-flowspec` and rejects the other with "unsupported
    # address family". So a VPN flow spec test needs both spellings, and
    # CLIENT_FAMILY below maps one to the other. The two unicast families and
    # the two plain flow spec ones are spelled alike on both sides.
    FS_IPV4 = 'ipv4-flowspec'
    FS_IPV6 = 'ipv6-flowspec'
    FS_VPN  = 'l3vpn-ipv4-flowspec'

    # EVPN, AFI 25 SAFI 70, and **the same disagreement again**: the
    # config file takes `l2vpn-evpn` and the client takes `evpn`,
    # rejecting the other with "unsupported address family: l2vpn-evpn".
    # Measured on 2026-10-30. So this is the second family where the two
    # sides of GoBGP 3.23.0 spell one thing two ways, which is why the
    # map below is no longer flow spec's alone.
    EVPN = 'l2vpn-evpn'

    # RT-constrain, AFI 1 SAFI 132, RFC 4684. **The two sides agree on
    # this one**, measured on 2026-10-31: the config file and the client
    # both take `rtc`, and the client rejects `ipv4-rtc`,
    # `route-target-constraints`, `rtfilter` and `ipv4-rtfilter` with
    # "unsupported address family". So this family needs no CLIENT_FAMILY
    # entry, which is worth saying because the two families above set the
    # expectation that it would. Checked rather than assumed, after a
    # first draft of the CLAUDE.md entry guessed the name and was wrong.
    RTC = 'rtc'

    # BGP-LS, AFI 16388 SAFI 71, RFC 9552. **The two sides agree on the
    # name and the client takes a second one**, measured on 2026-11-01,
    # which is a third shape after "they disagree" and "they agree": the
    # config file takes only `ls`, and the client takes `ls` **and**
    # `linkstate`. So this needs no CLIENT_FAMILY entry either, and a
    # reader who meets `linkstate` in client output is looking at this
    # family and not a second one.
    #
    # There is **no name for SAFI 72** on either side: the config
    # refuses `ls-vpn` and every other spelling tried, and a live
    # session reads the pair back as `UnknownFamily(1074004040)`. See
    # link_state_gobgp_test.rb.
    LS = 'ls'

    # Labelled unicast, SAFI 4, and the disagreement a third time: the
    # config file takes `ipv4-labelled-unicast` and the client refuses it
    # with "unsupported address family", taking `ipv4-mpls` or
    # `ipv4-labelled`. Measured on 2026-11-03 against 3.23.0, and the
    # same for IPv6.
    LABELLED_IPV4 = 'ipv4-labelled-unicast'
    LABELLED_IPV6 = 'ipv6-labelled-unicast'

    # Multicast, SAFI 2. The config file takes `ipv4-multicast` and
    # `ipv6-multicast` and a session negotiates them, and **the client
    # has no table for either**: `global rib` and `neighbor adj-in` both
    # answer "unsupported address family: ipv4-multicast", under every
    # spelling, and the log says nothing about the routes. So GoBGP
    # 3.23.0 can say a multicast feed did not reset the session and
    # cannot say what it read. Measured on 2026-11-03; gen_gobgp_test.rb
    # asserts it, so a GoBGP that grows the table fails there.
    MULTICAST_IPV4 = 'ipv4-multicast'
    MULTICAST_IPV6 = 'ipv6-multicast'

    # Labeled VPN, SAFI 128, and the disagreement a fourth time: the
    # config file takes `l3vpn-ipv4-unicast` and the client refuses it,
    # taking `vpnv4` or `ipv4-l3vpn`. The table is keyed by RD and
    # prefix, and prints a 4-octet AS RD in asdot, `64086.59904:4`,
    # where the NLRI's own `rd` object says 4200000000. Measured on
    # 2026-11-04 against 3.23.0, and the same for IPv6.
    VPN_IPV4 = 'l3vpn-ipv4-unicast'
    VPN_IPV6 = 'l3vpn-ipv6-unicast'

    # Labeled VPN Multicast, SAFI 129. **Negotiated and then refused**:
    # the session lists `l3vpn-ipv4-multicast` as advertised and
    # received, and the first UPDATE in it is logged as "unknown route
    # family. AFI: 1, SAFI: 129" with "Capability was disabled", the
    # session staying up. The client has no name for the family under
    # any spelling tried. Measured on 2026-11-04; gen_gobgp_test.rb
    # asserts it.
    VPN_MULTICAST_IPV4 = 'l3vpn-ipv4-multicast'

    # Config-file name to client name, for the families where the two
    # disagree. Everything else is spelled alike on both sides, RTC and
    # LS included.
    CLIENT_FAMILY = { FS_VPN => 'ipv4-l3vpn-flowspec', EVPN => 'evpn',
                      LABELLED_IPV4 => 'ipv4-mpls', LABELLED_IPV6 => 'ipv6-mpls',
                      VPN_IPV4 => 'vpnv4', VPN_IPV6 => 'vpnv6' }.freeze

    # The name to pass the client's -a for a family, which is its own
    # name except where the two disagree.
    def self.client_family(name) ; CLIENT_FAMILY[name] || name ; end

    # local:    address the router speaks from
    # peer:     address bgp4r listens on, which the router dials
    # port:     port bgp4r listens on, which the router dials
    # add_path: {receive: true, send_max: 8} for RFC 7911, or nil for none
    # families: extra afi-safi names beyond the two unicast ones, such as
    #           FS_IPV4. Empty by default, so a config with none is what
    #           it always was.
    # peer2:    a second neighbor as {address:, as:, port:}, or nil for
    #           none. **What it is for**: a router with one peer can only
    #           say what it made of what we sent, where a router with two
    #           carries a route from one bgp4r speaker to another, so the
    #           far side reads what crossed a real implementation. That
    #           is what attr_set_gobgp_test.rb needs, since ATTR_SET
    #           exists so a customer's attributes survive transit (RFC
    #           6368 section 5) and nothing but a transit router can say
    #           whether they do. nil by default, and the config a caller
    #           without it gets is byte for byte what it always was,
    #           which test/unit/lab_helper_test.rb pins.
    def initialize(local: '127.0.0.2', as: 65002, router_id: '10.0.0.2',
                   peer: '127.0.0.1', peer_as: 65001, port: nil, ipv6: true,
                   add_path: nil, families: [], peer2: nil)
      @local, @as, @router_id = local, as, router_id
      @peer, @peer_as, @ipv6 = peer, peer_as, ipv6
      @add_path = add_path
      @families = families
      @peer2 = peer2
      @port = port || Local.free_port
      pick_ports
      @dir = Dir.mktmpdir('bgp4r-gobgpd')
    end

    # The two ports this daemon binds, both on its own address. @port is
    # not picked here: it is the **peer's** port, usually the bgp4r
    # listener the caller already opened, so re-picking it on a retry
    # would point the daemon at nothing.
    def pick_ports
      @listen_port = Local.free_port(@local)
      @api_port = Local.free_port(@local)
    end
    private :pick_ports

    def config
      global = <<~TOML
        [global.config]
          as = #{@as}
          router-id = "#{@router_id}"
          local-address-list = ["#{@local}"]
          # Its own listening port, so the daemon needs no privilege. It
          # only dials out here; GoBGP would still bind 179 without this.
          port = #{@listen_port}

      TOML
      out = global + neighbor_block(@peer, @peer_as, @port)
      # A second neighbor, when one was asked for, so the daemon carries
      # a route between two bgp4r speakers. Appended whole after the
      # first one's sub-tables, which is where TOML puts the next
      # [[neighbors]] element.
      out += "\n" + neighbor_block(@peer2[:address], @peer2[:as], @peer2[:port]) if @peer2
      out
    end

    # One [[neighbors]] element: its config, transport, timers, the
    # afi-safis every neighbor here gets, and the add-paths block when
    # one was asked for. Extracted from `config` so a second neighbor is
    # a second call rather than a second copy of the TOML.
    def neighbor_block(address, peer_as, remote_port)
      families = ['ipv4-unicast']
      families << 'ipv6-unicast' if @ipv6
      families += @families
      afi_safis = families.collect { |f|
        "  [[neighbors.afi-safis]]\n" \
        "    [neighbors.afi-safis.config]\n" \
        "      afi-safi-name = \"#{f}\"\n"
      }.join
      block = <<~TOML
        [[neighbors]]
          [neighbors.config]
            neighbor-address = "#{address}"
            peer-as = #{peer_as}
          [neighbors.transport.config]
            local-address = "#{@local}"
            # Where bgp4r listens, so our side needs no privilege either.
            remote-port = #{remote_port}
          [neighbors.timers.config]
            # These ask the router to come back quickly, for a caller
            # that gives each case its own session. **GoBGP 3.23.0
            # ignores both.** Measured on 2026-10-31: asking for
            # connect-retry 30 instead of 2 does not change the 10 to
            # 14s it takes to dial back, and asking for
            # idle-hold-time-after-reset 30 instead of 0 does not
            # change the 5s it holds a session down before it will
            # finish an OPEN. Reproduced with a bare TCPServer, so it
            # is not the harness.
            #
            # They stay because they cost nothing and say what is
            # wanted, and a later GoBGP may honour them. What they do
            # not do is make a session per case cheap: that is what
            # fault_matrix.rb --dial is for.
            connect-retry = 2
            idle-hold-time-after-reset = 0
      TOML
      # RFC 7911, and left out entirely when nobody asked, so a config with
      # no add-paths block is what it always was. receive lets the router
      # take several paths for one prefix from us; a send-max above 0 lets
      # it send us several. A sub-table after the afi-safis array attaches
      # to this [[neighbors]] element, which is what TOML says and what
      # GoBGP reads.
      add_paths = ''
      if @add_path
        add_paths = "  [neighbors.add-paths.config]\n" \
                    "    receive = #{@add_path.fetch(:receive, true)}\n" \
                    "    send-max = #{@add_path.fetch(:send_max, 8)}\n"
      end
      block + afi_safis + add_paths
    end
    private :neighbor_block

    # Did the daemon die because something already held a port it tried
    # to bind? Its own words, and it says them for the gRPC port and for
    # the BGP one alike:
    #
    #   {"Err":"listen tcp 127.0.0.2:37903: bind: address already in
    #    use","level":"fatal","msg":"failed to listen grpc port"}
    #
    # A predicate rather than an inline match so the unit suite can pin
    # it without a daemon, which matters because this is the half that
    # decides whether a lost race is retried or reported as a config
    # error, and the two look nothing alike to a reader of the log.
    def self.port_conflict?(text)
      text.to_s.include?('address already in use')
    end

    # Starts the daemon and waits until its API answers, which is the only
    # signal that it read the config at all. Raises with the daemon's log,
    # which names the config key it rejected.
    #
    # **Retries a lost port race, because that race cannot be removed.**
    # Local.free_port has to close its socket before the port can be
    # handed to a child, so between the probe and gobgpd's bind anything
    # may take it, and with a dozen daemons in one group something
    # eventually does: CI failed on 2026-10-31 with "listen tcp
    # 127.0.0.2:37903: bind: address already in use", in a flow spec case
    # that had not changed, because this file's new RT-constrain test
    # raised the number of daemons in the group from 3 to 12.
    #
    # Only a port conflict is retried. Every other way of not coming up
    # is a config gobgpd rejected, which is a real failure and must still
    # raise with the log that names the key.
    def up(timeout: 30, attempts: 3)
      tried = 0
      begin
        tried += 1
        start_once(timeout: timeout)
      rescue RuntimeError => e
        raise unless self.class.port_conflict?(e.message) && tried < attempts
        # Take two fresh ports, not the ones it lost. **Not `down`**,
        # which removes @dir in its ensure, so the next attempt had
        # nowhere to write its config and died with ENOENT on
        # gobgpd.conf. Measured, by squatting on the port and watching
        # the first draft of this fail that way.
        @pid = nil
        pick_ports
        retry
      end
    end

    # **Stops waiting the moment the daemon dies**, rather than polling a
    # process that is already gone until the timeout. gobgpd exits at
    # once on a port conflict and on a config key it rejects, so without
    # this every such failure costs the full 30s and a retry costs three
    # of them. It also makes the message true: "did not come up in 30s"
    # was wrong about a daemon that had been dead for 29 of them.
    def start_once(timeout: 30)
      path = File.join(@dir, 'gobgpd.conf')
      File.write(path, config)
      @log = File.join(@dir, 'gobgpd.log')
      @pid = Process.spawn(self.class.bin, '-f', path, '--api-hosts', "#{@local}:#{@api_port}",
                           out: @log, err: [:child, :out])
      deadline = Time.now + timeout
      until neighbors
        if exited?
          raise "gobgpd exited without coming up:\n#{log}"
        elsif Time.now > deadline
          raise "gobgpd did not come up in #{timeout}s:\n#{log}"
        end
        sleep 0.5
      end
      self
    end
    private :start_once

    # True once the child is gone, reaping it so down has nothing to
    # wait for. Answers false while it runs and on a pid already reaped.
    def exited?
      return false unless @pid
      !Process.wait(@pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end
    private :exited?

    def down
      @log_text = log
      if @pid
        Process.kill('TERM', @pid)
        Process.wait(@pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
    ensure
      @pid = nil
      FileUtils.rm_rf(@dir)
    end

    # Runs the client against this daemon and answers [output, status].
    #
    # The readers below cover what a test usually wants from the RIB.
    # This is for the one thing they cannot do, which is make the router
    # **originate** something: `gobgp global rib add` is how a test gets
    # a second implementation's encoder to feed bgp4r's decoder, and
    # until BGP-LS no family here could be measured in that direction at
    # all. It answers the status rather than nil on failure, because a
    # caller asserting on a refusal wants the client's own words.
    def client_run(*args)
      Open3.capture2e(self.class.client, '-u', @local,
                      '-p', @api_port.to_s, *args)
    end

    # The client's neighbor table, or nil while the daemon is not answering.
    def neighbors
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'neighbor')
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end

    # One neighbor's detail, as the client prints it for a person.
    def neighbor(address)
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'neighbor', address)
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end

    # What the router made of the ADD-PATH Send/Receive field its peer
    # advertised for one family: "receive", "send" or "receive/send". nil
    # when it reports no remote add-path at all, which is the answer when
    # the capability was never negotiated.
    #
    # This is the only way to see a second implementation's reading of that
    # field, and bgp4r had it inverted until #115, so it is worth the one
    # brittle thing in this class: it parses the client's human output,
    # because the JSON form wraps every capability in a protobuf Any with a
    # base64 value and decoding that by hand would be worse. The layout is
    # therefore not contractual. If a GoBGP release rewords this block the
    # parse returns nil and the test says so, and that is a test to update
    # rather than a bgp4r bug.
    def remote_add_path(address, family = 'ipv4-unicast')
      text = neighbor(address) or return nil
      block = text[/add-path:.*?Remote:\s*\n(.*?)(?:\n\s*[a-z-]+:|\z)/m, 1] or return nil
      block[/#{Regexp.escape(family)}:\s*(\S+)/, 1]
    end

    # What to pass lab/fault_matrix.rb as --rib-command: one argument,
    # spaces and all, since the matrix runs it through a shell.
    def rib_command
      "#{self.class.client} -u #{@local} -p #{@api_port} global rib"
    end

    # The router's RIB, parsed: prefix => array of paths. nil while the
    # daemon is not answering. An empty RIB answers {}, which is a real
    # answer and not the same as nil, so a caller can tell "nothing there"
    # from "could not ask".
    #
    # This is what a test asserts a bgp4r UPDATE against, because it is the
    # router's own reading of what we sent rather than ours.
    def rib
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'global', 'rib', '-j')
      return nil unless status.success?
      JSON.parse(out)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # One path out of that RIB for a prefix, or nil. Picks the best path,
    # since a prefix with one path has that one marked best.
    def path(prefix)
      paths = (rib || {})[prefix] or return nil
      paths.find { |p| p['best'] } || paths.first
    end

    # The RIB for one family, which is what a flow spec test asks for,
    # since `global rib` with no -a answers for IPv4 unicast only.
    #
    # The keys are the router's own rendering of each rule rather than a
    # prefix, which is the whole reason this is worth asserting: GoBGP
    # prints `[destination: 192.0.2.0/24][protocol: ==tcp][port: ==25]`
    # for the rule of RFC 8955 section 4.3.1, so the key is a second
    # implementation reading our components back, protocol 6 spelled tcp
    # and all. Treat the exact text as GoBGP's and not contractual: a
    # release may reword it, and that is a test to update.
    def rib_family(family)
      out, status = Open3.capture2e(self.class.client, '-u', @local,
                                    '-p', @api_port.to_s, 'global', 'rib',
                                    '-a', self.class.client_family(family), '-j')
      return nil unless status.success?
      JSON.parse(out)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    # How many paths the router holds in one family, from `global rib
    # summary`, or nil while it is not answering. The JSON RIB is no use
    # for counting a large feed: GoBGP prints each path's MP_REACH_NLRI
    # with every prefix of the UPDATE it came in, so 2000 IPv6 routes are
    # tens of megabytes per poll. LabHelper#spec_crosses reads this.
    def path_count(family = 'ipv4')
      out, status = client_run('global', 'rib', 'summary',
                               '-a', self.class.client_family(family))
      status.success? ? out[/Path: (\d+)/, 1].to_i : nil
    rescue SystemCallError
      nil
    end

    # The one rule in that family, or nil when it holds none. Every flow
    # spec case here sends exactly one, so this saves each test naming a
    # key it would have to spell the router's way.
    def only_rule(family)
      r = rib_family(family) or return nil
      pair = r.first or return nil
      key, paths = pair
      path = paths.find { |p| p['best'] } || paths.first
      [key, path]
    end

    # The component list of a flow spec path, as the client prints it:
    # one entry per component, keyed by the RFC 8955 section 4.2 type
    # number, so an assertion names the type the RFC does. The operator
    # octet comes back whole, under 'op', which is what makes this worth
    # reading: `op => 129` is our end-of-list bit plus eq.
    def self.components(path)
      (((path['nlri'] || {})['value']) || [])
    end

    # A path's attributes keyed by their BGP attribute type code, so an
    # assertion names the code point the RFC does: 2 AS_PATH, 3 NEXT_HOP,
    # 5 LOCAL_PREF, 9 ORIGINATOR_ID and 10 CLUSTER_LIST here. The client
    # prints no attribute bgp4r did not send, so a missing key means the
    # attribute did not arrive.
    def self.attrs(path)
      (path['attrs'] || []).to_h { |a| [a['type'], a] }
    end

    # A path's AS_PATH as one flat list of AS numbers, in order. RFC 4271
    # section 4.3 gives AS_PATH as a sequence of segments, and the client
    # prints them that way, so this is the common case flattened. An empty
    # AS_PATH, which is what an internal peer gets, has no segments and
    # answers []. Read the segments themselves when the shape matters, as
    # it does for telling an AS_SEQUENCE from an AS_SET.
    def self.as_path(path)
      segments = (attrs(path)[2] || {})['as_paths'] || []
      segments.collect { |s| s['asns'] || [] }.flatten
    end

    # The daemon's own log: what it made of each UPDATE, in its words.
    # Cached at down, since the directory goes with it.
    def log
      return @log_text if @log_text
      @log ? File.read(@log) : ''
    rescue Errno::ENOENT
      ''
    end
  end

  # FRR's bgpd, run the same way: a second real router on loopback, no
  # Docker and no zebra. Shaped on Gobgpd above, so a test can hold either.
  #
  # Four things about running bgpd standalone, each measured against 8.4.4
  # rather than recalled, because each one stops it dead:
  #
  # **-S**, --skip_runas. bgpd otherwise drops to the `frr` user, and then
  # cannot write its pid file or vty socket into a directory that user
  # cannot reach, which `Dir.mktmpdir` under a private /tmp subdirectory
  # always is: it exits with "Can't create pid lock file (Permission
  # denied)". Running as the invoking user instead makes any directory
  # work. There is no --vty_group in 8.4.4 either, so -u root -g root is
  # not an answer: it fails with "user(root) is not part of vty group
  # specified(frrvty)".
  #
  # **--no_kernel**, so a BGP conformance test cannot touch the routing
  # table of the machine it runs on. bgpd without zebra installs nothing
  # anyway, and this says so rather than relying on that.
  #
  # **A vty password**, because `show` over the vty answers "Vty password
  # is not set" without one. It is in the config below; nothing here is
  # reachable off loopback.
  #
  # **No -d**, so the process this holds a pid for is the daemon itself.
  # With -d bgpd forks and the parent exits, and then there is nothing to
  # TERM at the end.
  #
  # The RIB is read with `vtysh --vty_socket <dir>`, which talks to this
  # one bgpd through the socket in its own directory and so needs no
  # system-wide FRR installation to be running.
  class Frr
    # The usual path from a distribution package, since bgpd is not on
    # PATH there. FRR_BGPD and VTYSH name them on a machine that puts them
    # elsewhere, the way GOBGPD and GOBGP do for GoBGP.
    PACKAGED = '/usr/lib/frr/bgpd'

    # The next hop to put in a test route for this router, which is **not**
    # the peer's address the way it can be for GoBGP.
    #
    # Measured, one clean route per candidate: with a next hop of
    # 127.0.0.1 FRR keeps the session up and silently drops the route, so
    # `show bgp ipv4 unicast` never mentions it. With 192.0.2.1 it keeps
    # the route and even selects it, with no zebra to resolve the next hop
    # and nothing else changed. A loopback address is not a next hop
    # anything can forward to, and FRR filters it where GoBGP does not.
    #
    # This matters because the fault matrix reads route verdicts out of
    # that command. Point it at FRR with the peer's loopback address as
    # the next hop and the clean baseline route never appears either, so
    # every route verdict in the run is void: the harness says so rather
    # than scoring them, which is how this was found.
    #
    # 192.0.2.0/24 is RFC 5737 section 3's TEST-NET-1, reserved for
    # documentation, so it can never collide with anything real.
    NEXT_HOP = '192.0.2.1'

    def self.bin
      ENV['FRR_BGPD'] || (File.executable?(PACKAGED) ? PACKAGED : 'bgpd')
    end

    def self.vtysh ; ENV['VTYSH'] || 'vtysh' ; end

    def self.version
      out, status = Open3.capture2e(bin, '--version')
      status.success? ? out.lines.first.to_s.strip : nil
    rescue SystemCallError
      nil
    end

    def self.available? ; !version.nil? ; end

    # The major version, because the answers are not the same on every
    # one: that is the lesson GOBGP_3 records in fault_matrix_scenario.rb.
    def self.major
      v = version or return nil
      v[/version\s+(\d+)\./, 1]&.to_i
    end

    attr_reader :local, :as, :router_id, :peer, :peer_as, :port,
                :listen_port, :vty_port, :dir

    # port:    the port bgp4r listens on, which this router dials.
    # network: a prefix for it to originate, or nil for none.
    #
    # local defaults to 127.0.0.2 and must not be the peer's address, for
    # the same reason Gobgpd's does. RFC 4271 section 6.3 makes a NEXT_HOP
    # equal to the receiving speaker's own address an error, subcode 8,
    # "Invalid NEXT_HOP Attribute". The fault matrix sends its routes with
    # the peer's address as the next hop, so with both ends on 127.0.0.1
    # FRR rejects every route including the clean baseline one, and then
    # every route verdict in the run is meaningless. That is not
    # hypothetical: the first measurement here was made that way, and it
    # read as "FRR resets on all 18 cases" until the harness's own
    # test_the_rib_answer_was_usable said the RIB answer could not be
    # trusted.
    # The flow spec families, by the name FRR's own `address-family`
    # command wants. **There is no VPN flow spec family in 8.4.4**, and
    # that is measured rather than inferred from its absence here: a
    # session on which bgp4r advertises SAFI 134 alone is refused with
    # NOTIFICATION 2/7, Unsupported Capability (RFC 5492 section 5), and
    # one that also carries SAFI 133 comes up and then discards a SAFI
    # 134 rule in silence, leaving nothing in any RIB and sending no
    # notification. So a VPN flow spec case belongs to the GoBGP test
    # alone; see test/functional/lab/flow_spec_frr_test.rb.
    FS_IPV4 = 'ipv4 flowspec'
    FS_IPV6 = 'ipv6 flowspec'

    # EVPN, AFI 25 SAFI 70. FRR spells it the same in its config and in
    # its show command, so unlike GoBGP there is one name.
    EVPN = 'l2vpn evpn'

    # families: extra address families, each activated for the peer, such
    #           as FS_IPV4. Empty by default, so a config with none is
    #           what it always was.
    # ipv6:     activate IPv6 unicast for the peer. **Off by default**,
    #           because FRR 10 refuses it over an IPv4 session with no
    #           zebra: it logs "No local IPv6 address, and zebra does not
    #           support V6 routing with v4 nexthops" and sends Cease 6/0,
    #           where 8.4.4 only warned. Measured on the owner's VM against
    #           10.5.1 on 2026-11-04. A test that sends IPv6 unicast asks
    #           for it and runs on 8.x only.
    def initialize(local: '127.0.0.2', as: 65002, router_id: '10.0.0.2',
                   peer: '127.0.0.1', peer_as: 65001, port: nil, ipv6: false,
                   network: nil, families: [])
      @local, @as, @router_id = local, as, router_id
      @peer, @peer_as, @ipv6 = peer, peer_as, ipv6
      @network = network
      @families = families
      @port = port || Local.free_port
      @listen_port = Local.free_port
      @vty_port = Local.free_port
      @dir = Dir.mktmpdir('bgp4r-frr')
    end

    def config
      lines = ['hostname bgp4r-lab-frr',
               'password zebra',
               # Without these the log is empty, and the log is the whole
               # point of keeping one: it is the router saying in its own
               # words what it made of each UPDATE, which is what a
               # divergence has to be justified from. bgpd writes nothing
               # to stdout by default, however it was started.
               'log stdout debugging',
               'debug bgp updates in',
               'debug bgp neighbor-events',
               'router bgp %d' % @as,
               ' bgp router-id %s' % @router_id,
               # A lab, not a network. Without the first, FRR refuses to
               # accept or send anything to an eBGP peer with no policy
               # configured (RFC 8212, which it implements by default).
               # The second stops it requiring a matching route in its own
               # table before originating one with `network`.
               ' no bgp ebgp-requires-policy',
               ' no bgp network import-check',
               ' neighbor %s remote-as %d' % [@peer, @peer_as],
               # Where bgp4r listens, so our side needs no privilege.
               ' neighbor %s port %d' % [@peer, @port],
               # So the connection really comes from @local. Without it
               # bgpd dials from whatever the route to the peer gives,
               # which over loopback is 127.0.0.1, and then this router
               # and its peer share an address: see the note on local in
               # initialize for what that costs.
               ' neighbor %s update-source %s' % [@peer, @local],
               # A caller may give each case its own session, as the fault
               # matrix does, so keep coming back quickly.
               ' neighbor %s timers connect 2' % @peer]
      lines << ' address-family ipv4 unicast'
      lines << '  network %s' % @network if @network
      lines << ' exit-address-family'
      if @ipv6
        lines << ' address-family ipv6 unicast'
        lines << '  neighbor %s activate' % @peer
        lines << ' exit-address-family'
      end
      # A family has to be activated for the peer or FRR negotiates it
      # and then has nowhere to put what arrives.
      @families.each do |f|
        lines << ' address-family %s' % f
        lines << '  neighbor %s activate' % @peer
        lines << ' exit-address-family'
      end
      lines.join("\n") + "\n"
    end

    # A line to add when bgpd did not come up, or nil.
    #
    # **FRR 10's packages carry an AppArmor profile for the packaged
    # bgpd**, and it denies the pid file this harness puts under /tmp, as
    # root too. bgpd then logs "Can't create pid lock file ... (Permission
    # denied), exiting" and exits 1, which reads like the -S problem in the
    # class comment and is not. A profile attaches by path, so a copy of
    # the binary somewhere else runs unconfined. Measured on the owner's
    # VM against 10.5.1 on 2026-11-04.
    #
    # The hint fires on the log line, or when bgpd exited while AppArmor
    # is on and the binary is the packaged one, because bgpd may write the
    # pid error before it reads the config that sends its log to stdout.
    # Pure, so the unit suite pins it with no daemon.
    def self.startup_hint(log, bin: self.bin, apparmor: apparmor?, exited: true)
      pid_denied = log.to_s =~ /pid lock file.*Permission denied/
      packaged = (File.realpath(bin) rescue bin) == PACKAGED
      return nil unless pid_denied || (exited && apparmor && packaged)
      "bgpd may be confined by AppArmor. Copy it out of #{PACKAGED} and " \
      'point FRR_BGPD at the copy, for example: ' \
      'cp /usr/lib/frr/bgpd ~/frr-test/bgpd; FRR_BGPD=~/frr-test/bgpd'
    end

    def self.apparmor?
      File.read('/sys/module/apparmor/parameters/enabled').strip == 'Y'
    rescue SystemCallError
      false
    end

    # Starts bgpd and waits until its vty answers, which is the only
    # signal it read the config at all. Raises with the log, which names
    # the line it rejected. **Stops waiting the moment bgpd dies**, the
    # way Gobgpd does, so a pid file AppArmor refused costs one second and
    # not thirty.
    def up(timeout: 30)
      path = File.join(@dir, 'bgpd.conf')
      File.write(path, config)
      @log = File.join(@dir, 'bgpd.log')
      @pid = Process.spawn(self.class.bin,
                           '-f', path,
                           '-i', File.join(@dir, 'bgpd.pid'),
                           '-p', @listen_port.to_s,   # its own BGP port
                           '-P', @vty_port.to_s,
                           '-l', @local,
                           '--vty_socket', @dir,
                           '-S',             # see the class comment
                           '--no_kernel',
                           out: @log, err: [:child, :out])
      deadline = Time.now + timeout
      until summary
        dead = exited?
        if dead || Time.now > deadline
          text = log
          hint = self.class.startup_hint(text, exited: dead)
          what = dead ? 'bgpd exited without coming up' : "bgpd did not come up in #{timeout}s"
          raise [what + ':', text, hint].compact.join("\n")
        end
        sleep 0.5
      end
      self
    end

    # True once the child is gone, reaping it. Gobgpd's, for the same reason.
    def exited?
      return false unless @pid
      !Process.wait(@pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end
    private :exited?

    def down
      @log_text = log
      if @pid
        Process.kill('TERM', @pid)
        Process.wait(@pid)
      end
    rescue Errno::ESRCH, Errno::ECHILD
    ensure
      @pid = nil
      FileUtils.rm_rf(@dir)
    end

    # One vty command, or nil while bgpd is not answering.
    def vty(command)
      out, status = Open3.capture2e(self.class.vtysh, '--vty_socket', @dir,
                                    '-c', command)
      status.success? ? out : nil
    rescue SystemCallError
      nil
    end

    # A vty command that answers JSON, parsed, or nil.
    #
    # The JSON is taken from the first brace rather than from the start of
    # the output, because vtysh prefixes warnings to it and they are not
    # JSON. Run as any user who is not root and not in the frrvty group,
    # which is what CI does, every call begins with:
    #
    #   % Can't open configuration file /etc/frr/vtysh.conf due to
    #   'Permission denied'.
    #
    # and the command still answers correctly after it. Parsing the whole
    # output instead made every call here return nil, so up never saw the
    # daemon answer and raised after its timeout even though the session
    # had established. That is what broke the first CI run of this: root
    # reads that file, so nothing local showed it.
    #
    # One more line a non-root run prints, harmless and left alone: bgpd
    # logs that it could not mkdir under /var/tmp/frr and that "crashlog
    # and per-thread log buffering unavailable". It is a crash handler, not
    # anything this needs.
    def vty_json(command)
      out = vty(command) or return nil
      start = out.index('{') || out.index('[') or return nil
      JSON.parse(out[start..])
    rescue JSON::ParserError
      nil
    end

    def summary ; vty_json('show bgp summary json') ; end

    # The neighbor table, keyed by address, or nil while not answering.
    def neighbors ; vty_json('show bgp neighbors json') ; end

    def neighbor(address) ; (neighbors || {})[address] ; end

    # True when the session to our peer is up. FRR spells the state
    # "Established" in its JSON, the same word RFC 4271 section 8.2.2 uses.
    def established?(address = @peer)
      n = neighbor(address)
      n && n['bgpState'] == 'Established'
    end

    # What to pass lab/fault_matrix.rb as --rib-command: one argument,
    # spaces and all, since the matrix runs it through a shell. Quoted
    # because the command itself has spaces in it.
    def rib_command
      "#{self.class.vtysh} --vty_socket #{@dir} -c 'show bgp ipv4 unicast'"
    end

    # The router's RIB: prefix => array of paths, as FRR's own JSON gives
    # it. nil while not answering, {} for an empty RIB, so a caller can
    # tell "nothing there" from "could not ask", as Gobgpd#rib does.
    def rib(family = 'ipv4 unicast')
      answer = vty_json("show bgp #{family} json") or return nil
      answer['routes'] || {}
    end

    # How many prefixes the router took from our peer in one family,
    # from its own summary, or nil while it is not answering. FRR's own
    # count rather than this reader's, so a large feed is not read back
    # as JSON to be counted. LabHelper#spec_crosses reads this.
    def path_count(family = 'ipv4 unicast')
      s = vty_json("show bgp #{family} summary json") or return nil
      p = (s['peers'] || {})[@peer] or return nil
      p['pfxRcd'].to_i
    end

    # One path for a prefix, best first, or nil.
    def path(prefix)
      paths = (rib || {})[prefix] or return nil
      paths.find { |p| p['bestpath'] } || paths.first
    end

    # The one rule in a flow spec family, as [key, path], or nil when it
    # holds none. The twin of Gobgpd#only_rule, so the two flow spec
    # tests read alike.
    #
    # **FRR's key carries the RFC 8955 section 4.1 length**, which is
    # worth knowing before reading one: the rule of section 4.3.1 comes
    # back as `to 192.0.2.0/24 proto = 6  port = 25 /11`, where 11 is
    # 0x0b, the length a correct encoder writes. So the key checks our
    # framing arithmetic as well as our components, with FRR's own
    # spacing, which is its text and not contractual.
    def only_rule(family)
      r = rib(family) or return nil
      pair = r.first or return nil
      key, paths = pair
      path = paths.find { |p| p['bestpath'] } || paths.first
      [key, path]
    end

    # The EVPN table, as prefix => array of paths, flattened across the
    # Route Distinguishers.
    #
    # **This needs its own reader because the EVPN JSON is shaped
    # differently from every other family's.** `show bgp ipv4 unicast
    # json` puts everything under a `routes` key, which is what #rib
    # reads; `show bgp l2vpn evpn json` has no `routes` key at all and
    # is keyed by RD at the top level, each RD holding its own prefixes
    # beside scalars like `numPrefix` and `localAS`. So #rib answers {}
    # for this family however many routes are in it, which is a wrong
    # answer rather than a missing one. Measured on 2026-10-30.
    #
    # The paths are worth reading field by field, which is more than
    # GoBGP's rendering gives for route type 2: FRR's JSON carries
    # `routeType`, `ethTag`, `macLen`, `mac`, `ipLen`, `ip` and `esi` as
    # separate keys, so an assertion names the field RFC 7432 names.
    def evpn_rib
      answer = vty_json("show bgp #{EVPN} json") or return nil
      out = {}
      answer.each_value do |v|
        next unless v.is_a?(Hash) and v['rd']
        v.each { |k, p| out[k] = p['paths'] if p.is_a?(Hash) and p['paths'] }
      end
      out
    end

    # How many prefixes FRR says that table holds, which is its own count
    # and not this reader's. nil while it is not answering.
    def evpn_count
      answer = vty_json("show bgp #{EVPN} json") or return nil
      answer['numPrefix'].to_i
    end

    # One prefix in full, which is a different command and a different
    # shape from the table form above.
    #
    # Use this for anything the table form leaves out, and it leaves out
    # more than it looks: `show bgp ipv4 unicast json` gives an
    # abbreviated row per path with no `originatorId` and no
    # `clusterList` key at all, so reading the two RFC 4456 section 8
    # attributes off it answers nil however correct the UPDATE was. That
    # is a wrong answer rather than a missing one, which is why this
    # exists rather than a note somewhere.
    #
    # The shapes differ too, so a path from here is not interchangeable
    # with one from #path: the AS_PATH is a nested `aspath` with
    # `segments` here and a flat `path` string there, which is why
    # Frr.as_path reads the table form and this does not feed it.
    def detail(prefix, family = 'ipv4 unicast')
      answer = vty_json("show bgp #{family} #{prefix} json") or return nil
      paths = answer['paths'] or return nil
      paths.find { |p| p['bestpath'] } || paths.first
    end

    # FRR's JSON names attributes rather than numbering them, where the
    # gobgp client keys them by code point, so there is no shared shape to
    # read them through. These are the ones a test here asks about.
    def self.as_path(path)
      (path['path'] || '').split(/\s+/).reject(&:empty?).collect(&:to_i)
    end

    def self.next_hop(path)
      hop = (path['nexthops'] || []).first
      hop && hop['ip']
    end

    # The daemon's own log: what it made of each UPDATE, in its words.
    # Cached at down, since the directory goes with it.
    def log
      return @log_text if @log_text
      @log ? File.read(@log) : ''
    rescue Errno::ENOENT
      ''
    end
  end

  # ---- a bgp/gen spec against a router ---------------------------------
  #
  # Phase 6 of docs/route-generation.md: a lab test hands the router a
  # spec rather than hand built UPDATEs. Both routers answer
  # `path_count(family)` in their own family name, so this one method
  # serves either.
  #
  # It sends every UPDATE of the spec, waits until the router counts
  # exactly `total` paths, yields a sample of the `expected` rows for the
  # caller to compare with what the router printed, then withdraws and
  # waits for zero. **The count is the assertion that cannot pass by
  # luck**: a route the router dropped never reaches it.
  #
  # spec:   a spec Hash, or a BGP::Gen already built
  # peer:   anything with send_message, usually a BGP::Neighbor
  # sender: the session rules, as BGP::Gen.new takes them
  # sample: how many expected rows to yield, spread across the feed
  def spec_crosses(router, family, spec, peer, sender: nil, sample: 10, timeout: 60)
    require 'bgp/gen'
    g = spec.is_a?(BGP::Gen) ? spec : BGP::Gen.new(spec, sender)
    total = g.total
    g.updates.each { |u| peer.send_message u }
    wait_for("the router to hold #{total} #{family} paths", timeout: timeout) {
      router.path_count(family) == total
    }
    if block_given?
      rows = g.expected.to_a
      yield LabHelper.sample(rows.size, sample).collect { |i| rows[i] }
    end
    g.withdrawals.each { |u| peer.send_message u }
    wait_for("the router to hold no #{family} paths", timeout: timeout) {
      router.path_count(family) == 0
    }
    g
  end

  # n indexes spread across size rows, the first and the last among
  # them, so a pattern's value is checked at more than one point of its
  # cycle. Fewer when there are fewer rows.
  def self.sample(size, n = 10)
    return [] if size < 1
    return (0...size).to_a if size <= n
    (0...n).collect { |k| (size - 1) * k / (n - 1) }.uniq
  end

  # Wait until the block returns a truthy value, or fail with message.
  def wait_for(message, timeout: 30, interval: 0.5)
    deadline = Time.now + timeout
    loop do
      result = yield
      return result if result
      flunk "#{message} (waited #{timeout}s)" if Time.now > deadline
      sleep interval
    end
  end

  # One neighbor's entry in a node's state, or nil.
  def neighbor(lab, node, address)
    s = lab.state(node)
    s && s['neighbors'] && s['neighbors'][address]
  end

  def wait_established(lab, node, address, timeout: 30)
    wait_for("#{node} session to #{address} Established", timeout: timeout) do
      n = neighbor(lab, node, address)
      n if n && n['state'] == 'Established'
    end
  end

  def wait_routes(lab, node, address, prefixes, timeout: 30)
    wait_for("#{node} to receive #{prefixes.join(', ')} from #{address}", timeout: timeout) do
      n = neighbor(lab, node, address)
      n if n && (prefixes - n['received'].keys).empty?
    end
  end
end
