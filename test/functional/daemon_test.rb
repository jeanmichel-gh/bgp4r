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

# bgp4rd over its real socket, and the only test that can say the two
# halves of a line agree.
#
#   ruby -I. test/functional/daemon_test.rb
#
# **Why it has to be here and not in test/unit/daemon/.** Every unit
# test on the server side reads a request Hash a test wrote, and every
# one on the client side reads an answer a fake client wrote, so neither
# can say what `Api` puts on a socket is what `Client` takes off it.
# That is the same argument test/functional/flow_spec_test.rb makes for
# the four NLRI wiring sites.
#
# It needs no privilege, no router and no second machine: the control
# socket is a path in a temporary directory, and the one TCP port is for
# a session nobody dials.

require 'test/unit'
require 'json'
require 'socket'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon'

class BGP_Daemon_Functional_Test < Test::Unit::TestCase

  # A port nothing else here uses, for the listener the daemon opens.
  # Nobody dials it: what is under test is the control socket.
  PORT = 17_903

  def setup
    @dir = Dir.mktmpdir
    @socket = File.join(@dir, 'bgp4rd.sock')
    @out, @err = StringIO.new, StringIO.new
    @server = BGP::Daemon::Server.new(@out, @err)
    config = BGP::Daemon::Server.with_defaults(
      'as' => 65_000, 'router_id' => '10.0.0.1',
      'listen_address' => '127.0.0.1', 'port' => PORT,
      'state_file' => File.join(@dir, 'state.json'),
      'neighbors' => [{ 'address' => '127.0.0.9', 'as' => 65_001, 'description' => 'inj1' }])
    assert_not_nil(@server.build(config, :socket => @socket),
                   "the daemon did not start: #{@err.string}")
    @server.speaker.rib.originate('10.255.0.0/24', :path_attribute => pa)
    @server.speaker.rib.originate('10.255.1.0/24', :path_attribute => pa)
    @server.speaker.rib.drain
  end

  def teardown
    @server.stop if @server
    FileUtils.remove_entry(@dir) if @dir
  end

  # One request line in, one reply line out. **Written exactly as
  # routescope's own client writes it**, read in routescope at `7eabde1`,
  # because the bgp4r driver will be that one liner with the paths
  # changed and a mismatch is a wrong answer rather than a missing one.
  def raw(line)
    s = UNIXSocket.new(@socket)
    s.write(line)
    reply = s.gets
    s.close
    reply
  end

  def routescope_client(method, params = {})
    reply = raw("#{JSON.generate(:id => 1, :method => method, :params => params)}\n")
    JSON.parse(reply || '')
  end

  def test_the_socket_is_there_and_is_a_socket
    assert_equal(true, File.socket?(@socket))
  end

  # The socket is born 0660, so access is by file permission and there
  # is no window in which umask leaves it open.
  def test_the_socket_is_not_world_reachable
    assert_equal(0, File.stat(@socket).mode & 0o007,
                 'a control socket anybody can write is a daemon anybody can drive')
  end

  def test_the_envelope_is_an_id_and_a_result
    r = routescope_client('show.status')
    assert_equal(1, r['id'])
    assert_equal(false, r.key?('error'))
    assert_equal('10.0.0.1', r['result']['router_id'])
    assert_equal(65_000, r['result']['as'])
  end

  def test_one_line_per_reply_and_nothing_more
    reply = raw("#{JSON.generate(:id => 1, :method => 'api.info', :params => {})}\n")
    assert_equal(1, reply.lines.size)
    assert_equal("\n", reply[-1])
  end

  # Several requests on one connection, each answered with its own id,
  # which is what makes a client able to keep a socket open.
  def test_a_connection_answers_request_after_request
    s = UNIXSocket.new(@socket)
    %w[api.info show.status show.peers show.routes show.rib].each_with_index do |m, i|
      s.write("#{JSON.generate(:id => i + 1, :method => m, :params => {})}\n")
      r = read_line(s)
      assert_equal(i + 1, r['id'], "#{m} answered the wrong id")
      assert_equal(false, r.key?('error'), "#{m}: #{r['error']}")
    end
    s.close
  end

  def test_the_read_methods_answer_over_the_socket
    assert_equal(1, routescope_client('show.peers')['result'].size)
    assert_equal('127.0.0.9', routescope_client('show.peers')['result'].first['address'])
    assert_equal('inj1', routescope_client('show.peers')['result'].first['description'])
    assert_equal(2, routescope_client('show.routes')['result']['total'])
    assert_equal(2, routescope_client('show.rib')['result']['total'])
    assert_match(/10\.255\.0\.0\/24/, routescope_client('show.text')['result'])
  end

  # The page envelope crosses the socket with its cursor, which is what
  # a caller walks a million prefixes with.
  def test_a_page_crosses_the_socket_with_its_cursor
    first = routescope_client('show.routes', 'limit' => 1)['result']
    assert_equal(2, first['total'])
    assert_equal(1, first['rows'].size)
    assert_equal(1, first['next_offset'])
    second = routescope_client('show.routes', 'limit' => 1, 'offset' => 1)['result']
    assert_equal('10.255.1.0/24', second['rows'].first['prefix'])
    assert_nil(second['next_offset'])
  end

  # Symbol keys become Strings, which is the one thing JSON does to the
  # views on the way out, so a driver reads Strings everywhere.
  def test_every_key_and_symbol_value_arrives_as_a_string
    row = routescope_client('show.rib')['result']['rows'].first
    assert_equal('only_route', row['decided_by'])
    assert_equal('igp', row['paths'].first['origin'])
    assert_equal('ebgp', routescope_client('show.peers')['result'].first['type'])
  end

  # **A daemon a console can kill by accident is worse than one with no
  # API.** Each of these is something a console or a person really
  # sends, and after every one the daemon still answers.
  def test_an_unknown_method_is_an_error_line_and_not_a_crash
    r = routescope_client('show.nonsense')
    assert_equal(1, r['id'])
    assert_match(/unknown method/, r['error'])
    assert_match(/show\.status/, r['error'], 'the refusal names the methods that exist')
    assert_still_alive
  end

  def test_a_line_that_is_not_json_is_answered_and_the_daemon_lives
    r = JSON.parse(raw("this is not json\n"))
    assert_match(/bad JSON/, r['error'])
    assert_still_alive
  end

  def test_a_line_that_is_json_but_not_an_object_is_answered
    r = JSON.parse(raw("[1,2,3]\n"))
    assert_match(/a request is a JSON object/, r['error'])
    assert_still_alive
  end

  def test_a_request_too_long_to_read_ends_that_connection_only
    r = JSON.parse(raw("#{'x' * (BGP::Daemon::Api::MAX_LINE + 10)}\n"))
    assert_match(/longer than/, r['error'])
    assert_still_alive
  end

  # A method that raises comes back as an error on that request and the
  # connection goes on taking requests.
  def test_a_method_that_refuses_its_parameters_answers_and_lives
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'show.routes', :params => { :limit => 'lots' })}\n")
    assert_match(/limit must be an integer/, read_line(s)['error'])
    s.write("#{JSON.generate(:id => 2, :method => 'api.info', :params => {})}\n")
    assert_equal(2, read_line(s)['id'], 'the connection still takes requests')
    s.close
    assert_still_alive
  end

  # Half a request and then gone. The server thread for it ends; nothing
  # else does.
  def test_a_client_that_disappears_mid_request_takes_nothing_with_it
    s = UNIXSocket.new(@socket)
    s.write('{"id":1,"method":"show.sta')
    s.close
    assert_still_alive
  end

  def test_many_clients_at_once_are_all_answered
    socks = Array.new(8) { UNIXSocket.new(@socket) }
    socks.each_with_index { |s, i| s.write("#{JSON.generate(:id => i, :method => 'api.info')}\n") }
    socks.each_with_index { |s, i| assert_equal(i, read_line(s)['id']) }
    socks.each(&:close)
    assert_still_alive
  end

  # bgp4r-cli against the real daemon, both forms, which is the only
  # thing that says the client and the server agree about a line.
  def test_the_cli_reads_the_daemon_in_both_forms
    status, out, err = cli(['-s', @socket, 'show.peers'])
    assert_equal(0, status, err)
    assert_equal('127.0.0.9', JSON.parse(out).first['address'])

    status, out, err = cli(['-s', @socket, '-c', 'show bgp summary'])
    assert_equal(0, status, err)
    assert_match(/BGP router identifier 10\.0\.0\.1/, out)
    assert_match(/^127\.0\.0\.9\s+65001\s+idle/, out)

    status, out, err = cli(['-s', @socket, '-c', 'show bgp'])
    assert_equal(0, status, err)
    assert_match(/10\.255\.0\.0\/24/, out)
  end

  def test_the_cli_carries_a_refusal_out_as_an_exit_status
    status, out, err = cli(['-s', @socket, 'show.nonsense'])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/unknown method/, err)
  end

  def test_the_socket_environment_variable_reaches_the_cli
    status, out, _e = cli(['show.peers'], 'BGP4R_SOCKET' => @socket)
    assert_equal(0, status)
    assert_equal('127.0.0.9', JSON.parse(out).first['address'])
  end

  # Stopping takes the socket away, so a second daemon on the same path
  # is not refused by a file nobody is listening on.
  def test_stopping_removes_the_socket
    @server.stop
    assert_equal(false, File.exist?(@socket))
    @server = nil
  end

  # A socket with a daemon behind it is refused; one left by a daemon
  # that died is taken over.
  def test_a_second_daemon_on_the_same_path_is_refused
    other = BGP::Daemon::Api.new(@server.views, :path => @socket)
    assert_raise(BGP::Daemon::Api::InUse) { other.start }
  end

  def test_a_socket_left_behind_by_a_dead_daemon_is_taken_over
    @server.stop
    @server = nil
    FileUtils.mkdir_p(File.dirname(@socket))
    stale = UNIXServer.new(@socket)
    stale.close # the path stays, with nothing listening
    assert_equal(true, File.socket?(@socket))
    api = BGP::Daemon::Api.new(nil, :path => @socket)
    assert_nothing_raised { api.start }
    api.stop
  end

  # `bgp4rd` from its own command line, end to end: the flags, the YAML
  # file, the log file, the Speaker and the socket. Nothing else runs
  # `start`, which is what the executable calls.
  #
  # It is here and not in a unit test because it opens a log: `Log` is
  # the library's one logger and `Log.set_filename` replaces it for
  # every other test in the process, so this file puts it back.
  def test_the_whole_command_line_starts_a_daemon_that_answers
    @server.stop
    @server = nil
    config = File.join(@dir, 'bgp4rd.yml')
    log = File.join(@dir, 'bgp4rd.log')
    sock = File.join(@dir, 'from-the-command-line.sock')
    File.write(config, <<~YAML)
      router_id: 10.0.0.2
      as: 65002
      listen_address: 127.0.0.1
      port: #{PORT + 1}
      neighbors: []
    YAML
    out, err = StringIO.new, StringIO.new
    daemon = BGP::Daemon::Server.new(out, err)
    # **A logger before the daemon's, which is what makes the --log
    # assertion below mean something.** `Log.create` is `@@logger ||=
    # new(s)`, so in a fresh process it and `Log.set_filename` agree and
    # a test that starts the daemon first passes against either. Here
    # there is already a logger, as there is in any long-lived process,
    # so only the forcing form writes to the file.
    Log.create(StringIO.new)
    begin
      assert_equal(0, daemon.start(['-f', config, '-s', sock, '-l', log], {}, :wait => false),
                   err.string)
      assert_equal(true, File.socket?(sock))
      s = UNIXSocket.new(sock)
      s.write("#{JSON.generate(:id => 1, :method => 'show.status', :params => {})}\n")
      r = read_line(s)
      s.close
      assert_equal('10.0.0.2', r['result']['router_id'])
      assert_equal(65_002, r['result']['as'])
      assert_equal([], r['result']['peers'])
      # A table is on with no rib key, because a daemon is a router.
      assert_equal(0, r['result']['summary']['rib'])
      # --log FILE really wrote there, which Log.create would not have.
      assert_match(/bgp4rd #{Regexp.escape(BGP::VERSION)} up/, File.read(log))
      assert_match(/socket #{Regexp.escape(sock)}/, File.read(log))
      # **And the ring saw the same line, which is the whole claim
      # `show.log` rests on**: the ring sits in front of the real
      # destination, so it sees every line the library formats wherever
      # in the library it was written, and the file still gets them.
      s = UNIXSocket.new(sock)
      s.write("#{JSON.generate(:id => 2, :method => 'show.log', :params => {})}
")
      lines = read_line(s)['result']
      s.close
      assert_operator(lines['kept'], :>, 0, 'the daemon logged at least its own startup line')
      assert_equal(BGP::Daemon::LogRing::KEEP, lines['keeps'])
      assert_equal(true, lines['lines'].any? { |l| l =~ /bgp4rd #{Regexp.escape(BGP::VERSION)} up/ },
                   'the line in the file is the line in the ring')
      s = UNIXSocket.new(sock)
      s.write("#{JSON.generate(:id => 3, :method => 'show.log', :params => { 'count' => 1 })}
")
      assert_equal(1, read_line(s)['result']['lines'].size)
      s.close
    ensure
      daemon.stop
      Log.set_filename(STDERR)
    end
  end

  # ====================================================================
  # The write side over the socket

  def test_the_write_methods_answer_over_the_socket
    r = routescope_client('route.originate', 'prefix' => '10.255.9.0/24', 'med' => 7)
    assert_equal(['10.255.9.0/24'], r['result']['originated'])
    assert_equal(3, routescope_client('show.routes')['result']['total'])
    assert_equal(7, routescope_client('show.routes', 'prefix' => '10.255.9.0/24')['result']['rows']
                                     .first['med'])
    r = routescope_client('route.withdraw', 'prefix' => '10.255.9.0/24')
    assert_equal(['10.255.9.0/24'], r['result']['withdrawn'])
    assert_equal(2, routescope_client('show.routes')['result']['total'])
    assert_still_alive
  end

  def test_the_peer_methods_answer_over_the_socket
    assert_equal(true, routescope_client('peer.stop', 'peer' => '127.0.0.9')['result']['shutdown'])
    assert_equal(true, @server.speaker.peer('127.0.0.9').shutdown?)
    assert_equal(false, routescope_client('peer.start', 'peer' => '127.0.0.9')['result']['shutdown'])
    assert_equal(true, routescope_client('peer.clear', 'peer' => '127.0.0.9')['result']['cleared'])
    assert_equal(false, @server.speaker.peer('127.0.0.9').shutdown?)
    assert_still_alive
  end

  def test_a_write_methods_refusal_crosses_the_socket_as_an_error
    assert_match(/no neighbor "9\.9\.9\.9"/,
                 routescope_client('peer.stop', 'peer' => '9.9.9.9')['error'])
    assert_match(/prefix or prefixes is required/,
                 routescope_client('route.originate')['error'])
    assert_match(/not established/,
                 routescope_client('peer.refresh', 'peer' => '127.0.0.9')['error'])
    assert_still_alive
  end

  def test_the_new_read_methods_answer_over_the_socket
    page = routescope_client('show.adj_in', 'peer' => '127.0.0.9')['result']
    assert_equal(%w[limit next_offset offset rows total], page.keys.sort)
    out = routescope_client('show.adj_out', 'peer' => '127.0.0.9')['result']
    assert_equal(%w[limit next_offset offset rows skipped total], out.keys.sort)
    fib = routescope_client('show.fib')['result']
    assert_equal(false, fib['fib']['configured'],
                 'no fib: in the configuration, which is not the same as an empty table')
    assert_equal(%w[fib limit next_offset offset rows total], fib.keys.sort)
  end

  # **This daemon was built without going through the command line, so it
  # set up no logging and keeps no ring**, and `show.log` says so rather
  # than answering as though the log were empty. The ring itself is
  # asserted in test_the_whole_command_line_starts_a_daemon_that_answers,
  # which is the only test here that calls `start`.
  def test_show_log_says_when_nothing_is_kept
    lines = routescope_client('show.log')['result']
    assert_equal([], lines['lines'])
    assert_equal(0, lines['keeps'], 'keeps 0 says nothing is kept at all')
  end

  # ====================================================================
  # events.subscribe, which is the one method that answers many lines

  # **The exact line shapes**, because routescope's driver reads them:
  # one `result` line carrying where the stream starts and how many kept
  # events it replayed, then one `event` line each.
  def test_a_subscription_answers_a_result_line_then_one_event_per_line
    @server.speaker.events.publish(:kind => :log, :message => 'before the subscription')
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 2, :method => 'events.subscribe', :params => { 'since' => 0 })}\n")
    r = read_line(s)
    assert_equal(2, r['id'])
    assert_equal(1, r['result']['replayed'], 'the kept event above since 0')
    assert_equal(1, r['result']['seq'], 'where the stream has got to')
    assert_nil(r['result']['kinds'], 'every kind, since none was named')
    replay = read_line(s)
    assert_equal('before the subscription', replay['event']['message'])
    @server.speaker.events.publish(:kind => :session, :peer => '127.0.0.9',
                                   :message => 'Active -> Established',
                                   :data => { :state => :Established })
    ev = read_line(s)['event']
    assert_equal(%w[data kind level message peer seq time], ev.keys.sort)
    assert_equal('session', ev['kind'])
    assert_equal('127.0.0.9', ev['peer'],
                 "bgp4r's own key where ospfv2 has interface: BGP has no circuits")
    assert_equal('Established', ev['data']['state'])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, ev['time'])
    s.close
    assert_still_alive
  end

  def test_a_subscription_with_no_since_replays_nothing_and_starts_here
    @server.speaker.events.publish(:kind => :log, :message => 'already happened')
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe')}\n")
    r = read_line(s)
    assert_equal(0, r['result']['replayed'])
    assert_equal(1, r['result']['seq'])
    @server.speaker.events.publish(:kind => :log, :message => 'and this one is live')
    assert_equal('and this one is live', read_line(s)['event']['message'])
    s.close
  end

  def test_a_kind_filter_is_echoed_and_keeps_the_other_kinds_out
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe',
                             :params => { 'kinds' => ['notification'] })}\n")
    assert_equal(['notification'], read_line(s)['result']['kinds'])
    @server.speaker.events.publish(:kind => :log, :message => 'not this one')
    @server.speaker.events.publish(:kind => :notification, :peer => '127.0.0.9',
                                   :message => 'this one')
    assert_equal('this one', read_line(s)['event']['message'])
    s.close
  end

  # **Without a keepalive a reader cannot tell a quiet lab from a socket
  # that died**, which is the gap-against-quiet failure the synthetic
  # overflow event exists for one step further on. This daemon's
  # interval is shortened so the test does not wait fifteen seconds.
  def test_a_quiet_stream_says_so_rather_than_going_silent
    api = BGP::Daemon::Api.new(@server.views, :path => "#{@socket}.ka", :keepalive => 0.2).start
    begin
      s = UNIXSocket.new(api.path)
      s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe')}\n")
      read_line(s)
      line = read_line(s)
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, line['keepalive'])
      assert_kind_of(Integer, line['seq'])
      s.close
    ensure
      api.stop
    end
  end

  # The stream ends and the same connection takes requests again, which
  # is what keeps a console from needing a second socket to stop
  # watching.
  def test_unsubscribing_ends_the_stream_and_the_connection_takes_requests
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe')}\n")
    read_line(s)
    assert_equal(1, @server.speaker.events.subscribers)
    s.write("#{JSON.generate(:id => 2, :method => 'events.unsubscribe')}\n")
    r = read_line(s)
    assert_equal(2, r['id'])
    assert_equal(true, r['result']['unsubscribed'])
    s.write("#{JSON.generate(:id => 3, :method => 'api.info')}\n")
    assert_equal(BGP::VERSION, read_line(s)['result']['version'])
    s.close
    assert_equal(0, @server.speaker.events.subscribers, 'and the subscription is gone')
  end

  # Refused and the stream lives: a request answered mid stream would
  # interleave with the event lines, and dropping the stream over a
  # stray line would lose the events the caller asked for.
  def test_another_request_mid_stream_is_refused_and_the_stream_goes_on
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe')}\n")
    read_line(s)
    s.write("#{JSON.generate(:id => 9, :method => 'show.status')}\n")
    r = read_line(s)
    assert_equal(9, r['id'])
    assert_match(/only events\.unsubscribe/, r['error'])
    @server.speaker.events.publish(:kind => :log, :message => 'still streaming')
    assert_equal('still streaming', read_line(s)['event']['message'])
    s.close
  end

  # An unsubscribe with no subscription is an error on that request and
  # the connection goes on, because a console can send anything.
  def test_unsubscribing_without_a_subscription_is_an_error_and_not_a_crash
    r = JSON.parse(raw("#{JSON.generate(:id => 1, :method => 'events.unsubscribe')}\n"))
    assert_match(/not subscribed/, r['error'])
    assert_still_alive
  end

  def test_a_kind_nobody_publishes_is_refused_and_the_connection_lives
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe',
                             :params => { 'kinds' => ['nonsense'] })}\n")
    assert_match(/unknown event kind/, read_line(s)['error'])
    s.write("#{JSON.generate(:id => 2, :method => 'api.info')}\n")
    assert_equal(2, read_line(s)['id'], 'the connection still takes requests')
    s.close
    assert_equal(0, @server.speaker.events.subscribers)
  end

  # A subscriber that walks away leaves no subscription behind, or a
  # long running daemon accumulates one per console that ever watched.
  def test_a_subscriber_that_disappears_leaves_no_subscription
    s = UNIXSocket.new(@socket)
    s.write("#{JSON.generate(:id => 1, :method => 'events.subscribe')}\n")
    read_line(s)
    assert_equal(1, @server.speaker.events.subscribers)
    s.close
    deadline = Time.now + 5
    sleep 0.05 while @server.speaker.events.subscribers > 0 && Time.now < deadline
    assert_equal(0, @server.speaker.events.subscribers)
    assert_still_alive
  end

  # bgp4r-cli's stream form against the real daemon, which is the only
  # thing that says the client reads what the server writes line by line
  # rather than one reply.
  def test_the_cli_reads_a_stream_from_the_real_daemon
    @server.speaker.events.publish(:kind => :log, :message => 'one kept event')
    out, err = StringIO.new, StringIO.new
    client = BGP::Daemon::Client.new(@socket, {})
    lines = []
    client.stream('events.subscribe', 'since' => 0) do |line|
      lines << line
      lines.size < 2
    end
    client.close
    assert_equal(2, lines.size)
    assert_equal(1, lines[0]['result']['replayed'])
    assert_equal('one kept event', lines[1]['event']['message'])
    assert_equal('', err.string)
    assert_equal('', out.string)
    assert_equal(0, @server.speaker.events.subscribers,
                 'returning false from the block unsubscribed')
  end

  # ====================================================================
  # peer.refresh on a session that is really up

  # **The only test that puts a ROUTE-REFRESH on a wire from the control
  # socket.** Everything else about refresh is a refusal, because a
  # message needs a session, and a session needs two speakers. RFC 2918
  # section 3 is the message and RFC 7313 section 3.2 the subtype.
  def test_a_route_refresh_reaches_the_peer_over_a_real_session
    peer = Catcher.new(:my_as => 65_001, :remote_addr => '127.0.0.1', :id => '10.0.0.9')
    peer.capability :route_refresh
    server = TCPServer.new('127.0.0.1', PORT + 7)
    begin
      ours = @server.speaker.peer('127.0.0.9')
      client = TCPSocket.new('127.0.0.1', PORT + 7)
      accepted = server.accept
      Thread.new { peer.start(:session => accepted, :timeout => 10) }
      ours.instance_variable_set(:@neighbor, neighbor_on(client))
      assert_equal(true, wait_until { ours.neighbor.is_established? }, 'the session came up')

      r = routescope_client('peer.refresh', 'peer' => '127.0.0.9')
      assert_equal(1, r['result']['afi'])
      assert_equal(1, r['result']['safi'])
      assert_equal(0, r['result']['subtype'], 'RFC 2918, which is RFC 7313 subtype 0')
      assert_equal(true, wait_until { peer.refreshes.size == 1 })
      assert_equal(1, peer.refreshes.first.afi)
      assert_equal(BGP::Route_refresh::NORMAL, peer.refreshes.first.subtype)

      # RFC 7313 section 3.2's subtypes, by name and by number, and a
      # value the RFC does not define, because building never validates.
      routescope_client('peer.refresh', 'peer' => '127.0.0.9', 'afi' => 2, 'safi' => 128,
                        'subtype' => 'borr')
      assert_equal(true, wait_until { peer.refreshes.size == 2 })
      assert_equal([2, 128, BGP::Route_refresh::BORR],
                   [peer.refreshes.last.afi, peer.refreshes.last.safi,
                    peer.refreshes.last.subtype])
      routescope_client('peer.refresh', 'peer' => '127.0.0.9', 'subtype' => 200)
      assert_equal(true, wait_until { peer.refreshes.size == 3 })
      assert_equal(200, peer.refreshes.last.subtype,
                   'a subtype no RFC defines still goes on the wire')
    ensure
      ours.instance_variable_get(:@neighbor)&.close
      peer.close
      server.close
    end
  end

  # ---- the candidate configuration ----
  #
  # **Written as routescope's Config pane calls them**, in the order it
  # calls them, read in `Drivers::Ospfd` at `7eabde1`: that is the whole
  # point of putting them here rather than only in
  # test/unit/daemon/candidate_test.rb. A unit test reads a Hash a test
  # wrote; this reads what crossed a socket, and the shapes a driver
  # depends on are the ones a JSON round trip can quietly change. A bare
  # boolean is the one to watch: `true` survives, where a Symbol or a
  # Hash would arrive as something the driver cannot use.

  def test_the_config_methods_answer_over_the_socket
    assert_equal(false, routescope_client('config.changed')['result'])
    assert_equal([], routescope_client('config.compare')['result'])
    assert_equal([], routescope_client('config.history')['result'])
    text = routescope_client('show.configuration', 'format' => 'set')['result']
    assert_match(/^set as 65000$/, text)
    assert_match(/^set neighbors 127\.0\.0\.9 description inj1$/, text)
  end

  # `Drivers::Ospfd#running_config` uses the answer as a boolean
  # directly, so it has to arrive as one and not as a String or a Hash.
  def test_config_changed_crosses_the_socket_as_a_boolean
    assert_equal(FalseClass, routescope_client('config.changed')['result'].class)
    routescope_client('config.load', 'lines' => ['set log_level warn'])
    assert_equal(TrueClass, routescope_client('config.changed')['result'].class)
  ensure
    routescope_client('config.discard')
  end

  # `load_candidate` sends the startup file as `lines:` and reads
  # `['errors']`, treating an empty Array as success. Then `candidate`
  # asks `config.compare` and `config.commit` with `check: true`, and
  # `commit_candidate` commits with a comment and raises unless `['ok']`.
  # That is one pass of the pane, over the socket.
  def test_a_whole_pass_of_the_config_pane_crosses_the_socket
    lines = BGP::Daemon::Config.to_set(@server.candidate.running)
    edited = lines.map { |l| l.sub('description inj1', 'description inj2') }
    assert_equal([], routescope_client('config.replace', 'lines' => edited)['result']['errors'])
    assert_equal(true, routescope_client('config.changed')['result'])
    assert_equal(['set neighbors 127.0.0.9 description inj2'],
                 routescope_client('config.compare')['result'])
    check = routescope_client('config.commit', 'check' => true)['result']
    assert_equal(true, check['ok'])
    assert_equal([], check['errors'])
    done = routescope_client('config.commit', 'comment' => 'from the pane')['result']
    assert_equal(true, done['ok'])
    assert_equal('inj2', @server.speaker.peer('127.0.0.9').description)
    assert_equal('from the pane', routescope_client('config.history')['result'].first['comment'])
    assert_equal(false, routescope_client('config.changed')['result'])
  end

  # The one that matters most, because it is the answer this repository
  # least wants to give wrongly: a key that cannot change refuses the
  # commit, and the running configuration goes on being true.
  def test_a_commit_that_cannot_be_done_is_refused_over_the_socket
    routescope_client('config.load', 'lines' => ['set router_id 9.9.9.9'])
    r = routescope_client('config.commit', 'check' => true)['result']
    assert_equal(false, r['ok'])
    assert_match(/router_id cannot change while bgp4rd runs/, r['errors'].first)
    assert_equal(false, routescope_client('config.commit')['result']['ok'])
    assert_equal('10.0.0.1', @server.speaker.router_id)
    assert_match(/^set router_id 10\.0\.0\.1$/,
                 routescope_client('show.configuration', 'format' => 'set')['result'])
    assert_still_alive
  ensure
    routescope_client('config.discard')
  end

  # A bounce is reported in `warnings`, which is the channel
  # docs/daemon.md names for it, and it crosses as an Array of Strings.
  def test_a_bounce_crosses_the_socket_as_a_warning
    routescope_client('config.load', 'lines' => ['set neighbors 127.0.0.9 hold_time 90'])
    r = routescope_client('config.commit')['result']
    assert_equal(true, r['ok'])
    assert_match(/was bounced/, r['warnings'].first)
    assert_equal(90, @server.speaker.peer('127.0.0.9').config['hold_time'])
  end

  def test_the_rollback_pane_crosses_the_socket
    routescope_client('config.load', 'lines' => ['set neighbors 127.0.0.9 description two'])
    routescope_client('config.commit', 'comment' => 'one')
    # What the pane lists: a row per commit, newest first, which it
    # labels with its own index as the rollback number.
    rows = routescope_client('config.history')['result']
    assert_equal(1, rows.size)
    assert_equal(%w[time comment changes].sort, rows.first.keys.sort)
    assert_equal(1, routescope_client('config.rollback', 'number' => 1)['result']['rollback'])
    assert_equal(['set neighbors 127.0.0.9 description inj1'],
                 routescope_client('config.compare')['result'])
    assert_equal(true, routescope_client('config.discard')['result']['discarded'])
  end

  def test_a_config_refusal_crosses_the_socket_as_an_error_line
    r = routescope_client('config.rollback', 'number' => 9)
    assert_nil(r['result'])
    assert_match(/rollback 9 does not exist/, r['error'])
    assert_still_alive
  end

  def test_the_cli_prints_the_configuration_as_set_lines
    status, out, err = cli(['-s', @socket, '-c', 'show configuration'])
    assert_equal(0, status, err)
    assert_match(/^set as 65000$/, out)
  end


  private

  # A Neighbor that keeps the ROUTE-REFRESH messages it is sent.
  class Catcher < BGP::Neighbor
    def refreshes ; @refreshes ||= [] ; end

    def rcv_route_refresh(m)
      refreshes << m
      super
    end
  end

  # Our side of that session, started on an accepted socket.
  def neighbor_on(sock)
    n = BGP::Neighbor.new(:my_as => 65_000, :id => '10.0.0.1',
                          :remote_addr => '127.0.0.1', :local_addr => '127.0.0.1',
                          :events => @server.speaker.events)
    n.capability :route_refresh
    Thread.new { n.start(:session => sock, :timeout => 10) }
    n
  end

  # **One line of a stream, or a failure saying none came.** A bare
  # `gets` on a stream that went quiet blocks until the connection's
  # IDLE, which is fifteen minutes, so every sabotage aimed at the
  # stream would hang the suite rather than fail it, and a hang names
  # nothing. Measured: with the keepalive line taken out,
  # test_a_quiet_stream_says_so_rather_than_going_silent hung instead of
  # failing until this was here.
  def read_line(sock, timeout = 10)
    assert_not_nil(sock.wait_readable(timeout), "no line arrived within #{timeout}s")
    JSON.parse(sock.gets)
  end

  def wait_until(timeout = 10)
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now > deadline
    yield
  end

  def cli(argv, env = {})
    out, err = StringIO.new, StringIO.new
    status = BGP::Daemon::CLI.new(out, err).start(argv, env)
    [status, out.string, err.string]
  end

  # The daemon answers after whatever just happened to it.
  def assert_still_alive
    assert_equal(BGP::VERSION, routescope_client('api.info')['result']['version'],
                 'the daemon stopped answering')
  end

  def pa
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                            BGP::Next_hop.new('10.0.0.1'))
  end

end
