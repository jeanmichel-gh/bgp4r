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

# The console over a real session, against the test BGP server on
# loopback: the verbs in process, then `bgp4r routegen --interact`,
# `bgp4r console` and `bgp4r sim --interact` as programs, driven by lines on its standard input the way a person types
# them. No privilege, no router, no Docker.
#
#   ruby -I. test/functional/console_test.rb

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim/console'
require 'bgp/sim/console_command'
require 'bgp/sim/http'
require 'bgp/daemon'
require 'test/helpers/server'
require 'rbconfig'
require 'tmpdir'
require 'net/http'
require 'socket'

class TestConsole < Test::Unit::TestCase
  include BGP
  include BGP::TestHelpers

  ROOT = File.expand_path('../..', __dir__)
  PEER_AS = 100

  # The UPDATEs the test server read. BGP:: written in full: a nested class does
  # not see the include around it.
  class Catcher
    def initialize ; @q = Queue.new ; end
    def update(msg) ; @q << msg if msg.is_a?(BGP::Update) ; end

    def shift(timeout = 5)
      deadline = Time.now + timeout
      loop do
        return @q.shift if @q.size > 0
        return nil if Time.now > deadline
        sleep 0.02
      end
    end
  end

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    @catcher = Catcher.new
    @port = start_server
    @s.add_observer @catcher
  end

  def teardown
    @injector.stop if @injector
    stop_server
    Log.set_filename(STDERR)
  end

  def wait(seconds = 10)
    deadline = Time.now + seconds
    until yield
      return false if Time.now > deadline
      sleep 0.05
    end
    true
  end

  def console
    @injector = BGP::Sim::Injector.new(
      'router_id' => '10.255.10.1', 'as' => 65_001,
      'neighbors' => [{ 'address' => '127.0.0.1', 'as' => PEER_AS, 'connect' => true,
                        'port' => @port, 'retry' => 0.2, 'hold_time' => 30 }])
    @injector.start
    assert(wait { @s.is_established? }, 'the session did not come up')
    @out = StringIO.new
    BGP::Sim::Console.new(@injector, @out)
  end

  def nlri_of(msg) ; msg.nlri.to_ary ; end

  # ---- in process -----------------------------------------------------

  def test_an_announcement_typed_at_the_console_crosses
    c = console
    c.announce('10.9.0.0/24', med: 7)
    u = @catcher.shift
    assert_kind_of(BGP::Update, u)
    assert_equal(['10.9.0.0/24'], nlri_of(u))
    assert_equal(7, u.path_attribute[:multi_exit_disc].to_i)
  end

  def test_a_specimen_crosses_by_name
    c = console
    c.specimen(:large_communities, '10.8.0.0/24')
    u = @catcher.shift
    assert_equal(['10.8.0.0/24'], nlri_of(u))
    assert(u.path_attribute.has?(BGP::Large_communities), 'the specimen attribute arrived')
  end

  def test_ship_puts_a_hand_built_message_on_the_wire
    c = console
    upd = Update.new(Path_attribute.new(Origin.new(0), Next_hop.new('127.0.0.1'), As_path.new(65_001)),
                     Nlri.new('10.7.0.0/24'))
    c.ship(upd)
    assert_equal(['10.7.0.0/24'], nlri_of(@catcher.shift))
  end

  def test_what_the_peer_sends_is_received
    c = console
    @s.send_message Update.new(Path_attribute.new(Origin.new(0), Next_hop.new('127.0.0.1'),
                                                  As_path.new(PEER_AS)),
                               Nlri.new('192.0.2.0/24'))
    assert(wait { c.last.is_a?(BGP::Update) }, 'nothing reached the console')
    assert_equal(['192.0.2.0/24'], nlri_of(c.last))
    c.received
    assert_match(/127\.0\.0\.1 Update, 1 prefixes, 0 withdrawn/, @out.string)
  end

  # ---- connect, listen, shutdown and clear: bgp4r console ---------------

  # Every message the test server reads, NOTIFICATIONs included.
  class AllCatcher < Catcher
    def update(msg) ; @q << msg if msg.is_a?(BGP::Message) ; end
  end

  # A console with no session, which opens one at the prompt.
  def empty_console
    @out = StringIO.new
    @owned = BGP::Sim::Console.new(nil, @out)
  end

  def connected_console
    c = empty_console
    row = c.connect('127.0.0.1', remote_as: PEER_AS, port: @port)
    assert_equal('Established', row[:state].to_s, 'connect waited for the session')
    c
  end

  def teardown_console
    @owned.stop if @owned
  end

  def notification_from(catcher)
    loop do
      m = catcher.shift
      return m if m.nil? || m.is_a?(BGP::Notification)
    end
  end

  def test_connect_at_the_prompt_opens_a_session_and_an_announcement_crosses
    c = connected_console
    assert(@s.is_established?)
    c.announce('10.5.0.0/24', med: 4)
    u = @catcher.shift
    assert_equal(['10.5.0.0/24'], nlri_of(u))
    assert_equal(4, u.path_attribute[:multi_exit_disc].to_i)
  ensure
    teardown_console
  end

  def test_clear_sends_administrative_reset_and_the_session_comes_back
    all = AllCatcher.new
    @s.add_observer all
    c = connected_console
    c.clear
    n = notification_from(all)
    assert_kind_of(BGP::Notification, n, 'no NOTIFICATION reached the peer')
    assert_equal([6, 4], n.to_hash.values_at(:code, :subcode))
    assert(wait(15) { c.state == 'Established' }, "clear left it #{c.state}")
  ensure
    teardown_console
  end

  def test_shutdown_sends_administrative_shutdown_and_it_stays_down
    all = AllCatcher.new
    @s.add_observer all
    c = connected_console
    c.shutdown
    n = notification_from(all)
    assert_kind_of(BGP::Notification, n, 'no NOTIFICATION reached the peer')
    assert_equal([6, 2], n.to_hash.values_at(:code, :subcode))
    sleep 3 # longer than the 2 second retry
    assert_not_equal('Established', c.state.to_s, 'it came back on its own')
    c.no_shutdown
    assert(wait(15) { c.state == 'Established' }, "no_shutdown left it #{c.state}")
  ensure
    teardown_console
  end

  # Two bgp4r speakers in one process, one listening and one dialling,
  # each a console of its own. What one announces the other reads.
  def test_listen_takes_a_session_a_second_console_dials
    port = TCPServer.open('127.0.0.1', 0) { |srv| srv.addr[1] }
    near = empty_console
    near.listen('127.0.0.1', remote_as: 65_002, port: port, local_address: '127.0.0.1', wait: 0)
    far = BGP::Sim::Console.new(nil, StringIO.new)
    begin
      row = far.connect('127.0.0.1', remote_as: 65_001, local_as: 65_002, port: port)
      assert_equal('Established', row[:state].to_s)
      assert(wait { near.state == 'Established' })
      far.announce('10.4.0.0/24')
      assert(wait { near.last.is_a?(BGP::Update) }, 'nothing reached the listening side')
      assert_equal(['10.4.0.0/24'], nlri_of(near.last))
      assert_equal([65_002], near.last.path_attribute[:as_path].as_path.split.collect(&:to_i))
    ensure
      far.stop
    end
  ensure
    teardown_console
  end

  def test_a_second_listen_on_a_taken_port_is_refused_in_words
    port = TCPServer.open('127.0.0.1', 0) { |srv| srv.addr[1] }
    c = empty_console
    c.listen('127.0.0.1', remote_as: 65_002, port: port, local_address: '127.0.0.1', wait: 0)
    e = assert_raise(ArgumentError) do
      c.listen('127.0.0.9', remote_as: 65_009, port: port, local_address: '127.0.0.1', wait: 0)
    end
    assert_match(/port #{port} is taken/, e.message)
    assert_equal(['127.0.0.1'], c.peers.collect { |p| p[:address] })
  ensure
    teardown_console
  end

  # The program: no session until `connect` is typed.
  def test_bgp4r_console_opens_with_no_session_and_connect_opens_one
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4r'), 'console', '-l', File::NULL]
    out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
      io.puts 'p peers'
      io.puts 'p Specimen.build(:origin).class'
      io.puts "connect '127.0.0.1', remote_as: #{PEER_AS}, port: #{@port}"
      io.puts "announce '10.3.0.0/24'"
      io.puts 'exit'
      io.close_write
      io.read
    end
    assert_equal(0, $?.exitstatus, out)
    assert_match(/^\[\]$/, out, 'peers answered no session')
    assert_match(/^BGP::Origin$/, out, 'the library is loaded, with BGP included')
    assert_match(/:state=>"Established"|state: "Established"/, out, 'connect answered the row')
    u = @catcher.shift
    assert_kind_of(BGP::Update, u, 'nothing crossed: ' + out)
    assert_equal(['10.3.0.0/24'], nlri_of(u))
    assert(wait { !@s.is_established? }, 'exit left the session up')
  end

  def test_bgp4r_console_with_peer_connects_before_the_prompt
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4r'), 'console',
            '--peer', '127.0.0.1', '--peer-as', PEER_AS.to_s, '--port', @port.to_s, '-l', File::NULL]
    out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
      io.puts "announce '10.2.0.0/24'"
      io.puts 'exit'
      io.close_write
      io.read
    end
    assert_equal(0, $?.exitstatus, out)
    assert_match(/session to 127\.0\.0\.1 is established/, out)
    assert_equal(['10.2.0.0/24'], nlri_of(@catcher.shift))
  end

  # ---- bgp4r routegen --interact ----------------------------------------

  # The whole program, with its prompt fed from a pipe: the line typed
  # goes out, `exit` stops the session and the program succeeds.
  # `::IO`, because a bare `IO` in a class that includes BGP is BGP::IO.
  def test_routegen_interact_sends_what_is_typed_and_exit_quits
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4r'), 'routegen',
            '--peer', '127.0.0.1', '--peer-as', PEER_AS.to_s, '--port', @port.to_s,
            '--interact', '-l', File::NULL]
    out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
      io.puts "announce '10.6.0.0/24', med: 3"
      io.puts 'state'
      io.puts 'guide 5'
      io.puts 'exit'
      io.close_write
      io.read
    end
    assert_equal(0, $?.exitstatus, out)
    assert_match(/session to 127\.0\.0\.1 up/, out)
    assert_match(/"Established"/, out, 'the prompt answered a verb')
    assert_match(/^5\. Leaving$/, out, 'guide printed its section')
    u = @catcher.shift
    assert_kind_of(BGP::Update, u, 'nothing crossed: ' + out)
    assert_equal(['10.6.0.0/24'], nlri_of(u))
    assert_nil(@catcher.shift(0.5), 'it started silent: one UPDATE, the one typed')
    assert(wait { !@s.is_established? }, 'exit left the session up')
  end


  # ---- bgp4r sim --interact ---------------------------------------------

  # The injector with its prompt on, fed from a pipe, while the test
  # drives the same node over its HTTP API: what is typed goes out, what
  # is posted goes out, and `exit` stops the session and the API.
  def test_sim_interact_takes_typed_lines_while_the_api_serves
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    probe = TCPServer.new('127.0.0.1', 0)
    api = probe.addr[1]
    probe.close
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sim.yml')
      File.write(path, <<~YAML)
        router_id: 10.255.10.1
        as: 65001
        api: 127.0.0.1:#{api}
        neighbors:
          - address: 127.0.0.1
            port: #{@port}
            as: #{PEER_AS}
            connect: true
            retry: 0.2
      YAML
      argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4r'), 'sim', path,
              '--interact', '-l', File::NULL]
      out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
        assert(wait { @s.is_established? }, 'the session did not come up')
        io.puts "announce '10.6.0.0/24', med: 3"
        u = @catcher.shift
        assert_kind_of(BGP::Update, u, 'the typed line did not cross')
        assert_equal(['10.6.0.0/24'], nlri_of(u))
        http = Net::HTTP.new('127.0.0.1', api)
        r = http.post('/api/announce', '{"prefixes":["10.5.0.0/24"]}',
                      BGP::Sim::Http::HEADER => BGP::Sim::Http::HEADER_VALUE)
        assert_equal('200', r.code, r.body)
        assert_equal(['10.5.0.0/24'], nlri_of(@catcher.shift), 'the API did not serve')
        io.puts 'exit'
        io.close_write
        io.read
      end
      assert_equal(0, $?.exitstatus, out)
      assert_match(/self is the console/, out)
      assert(wait { !@s.is_established? }, 'exit left the session up')
      assert_raise(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', api) }
    end
  end

  # ---- bgp4rd --interact ------------------------------------------------

  # The daemon with its prompt on, fed from a pipe, while bgp4r-cli reads
  # the same daemon over its socket. A route typed at the prompt goes
  # into the Loc-RIB, out through the export rules with the configured
  # mark, and the peer reads it; `exit` sends Cease 6/2 and the socket
  # goes away.
  def test_bgp4rd_interact_originates_with_the_mark_and_ceases_on_exit
    begin
      BGP::Daemon::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    notes = Queue.new
    @s.add_observer(Class.new do
      define_method(:initialize) { |q| @q = q }
      define_method(:update) { |m| @q << m if m.is_a?(BGP::Notification) }
    end.new(notes))
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'rtr.yml')
      sock = File.join(dir, 'rtr.sock')
      File.write(path, <<~YAML)
        router_id: 10.255.0.1
        as: 65001
        neighbors:
          - address: 127.0.0.1
            port: #{@port}
            as: #{PEER_AS}
            connect: true
            retry: 0.2
        # Both ends are 127.0.0.1, and RFC 4271 section 5.1.3 forbids
        # sending our own route with the peer's address as its next hop,
        # so the next hop is named.
        export:
          next_hops: { 1: 192.0.2.1 }
        mark:
          large_communities: ['65001:1:1']
      YAML
      argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4rd'), '-f', path,
              '-s', sock, '--interact', '-l', File::NULL]
      out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
        assert(wait { @s.is_established? }, 'the session did not come up')
        io.puts "originate '10.7.0.0/24', communities: ['65001:100']"
        u = @catcher.shift
        assert_kind_of(BGP::Update, u, 'the typed route did not cross')
        assert_equal(['10.7.0.0/24'], nlri_of(u))
        assert_equal('65001:100', u.path_attribute[:communities].communities)
        assert(u.path_attribute.has?(BGP::Large_communities), 'the mark did not go out with the route')
        assert_equal(['65001:1:1'], u.path_attribute[:large_communities].communities.collect(&:to_s))
        # The prompt and the socket are one daemon: the route typed at one
        # is in the table the other reads.
        rows = BGP::Daemon::Client.new(sock).call('show.routes', 'prefix' => '10.7.0.0/24')['rows']
        assert_equal(['65001:1:1'], rows.first['large_communities'])
        io.puts "why '10.7.0.0/24'"
        io.puts 'exit'
        io.close_write
        io.read
      end
      assert_equal(0, $?.exitstatus, out)
      assert_match(/self is the daemon/, out)
      assert_match(%r{10\.7\.0\.0/24, 1 path, decided at}, out)
      assert_match(%r{bgp4rd: stopping, Cease 6/2 to 1 peer\b}, out)
      n = notes.pop(:timeout => 5)
      assert_not_nil(n, 'no NOTIFICATION reached the peer')
      assert_equal([6, 2], [n.to_hash[:code], n.to_hash[:subcode]])
      assert_equal(false, File.exist?(sock), 'exit left the socket')
    end
  end

end

# `bgp4r console --back-to-back`: two bgp4r speakers in this process, on
# 127.0.0.1, with no test server. The claim it exists for is that every
# specimen and every fault crosses with no node file, which no router
# here can say, so that is asserted catalog by catalog.
class TestConsoleBackToBack < Test::Unit::TestCase

  def setup
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    Log.set_filename(STDERR)
  end

  # Runs the command with the prompt replaced by the block, so no irb.
  # The remote side logs nowhere.
  def back_to_back(*argv, &prompt)
    @cmd = BGP::Sim::ConsoleCommand.new(@out, @err, :interact => prompt, :load_irb => false,
                                        :remote_logger => ->(_level, _message) {})
    status = @cmd.start(['--back-to-back', '--timeout', '10', '-l', File::NULL, *argv])
    assert_equal(0, status, @err.string)
  end

  # The next message a console receives after count, or nil.
  def next_in(console, count, timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until console.instance_variable_get(:@received).size > count || Time.now > deadline
    r = console.instance_variable_get(:@received)
    r.size > count ? r.last.message : nil
  end

  # The [afi, safi] pairs of the MBGP capabilities in the OPEN a
  # console's session received, which is what the other side offered.
  def families_heard(console)
    console.neighbor.session_info.peer.opt_parms
           .flat_map { |o| o.respond_to?(:capabilities) ? Array(o.capabilities) : [o] }
           .select { |c| c.is_a?(BGP::OPT_PARM::CAP::Mbgp) }
           .collect { |c| h = c.to_hash[:capability] ; [h[:afi], h[:safi]] }.sort
  end

  def count_in(console) ; console.instance_variable_get(:@received).size ; end

  def test_a_fault_is_reported_on_the_remote_side_and_remote_sends_back
    back_to_back do |c|
      assert_equal('Established', c.peers.first[:state])
      assert_equal('Established', c.remote.peers.first[:state])
      n = count_in(c.remote)
      c.fault :origin_value, '10.3.0.0/24'
      u = next_in(c.remote, n)
      assert_kind_of(BGP::Update, u)
      assert_match(/undefined ORIGIN value/, u.path_attribute.errors.first.reason)
      n = count_in(c)
      c.remote.announce '10.9.0.0/24', med: 5
      u = next_in(c, n)
      assert_equal(['10.9.0.0/24'], u.nlri.to_ary)
      assert_equal([65_002], u.path_attribute[:as_path].as_path.split.collect(&:to_i),
                   'eBGP: the remote side put its AS in front')
    end
    assert_match(/AS 65001 to AS 65002, eBGP, session established/, @out.string)
    assert_equal('Idle', @cmd.remote.peers.first[:state].to_s, 'exit stopped the remote side')
    assert_equal('Idle', @cmd.console.peers.first[:state].to_s, 'and ours')
  end

  def test_every_specimen_crosses_clean_and_every_fault_is_reported
    back_to_back do |c|
      # A bgp4r receiver reads a family it did not negotiate, so a
      # specimen crossing does not say it was offered. The OPEN does.
      every = BGP::Sim::ConsoleCommand.families.collect { |_, afi, safi| [afi, safi] }.sort
      assert_equal(every, families_heard(c.remote), 'the remote side heard every family')
      assert_equal(every, families_heard(c), 'and so did ours')
      BGP::Specimen.names.each do |name|
        n = count_in(c.remote)
        c.specimen name
        u = next_in(c.remote, n)
        assert_kind_of(BGP::Update, u, "specimen #{name} did not arrive")
        assert_empty(u.path_attribute.errors.collect(&:reason), "specimen #{name}")
        assert_empty(u.path_attribute.undecoded, "specimen #{name} was not decoded")
      end
      BGP::Fault.names.each do |name|
        n = count_in(c.remote)
        c.fault name
        u = next_in(c.remote, n)
        assert_kind_of(BGP::Update, u, "fault #{name} did not arrive")
        assert_not_empty(u.path_attribute.errors, "fault #{name} was not reported")
      end
      assert_equal('Established', c.peers.first[:state], 'no fault took the session down')
    end
  end

  def test_equal_as_numbers_make_it_ibgp
    back_to_back('--my-as', '65010', '--peer-as', '65010') do |c|
      n = count_in(c)
      c.remote.announce '10.8.0.0/24'
      u = next_in(c, n)
      assert_equal('empty', u.path_attribute[:as_path].as_path, 'iBGP: no AS put in front')
      assert(u.path_attribute.has?(BGP::Local_pref), 'iBGP carries LOCAL_PREF')
    end
    assert_match(/iBGP/, @out.string)
  end

  # Only the families asked for: a session offering IPv4 unicast alone
  # still comes up, and the remote reads what it was offered.
  def test_families_narrows_what_both_sides_offer
    back_to_back('--families', 'unicast') do |c|
      assert_equal('Established', c.peers.first[:state])
      assert_equal([[1, 1], [2, 1]], families_heard(c.remote))
      assert_equal([[1, 1], [2, 1]], families_heard(c))
    end
  end

  # The whole program, typed into: a fault from our side is reported on
  # the remote one, and exit stops both and succeeds.
  def test_bgp4r_console_back_to_back_as_a_program
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    root = File.expand_path('../..', __dir__)
    require 'tmpdir'
    Dir.mktmpdir do |d|
      argv = [RbConfig.ruby, '-I', root, File.join(root, 'exe', 'bgp4r'), 'console',
              '--back-to-back', '-l', File.join(d, 'c.log')]
      out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
        io.puts "fault :origin_value, '10.3.0.0/24'"
        io.puts 'sleep 1'
        io.puts 'puts "REASON " + remote.last.path_attribute.errors.first.reason'
        io.puts 'exit'
        io.close_write
        io.read
      end
      assert_equal(0, $?.exitstatus, out)
      assert_match(/back to back on 127\.0\.0\.1 port \d+, AS 65001 to AS 65002, eBGP, session established/, out)
      assert_match(/^REASON undefined ORIGIN value/, out)
      assert(File.size?(File.join(d, 'c-remote.log')), 'the remote side wrote its own log')
    end
  end

end
