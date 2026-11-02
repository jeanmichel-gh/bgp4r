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

# `bgp4r-sim` over its real HTTP API and a real BGP session, and the
# only test that can say the two halves agree.
#
#   ruby -I. test/functional/sim_test.rb
#
# **Why it has to be here and not in test/unit/sim/.** Every unit test
# on the API side reads a `[status, data]` pair `handle` returned, and
# every one on the action side reads a message a fake peer kept, so
# neither can say that an HTTP request reaching this process puts octets
# on a socket that another BGP speaker reads as the UPDATE it asked for.
# That is the argument test/functional/flow_spec_test.rb makes for the
# four NLRI wiring sites, two layers up.
#
# **The client is `Net::HTTP`, which is what routescope's driver
# inlines.** `Drivers::Sim`, read at routescope `7eabde1`, runs
# `ruby -rnet/http -e 'print Net::HTTP.get(...)'` and
# `Net::HTTP.post(URI(...), ARGV[1], "X-OSPFv2" => "routescope",
# "Content-Type" => "application/json")` under `docker exec`, then
# `exit(r.code.to_i < 300 ? 0 : 1)`. So using the same client is what
# makes this test say something about the driver: in particular it is
# what sends `X-Bgp4r`, capitalised per word, where the header is
# written `X-BGP4R`.
#
# It needs no privilege, no router and no container: the API is a port
# on the loopback and the session is two bgp4r speakers on another.
require 'test/unit'
require 'json'
require 'net/http'
require 'socket'
require 'stringio'
require 'tmpdir'
require 'bgp4r'
require 'bgp/sim'
require 'test/helpers/server'

class BGP_Sim_Functional_Test < Test::Unit::TestCase
  include BGP::TestHelpers

  PEER_AS = 100     # the test helper's AS
  OUR_AS  = 65_001

  # Keeps what the receiving speaker parsed, so a test reads the UPDATE
  # another implementation of this library made of our octets.
  #
  # BGP:: names are written out in full here, see Conventions in
  # CLAUDE.md: a nested class does not see an include in the class
  # around it, and `Neighbor` logs an exception from an observer rather
  # than raising it, so a wrong constant shows up as "nothing arrived".
  class Catcher
    def initialize ; @q = Queue.new ; end

    def update(msg)
      @q << msg if msg.is_a?(BGP::Update)
    end

    def size ; @q.size ; end
    def clear ; @q.clear ; end
    def to_a ; a = [] ; a << @q.shift while @q.size > 0 ; a ; end

    # The next UPDATE, or nil after timeout seconds.
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
    # **The library's own logger goes to a StringIO for the length of
    # this file.** Every session here writes INFO lines and `Log` is
    # process-wide, so without this a run prints 60 lines of FSM
    # transitions per test. `teardown` puts it back, which
    # test/functional/daemon_test.rb records the reason for: it replaces
    # the logger for every other test in the process.
    Log.set_filename(StringIO.new)
    Log.level = Logger::WARN
    @dir = Dir.mktmpdir
    @catcher = Catcher.new
    port = start_server
    @s.add_observer @catcher
    @injector = BGP::Sim::Injector.new(
      'router_id' => '10.255.10.1', 'as' => OUR_AS,
      'neighbors' => [{ 'address' => '127.0.0.1', 'as' => PEER_AS, 'connect' => true,
                        'port' => port, 'retry' => 0.2, 'hold_time' => 30 }])
    @http = BGP::Sim::Http.new(BGP::Sim::Views.new(@injector), @injector,
                               :bind => '127.0.0.1', :port => 0)
    @injector.start
    @http.start
    @url = @http.url
    assert(wait { @s.is_established? }, 'the session did not come up')
    # The KEEPALIVE that takes the session to Established is not an
    # UPDATE, so the catcher is empty here and stays empty until asked.
  end

  def teardown
    @http.stop if @http
    @injector.stop if @injector
    stop_server
    Log.set_filename(STDERR)
    FileUtils.remove_entry(@dir) if @dir
  end

  # ---- the client ----------------------------------------------------

  def get(path)
    JSON.parse(Net::HTTP.get(URI("#{@url}#{path}")))
  end

  # **Written as routescope's driver writes it**, header spelling
  # included, because that is the line a bgp4r driver will be.
  def post(path, body = {}, header = 'routescope')
    headers = { 'Content-Type' => 'application/json' }
    headers['X-BGP4R'] = header if header
    r = Net::HTTP.post(URI("#{@url}#{path}"), JSON.generate(body), headers)
    [r.code.to_i, JSON.parse(r.body)]
  end

  # What `exit(r.code.to_i < 300 ? 0 : 1)` makes of a reply, which is
  # the whole of how a refusal reaches a scenario.
  def exit_status(code) ; code < 300 ? 0 : 1 ; end

  def wait(seconds = 10)
    deadline = Time.now + seconds
    loop do
      return true if yield
      return false if Time.now > deadline
      sleep 0.05
    end
  end

  # ---- it is up and it is silent --------------------------------------

  def test_the_api_answers_over_a_real_socket
    s = get('/api/status')
    assert_equal('10.255.10.1', s['router_id'])
    assert_equal(OUR_AS, s['as'])
    assert_equal('established', s['peers'].first['state'])
    assert_equal(1, s['summary']['established'])
  end

  # **It starts silent**, which is the rule a scenario's baseline rests
  # on: the peer holds nothing until an action asks.
  def test_it_starts_silent
    assert_equal(0, @catcher.size, 'an UPDATE arrived with nobody having asked for one')
    assert_equal(0, get('/api/sent')['summary']['prefixes_sent'])
    assert_equal([], get('/api/sent')['routes']['rows'])
  end

  # ---- an announcement crosses ---------------------------------------

  # **The two halves.** An HTTP request reaches this process and another
  # BGP speaker reads the UPDATE it asked for, with the attributes it
  # asked for.
  def test_an_announcement_crosses_the_session
    code, answer = post('/api/announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100,
                                         'communities' => ['65001:7'])
    assert_equal(200, code, answer.inspect)
    assert_equal(1, answer['updates'])
    u = @catcher.shift
    assert_not_nil(u, 'the peer never read an UPDATE')
    assert_equal(['10.1.0.0/24'], u.nlri.to_ary)
    assert_equal(100, u.path_attribute[:multi_exit_disc].to_i)
    assert_equal('65001:7', u.path_attribute[:communities].communities)
    assert_equal('65001', u.path_attribute[:as_path].as_path)
    assert_equal(0, u.path_attribute.errors.size,
                 'an ordinary announcement is not a protocol error')
  end

  def test_an_attribute_change_crosses_and_keeps_the_rest
    post('/api/announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100,
                          'communities' => ['65001:7'])
    @catcher.shift
    assert_equal(200, post('/api/attribute', 'prefixes' => ['10.1.0.0/24'], 'med' => 7).first)
    u = @catcher.shift
    assert_equal(7, u.path_attribute[:multi_exit_disc].to_i)
    assert_equal('65001:7', u.path_attribute[:communities].communities)
  end

  def test_a_withdrawal_crosses_the_session
    post('/api/announce', 'prefixes' => ['10.1.0.0/24'])
    @catcher.shift
    assert_equal(200, post('/api/withdraw', 'prefixes' => ['10.1.0.0/24']).first)
    u = @catcher.shift
    assert_equal(['10.1.0.0/24'], u.withdrawn.to_ary)
  end

  # ---- a feed --------------------------------------------------------

  # A generated range answers at once and streams behind, which is what
  # lets a console show a feed: `finished_at` is nil while it runs.
  def test_a_generated_range_streams_and_is_reported_as_a_feed
    code, answer = post('/api/announce',
                        'generate' => { 'start' => '11.0.0.0/28', 'count' => 300,
                                        'per_update' => 50 })
    assert_equal(200, code, answer.inspect)
    assert_equal(1, answer['feeds'].size)
    assert_equal('11.0.0.0/28 x 300', answer['feeds'].first['range'])
    assert(wait { get('/api/sent')['summary']['prefixes_sent'] == 300 },
           "the feed did not finish: #{get('/api/sent')['summary'].inspect}")
    feed = get('/api/sent')['feeds'].first
    assert_equal(300, feed['prefixes_sent'])
    assert_equal(6, feed['updates_sent'], '300 prefixes, 50 per UPDATE')
    assert_equal(false, feed['running'])
    assert_not_nil(feed['finished_at'])
    # And the peer really read them, in six UPDATEs.
    assert(wait { @catcher.size >= 6 })
    prefixes = @catcher.to_a.flat_map { |u| u.nlri.to_ary }
    assert_equal(300, prefixes.size)
    assert_equal('11.0.0.0/28', prefixes.first)
    # 299 steps of 16 addresses from 11.0.0.0, which is 4784. **The
    # hand written expectation here was wrong first** and said
    # 11.0.4.176; the library was right, which is the usual way round in
    # this repository. Computed and pasted, as CLAUDE.md asks.
    assert_equal('11.0.18.176/28', prefixes.last)
  end

  def test_a_generated_range_is_withdrawn_by_regenerating_it
    post('/api/announce', 'generate' => { 'start' => '11.0.0.0/28', 'count' => 100,
                                          'per_update' => 50 })
    assert(wait { @catcher.size >= 2 })
    @catcher.clear
    assert_equal(200, post('/api/withdraw',
                           'generate' => { 'start' => '11.0.0.0/28', 'count' => 100,
                                           'per_update' => 50 }).first)
    assert(wait { @catcher.size >= 2 })
    withdrawn = @catcher.to_a.flat_map { |u| u.withdrawn.to_ary }
    assert_equal(100, withdrawn.size)
    assert_equal('11.0.0.0/28', withdrawn.first)
  end

  # ---- a fault -------------------------------------------------------

  # **A fault case crosses and the receiver reports it**, which is the
  # one assertion no unit test can make: `validation.rb` runs on octets
  # that crossed a socket rather than on octets a test wrote.
  #
  # `origin_value` and not `origin_length`, and the reason is a bug in
  # the library this change found and did not fix: a received UPDATE
  # carrying a zero length ORIGIN kills a bgp4r receiver's event
  # dispatch thread, because `Neighbor#dispatch_event` builds
  # `"Recv #{msg}"` before the log level is looked at and `Origin#encode`
  # raises on a value `Origin.new` accepted. The pull request has the
  # one liner. 17 of the 18 catalog cases render, so this test uses one
  # that does and the injector's own side is unaffected either way.
  def test_a_fault_case_crosses_and_the_receiver_reports_it
    code, answer = post('/api/fault', 'case' => 'origin_value',
                                      'prefixes' => ['203.0.113.0/24'])
    assert_equal(200, code, answer.inspect)
    assert_equal('origin_value', answer['case'])
    u = @catcher.shift
    assert_not_nil(u, 'the faulty UPDATE never arrived')
    assert_equal(['203.0.113.0/24'], u.nlri.to_ary)
    assert_equal(1, u.path_attribute.errors.size,
                 'the receiver read it as exactly one protocol error')
    finding = u.path_attribute.errors.first
    assert_equal(:treat_as_withdraw, finding.action)
    assert_equal(true, @s.is_established?, 'and the session survived, which is the point')
  end

  # ---- a replay ------------------------------------------------------

  # The octets go out as they came in, which is what the
  # keep-what-you-cannot-read work exists to make possible.
  def test_a_capture_is_replayed_byte_for_byte
    hex = BGP::Update.new(
      BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_001),
                              BGP::Next_hop.new('10.0.0.1')),
      BGP::Nlri.new('10.9.0.0/24')).to_shex
    code, answer = post('/api/replay', 'hex' => hex)
    assert_equal(200, code, answer.inspect)
    u = @catcher.shift
    assert_not_nil(u, 'the replayed octets never arrived')
    assert_equal(hex, u.to_shex, 'octet for octet')
  end

  # ---- sessions ------------------------------------------------------

  # **`session.stop` really keeps it down**, which `Neighbor#stop` alone
  # does not: the active side reconnects every `retry` seconds, so
  # without the administrative flag a stopped session would come back
  # and the API would have reported stopping something it did not.
  #
  # And when it is let back up, what was announced goes again, which is
  # what a `session.flap` in a scenario depends on: a peer that has just
  # re-established holds nothing.
  def test_a_session_stops_and_what_was_announced_comes_back_with_it
    post('/api/announce', 'prefixes' => ['10.1.0.0/24'], 'med' => 100)
    assert_not_nil(@catcher.shift)

    assert_equal(200, post('/api/session/stop', {}).first)
    assert(wait { !@s.is_established? }, 'the session did not go down')
    sleep 0.6 # longer than retry, so a reconnect would have happened
    assert_equal(false, @s.is_established?, 'it came back while administratively down')
    assert_equal('idle', get('/api/peers').first['state'])

    @catcher.clear
    assert_equal(200, post('/api/session/start', {}).first)
    assert(wait { @s.is_established? }, 'the session did not come back')
    u = @catcher.shift
    assert_not_nil(u, 'nothing was re-announced, so a flap would lose the route for good')
    assert_equal(['10.1.0.0/24'], u.nlri.to_ary)
    assert_equal(100, u.path_attribute[:multi_exit_disc].to_i)
  end

  def test_a_notification_crosses_with_a_code_no_rfc_defines
    code, answer = post('/api/notification', 'code' => 199, 'subcode' => 254,
                                             'data' => 'deadbeef')
    assert_equal(200, code, answer.inspect)
    assert_equal(199, answer['code'])
    assert(wait { !@s.is_established? },
           'a NOTIFICATION ends the session, whatever its code')
  end

  def test_a_route_refresh_crosses
    assert_equal(200, post('/api/refresh', 'afi' => 1, 'safi' => 1).first)
  end

  # ---- the refusals --------------------------------------------------

  # **A POST without the header is refused over a real socket**, and the
  # 403 reaches a driver as a non-zero exit status.
  def test_a_post_without_the_header_is_refused
    code, answer = post('/api/announce', { 'prefixes' => ['10.1.0.0/24'] }, nil)
    assert_equal(403, code)
    assert_equal(1, exit_status(code))
    assert_match(/X-BGP4R/, answer['error'])
    assert_equal(0, @catcher.size, 'and nothing went on the wire')
  end

  # **The header is matched whatever its case and this is where that is
  # proved**: `Net::HTTP` sends `X-Bgp4r` for the `X-BGP4R` written
  # above, so a case sensitive match would make every test in this file
  # that posts fail with a 403.
  def test_net_http_capitalises_the_header_and_it_is_still_accepted
    sent = header_net_http_puts_on_the_wire
    assert_equal('X-Bgp4r: routescope', sent,
                 'Net::HTTP capitalises per word, which is the measurement this rests on')
    assert_equal(200, post('/api/session/start', {}).first)
  end

  def test_a_refused_action_is_a_4xx_a_driver_can_act_on
    [['/api/announce', { 'bogus' => 1 }, 400],
     ['/api/fault', { 'case' => 'no_such_case' }, 400],
     ['/api/replay', { 'hex' => 'odd' }, 400],
     ['/api/announce', { 'prefixes' => ['10.1.0.0/24'], 'peer' => '10.9.9.9' }, 400]].each do |path, body, want|
      code, answer = post(path, body)
      assert_equal(want, code, "#{path} #{body.inspect}: #{answer.inspect}")
      assert_equal(1, exit_status(code))
      assert_not_equal('', answer['error'].to_s, "#{path}: a refusal with no reason")
    end
    assert_equal(0, @catcher.size, 'a refused action sends nothing')
  end

  def test_an_unknown_path_is_a_404_naming_the_paths
    r = Net::HTTP.get_response(URI("#{@url}/api/nonsense"))
    assert_equal('404', r.code)
    assert_match(%r{/api/announce}, JSON.parse(r.body)['error'])
  end

  def test_the_index_names_every_path
    index = get('/')
    assert_equal(BGP::VERSION, index['bgp4r'])
    assert_equal(5, index['reads'].size)
    assert_equal(10, index['actions'].size)
  end

  # **An injector a console can kill by accident is worse than one with
  # no API.** Each of these is something a console or a person really
  # sends, and after every one it still answers.
  def test_nothing_a_client_sends_takes_the_process_down
    raw("GET\r\n\r\n")
    assert_still_alive
    raw("POST /api/announce HTTP/1.1\r\nX-Bgp4r: routescope\r\n" \
        "Content-Length: 7\r\n\r\nnotjson")
    assert_still_alive
    raw("POST /api/announce HTTP/1.1\r\nX-Bgp4r: routescope\r\n" \
        "Content-Length: 99999\r\n\r\n{}")  # a length it does not send
    assert_still_alive
    raw("GET /api/status HTTP/1.1\r\nX-#{'a' * 9000}: 1\r\n\r\n")
    assert_still_alive
    # Half a request and then gone.
    s = TCPSocket.new('127.0.0.1', @http.port)
    s.write('GET /api/sta')
    s.close
    assert_still_alive
  end

  def test_many_clients_at_once_are_all_answered
    answers = 8.times.collect { Thread.new { get('/api/status')['as'] } }.collect(&:value)
    assert_equal([OUR_AS] * 8, answers)
  end

  # ---- events --------------------------------------------------------

  # The shape over the wire: all seven fields of `Event#to_h`, which is
  # what makes a driver's mapping a rename of `peer` and nothing else.
  def test_the_events_are_bgp4rs_own_shape_over_the_wire
    post('/api/announce', 'prefixes' => ['10.1.0.0/24'])
    answer = get('/api/events?since=0')
    assert(answer['seq'] >= 5, "only #{answer['seq']} events: #{answer.inspect}")
    kinds = answer['events'].collect { |e| e['kind'] }
    assert_include(kinds, 'session')
    assert_include(kinds, 'route')
    event = answer['events'].find { |e| e['kind'] == 'route' }
    %w[seq time level kind peer message data].each do |k|
      assert(event.key?(k), "#{k} is missing from an event on the wire")
    end
    assert_equal(['10.1.0.0/24'], event['data']['prefixes'])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, event['time'])
    # `since` is where a reader resumes from.
    assert(get("/api/events?since=#{answer['seq']}")['events'].empty?)
  end

  # ---- the command line ----------------------------------------------

  # `bgp4r-sim` from its own argv, end to end: the flags, the YAML file,
  # the log file, the Injector and the HTTP API. Nothing else runs
  # `start`, which is what the executable calls.
  def test_the_whole_command_line_starts_an_injector_that_answers
    @http.stop
    @injector.stop
    @http = @injector = nil
    config = File.join(@dir, 'sim.yml')
    log = File.join(@dir, 'sim.log')
    File.write(config, <<~YAML)
      router_id: 10.255.10.2
      as: 65002
      neighbors: []
    YAML
    out, err = StringIO.new, StringIO.new
    sim = BGP::Sim::Server.new(out, err)
    Log.create(StringIO.new)
    begin
      assert_equal(0, sim.start([config, '--api', '127.0.0.1:0', '-l', log], {}, :wait => false),
                   err.string)
      status = JSON.parse(Net::HTTP.get(URI("#{sim.http.url}/api/status")))
      assert_equal('10.255.10.2', status['router_id'])
      assert_equal(65_002, status['as'])
      assert_equal([], status['peers'])
      assert_equal(0, status['summary']['rib'], 'an injector holds no Loc-RIB')
      assert_match(/bgp4r-sim #{Regexp.escape(BGP::VERSION)} up/, File.read(log))
      assert_match(/silent until asked/, File.read(log))
    ensure
      sim.stop
    end
  end

  # ---- routegen ------------------------------------------------------

  # **The third way into the generator, end to end**, which is the claim
  # docs/daemon.md makes: the `generate` block of an announce action,
  # this subcommand, and a node file's announce block, with one
  # implementation under all three. Here the peer reads what the
  # subcommand sent, which is the only thing that says the subcommand
  # really goes through the action.
  def test_the_routegen_subcommand_sends_a_range_and_reports_it
    port = release_the_session
    out, err = StringIO.new, StringIO.new
    status = BGP::Sim::Routegen.new(out, err).start(
      ['--peer', '127.0.0.1', '--peer-as', PEER_AS.to_s, '--my-as', OUR_AS.to_s,
       '--port', port.to_s, '--count', '20', '--per-update', '5',
       '--med', '42', '--timeout', '15', '-l', File.join(@dir, 'routegen.log')])
    assert_equal(0, status, err.string)
    assert_match(/session to 127\.0\.0\.1 up/, out.string)
    assert_match(/20 prefixes in 4 updates/, out.string)
    prefixes = @catcher.to_a.flat_map { |u| u.nlri.to_ary }
    assert_equal(20, prefixes.size, 'the peer did not read the whole range')
    assert_equal('11.0.0.0/28', prefixes.first)
  end

  # The node file form, which is the same code path with the blocks read
  # out of YAML. It is also what proves the blocks are moved out of the
  # config: left in, the Speaker would send each one as well and the
  # peer would read 40 prefixes.
  def test_the_routegen_subcommand_reads_a_node_file
    port = release_the_session
    config = File.join(@dir, 'routegen.yml')
    File.write(config, <<~YAML)
      router_id: 10.255.10.3
      as: #{OUR_AS}
      neighbors:
        - address: 127.0.0.1
          as: #{PEER_AS}
          connect: true
          port: #{port}
      announce:
        - generate: { start: 11.0.0.0/28, count: 20, per_update: 5 }
          med: 42
    YAML
    out, err = StringIO.new, StringIO.new
    status = BGP::Sim::Routegen.new(out, err).start(
      [config, '--timeout', '15', '-l', File.join(@dir, 'routegen.log')])
    assert_equal(0, status, err.string)
    prefixes = @catcher.to_a.flat_map { |u| u.nlri.to_ary }
    assert_equal(20, prefixes.size,
                 'twice this many means the Speaker sent the block as well')
  end

  private

  # Stops the injector of `setup` so the test server's one Neighbor is
  # free for another session, and answers the port it listens on.
  def release_the_session
    port = @s.socket.local_address.ip_port
    @http.stop
    @injector.stop
    @http = @injector = nil
    assert(wait { !@s.is_established? }, 'the first session did not end')
    @catcher.clear
    port
  end

  # One raw request line and whatever follows it, with no client.
  def raw(text)
    s = TCPSocket.new('127.0.0.1', @http.port)
    s.write(text)
    s.wait_readable(2)
    s.close
  rescue SystemCallError, IOError
    nil
  end

  def assert_still_alive
    assert_equal(OUR_AS, get('/api/status')['as'], 'the injector stopped answering')
  end

  # What `Net::HTTP` really puts on a socket for the header this file
  # writes as `X-BGP4R`. Measured rather than recalled, because the
  # whole POST path rests on it.
  def header_net_http_puts_on_the_wire
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      c = server.accept
      head = String.new
      head << c.readpartial(4096) until head.include?("\r\n\r\n")
      body = '{}'
      c.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
      c.close
      head
    end
    Net::HTTP.post(URI("http://127.0.0.1:#{server.addr[1]}/api/announce"), '{}',
                   'X-BGP4R' => 'routescope', 'Content-Type' => 'application/json')
    thread.value.lines.collect(&:chomp).find { |l| l.downcase.start_with?('x-bgp4r') }
  ensure
    server.close if server
  end

end
