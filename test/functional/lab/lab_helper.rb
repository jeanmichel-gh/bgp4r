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

    def self.free_port
      s = TCPServer.new('127.0.0.1', 0)
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

    # Config-file name to client name, for the families where the two
    # disagree. Everything else is spelled alike on both sides, RTC
    # included.
    CLIENT_FAMILY = { FS_VPN => 'ipv4-l3vpn-flowspec', EVPN => 'evpn' }.freeze

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
    def initialize(local: '127.0.0.2', as: 65002, router_id: '10.0.0.2',
                   peer: '127.0.0.1', peer_as: 65001, port: nil, ipv6: true,
                   add_path: nil, families: [])
      @local, @as, @router_id = local, as, router_id
      @peer, @peer_as, @ipv6 = peer, peer_as, ipv6
      @add_path = add_path
      @families = families
      @port = port || Local.free_port
      @listen_port = Local.free_port
      @api_port = Local.free_port
      @dir = Dir.mktmpdir('bgp4r-gobgpd')
    end

    def config
      families = ['ipv4-unicast']
      families << 'ipv6-unicast' if @ipv6
      families += @families
      afi_safis = families.collect { |f|
        "  [[neighbors.afi-safis]]\n" \
        "    [neighbors.afi-safis.config]\n" \
        "      afi-safi-name = \"#{f}\"\n"
      }.join
      global = <<~TOML
        [global.config]
          as = #{@as}
          router-id = "#{@router_id}"
          local-address-list = ["#{@local}"]
          # Its own listening port, so the daemon needs no privilege. It
          # only dials out here; GoBGP would still bind 179 without this.
          port = #{@listen_port}

        [[neighbors]]
          [neighbors.config]
            neighbor-address = "#{@peer}"
            peer-as = #{@peer_as}
          [neighbors.transport.config]
            local-address = "#{@local}"
            # Where bgp4r listens, so our side needs no privilege either.
            remote-port = #{@port}
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
      global + afi_safis + add_paths
    end

    # Starts the daemon and waits until its API answers, which is the only
    # signal that it read the config at all. Raises with the daemon's log,
    # which names the config key it rejected.
    def up(timeout: 30)
      path = File.join(@dir, 'gobgpd.conf')
      File.write(path, config)
      @log = File.join(@dir, 'gobgpd.log')
      @pid = Process.spawn(self.class.bin, '-f', path, '--api-hosts', "#{@local}:#{@api_port}",
                           out: @log, err: [:child, :out])
      deadline = Time.now + timeout
      until neighbors
        raise "gobgpd did not come up in #{timeout}s:\n#{log}" if Time.now > deadline
        sleep 0.5
      end
      self
    end

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
    def initialize(local: '127.0.0.2', as: 65002, router_id: '10.0.0.2',
                   peer: '127.0.0.1', peer_as: 65001, port: nil, ipv6: true,
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

    # Starts bgpd and waits until its vty answers, which is the only
    # signal it read the config at all. Raises with the log, which names
    # the line it rejected.
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
        raise "bgpd did not come up in #{timeout}s:\n#{log}" if Time.now > deadline
        sleep 0.5
      end
      self
    end

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
