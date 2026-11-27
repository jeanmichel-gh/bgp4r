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

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'net/http'
require 'json'
require 'bgp/bmp/server'
require 'bgp/fault'

# bgp4r-bmp over loopback: a router dials in and sends FRR 10.5.1's
# capture, the station dials a router that listens, BGP::Fault::BMP is
# sent to it, and the HTTP API reads what it holds.
# docs/design/bgp-operations.md 8b, docs/bmp.md section 5.
class TestBmpStationServer < Test::Unit::TestCase
  include BGP::Bmp

  FIXTURE = File.expand_path('../fixtures/bmp/frr-10.5.1.bin', __dir__)

  def setup
    @out = StringIO.new
    @err = StringIO.new
  end

  def teardown
    @router&.close
    @server&.stop
  end

  def start(*args)
    @server = Server.new(@out, @err)
    assert_equal(0, @server.start(args.empty? ? %w[--listen 127.0.0.1:0 --api 127.0.0.1:0] : args, wait: false), @err.string)
  end

  def connect ; @router = TCPSocket.new('127.0.0.1', @server.station.port) ; end
  def get(path) ; JSON.parse(Net::HTTP.get(URI("#{@server.http.url}#{path}"))) ; end
  def lines ; @out.string.lines.collect { |l| JSON.parse(l) } ; end

  def wait_until(seconds = 5)
    deadline = Time.now + seconds
    until Time.now > deadline
      return true if yield
      sleep 0.05
    end
    false
  end

  def test_a_router_dials_in
    start
    connect
    @router.write(File.binread(FIXTURE))
    assert(wait_until { lines.size == 43 }, "#{lines.size} lines")
    routes = get('/api/routes?view=loc_rib')['routes']
    assert_equal(%w[203.0.113.0/24 192.0.2.0/24], routes.collect { |r| r['nlri']['prefix'] })
    assert_equal('bgp4r-lab-frr', routes.first['sys_name'])
    assert_equal(2, get('/api/peers')['peers'].size)
    assert_equal('bgp4r-lab-frr', get('/api/routers')['routers'].first['sys_name'])
    assert_equal(43, get('/api/lines')['seq'])
    assert_equal([42, 43], get('/api/lines?since=41')['lines'].collect { |l| l['seq'] })
    assert_equal(1, get('/api/status')['routers'])
    @router.close
    @router = nil
    assert(wait_until { lines.last['type'] == 'closed' })
    assert_equal('end of stream', lines.last['reason'])
    assert_equal([], get('/api/routers')['routers'])
    assert_equal('closed: BMP session closed: end of stream', get('/api/events')['events'].last['message'])
  end

  def test_the_api_reads_only
    start
    uri = URI("#{@server.http.url}/api/routes")
    req = Net::HTTP::Post.new(uri)
    req['X-BGP4R'] = 'routescope'
    req.body = '{}'
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    assert_equal([405, '/api/routes is a GET'], [res.code.to_i, JSON.parse(res.body)['error']])
    res = Net::HTTP.get_response(URI("#{@server.http.url}/api/routes?view=x"))
    assert_equal(400, res.code.to_i)
  end

  # The station dials, and dials again once the session ends.
  def test_the_station_dials
    listener = TCPServer.new('127.0.0.1', 0)
    start('--no-listen', '--connect', "127.0.0.1:#{listener.addr[1]}", '--api', '127.0.0.1:0')
    assert_nil(@server.station.port)
    sock = listener.accept
    sock.write(BGP::Fault.bmp_initiation)
    assert(wait_until { lines.size == 2 })
    assert_equal('initiation', lines.last['type'])
    sock.close
    assert(wait_until { lines.last['type'] == 'closed' })
    assert_match(/dialing 127\.0\.0\.1:\d+/, @err.string)
  ensure
    listener&.close
  end

  # BGP::Fault::BMP against bgp4r-bmp: what the station does with each,
  # the matrix of docs/protocol-testing.md.
  STATION_DOES = {
    :bmp_unknown_type => %w[initiation unknown],      # ignored, the session kept
    :bmp_version_0 => %w[undecoded closed],           # nothing framed past it
    :bmp_no_initiation => %w[peer_up],                # read, with a finding
  }.freeze

  def test_the_fault_catalog
    start
    assert_equal(BGP::Fault.bmp_names.sort, STATION_DOES.keys.sort, 'every case has an answer')
    STATION_DOES.each do |name, types|
      @out.truncate(0)
      @out.rewind
      connect
      BGP::Fault.bmp(name).each { |o| @router.write(o) }
      assert(wait_until { lines.size == types.size + 1 }, "#{name}: #{lines.collect { |l| l['type'] }}")
      assert_equal(['connected', *types], lines.collect { |l| l['type'] }, name)
      kept = !types.include?('closed')
      if kept
        @router.write(BGP::Fault.bmp_initiation)
        assert(wait_until { lines.last['type'] == 'initiation' }, "#{name}: the session is kept")
      end
      @router.close
      @router = nil
      assert(wait_until { lines.last['type'] == 'closed' }) if kept
    end
  end

  def test_the_findings_of_each_case
    start
    connect
    BGP::Fault.bmp(:bmp_no_initiation).each { |o| @router.write(o) }
    assert(wait_until { lines.size == 2 })
    assert_equal(['no_initiation'], lines.last['findings'].collect { |f| f['name'] })
    @router.close
    connect
    BGP::Fault.bmp(:bmp_version_0).each { |o| @router.write(o) }
    assert(wait_until { lines.any? { |l| l['reason'] == 'version 0' } })
    assert_equal(['version'], lines.find { |l| l['type'] == 'undecoded' }['findings'].collect { |f| f['name'] })
  end

  def test_the_lines_to_a_file
    Dir.mktmpdir('bmp') do |dir|
      file = File.join(dir, 'bmp.jsonl')
      start('--listen', '127.0.0.1:0', '--api', '127.0.0.1:0', '--lines', file)
      connect
      @router.write(BGP::Fault.bmp_initiation)
      assert(wait_until { File.read(file).lines.size == 2 })
      assert_equal('', @out.string)
      @server.stop
      @server = nil
    end
  end

  FREE = %w[--listen 127.0.0.1:0 --api 127.0.0.1:0].freeze

  def test_the_command_line
    s = Server.new(out = StringIO.new, err = StringIO.new)
    assert_equal(0, s.start(%w[--help] + FREE, wait: false))
    assert_match(/\AUsage: bgp4r-bmp/, out.string)
    assert_nil(s.http, 'help starts nothing')
    %w[--listen --connect --no-listen --api --lines --log --version --help].each { |o| assert_match(/ #{o} /, out.string, o) }
    examples = out.string.scan(%r{curl '?127\.0\.0\.1:8080(/api/\w+)}).flatten
    assert_equal(%w[/api/peers /api/routes], examples)
    examples.each { |p| assert_include(Http::READS.keys, p) }
    assert_match(%r{^See docs/bmp\.md\.$}, out.string)
    assert_equal(0, s.start(%w[-v] + FREE, wait: false))
    assert_match(/^#{Regexp.escape(BGP::VERSION)}$/, out.string)
    assert_nil(s.http, 'the version starts nothing')
    assert_equal(1, s.start(%w[--bogus] + FREE, wait: false))
    assert_match(/unknown argument "--bogus"/, err.string)
    assert_nil(s.http)
    assert_equal(1, s.start(%w[--no-listen --api 127.0.0.1:0], wait: false))
    assert_match(/--no-listen needs a --connect/, err.string)
    assert_nil(s.http)
    assert_equal(1, Server.new(StringIO.new, err = StringIO.new).start(%w[--listen nowhere --api 127.0.0.1:0], wait: false))
    assert_match(/\Abgp4r-bmp: api "nowhere"/, err.string)
    assert_equal({ :bind => '0.0.0.0', :port => 5000 }, Server.listen_address('5000'))
    assert_equal({ :bind => '127.0.0.1', :port => 5001 }, Server.listen_address('127.0.0.1:5001'))
  end

  # The station's paths and nothing of bgp4r-sim's: an action or a dry
  # run is not found.
  def test_no_path_of_the_sim
    start
    %w[/api/announce /api/plan].each do |path|
      uri = URI("#{@server.http.url}#{path}")
      req = Net::HTTP::Post.new(uri)
      req['X-BGP4R'] = 'routescope'
      req.body = '{}'
      res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
      assert_equal(404, res.code.to_i, path)
    end
  end

  def test_the_log
    Dir.mktmpdir('bmp') do |dir|
      log = File.join(dir, 'bmp.log')
      start('--listen', '127.0.0.1:0', '--api', '127.0.0.1:0', '--log', log)
      text = File.read(log)
      assert_match(/INFO -- : bgp4r-bmp #{Regexp.escape(BGP::VERSION)} up, routers on 127\.0\.0\.1:#{@server.station.port}, api #{Regexp.escape(@server.http.url)}$/, text)
      connect
      assert(wait_until { File.read(log).include?('connected: BMP session up') }, 'the log is written as it goes')
    end
  end

  def test_stop
    s = Server.new(StringIO.new, StringIO.new)
    assert_same(s, s.build(:listen => '127.0.0.1:0', :api => '127.0.0.1:0'))
    s.stop
    Dir.mktmpdir('bmp') do |dir|
      start('--listen', '127.0.0.1:0', '--api', '127.0.0.1:0', '--lines', File.join(dir, 'l.jsonl'))
      port, api = @server.station.port, @server.http.port
      lines = @server.instance_variable_get(:@lines_io)
      assert_same(@server, @server.stop)
      assert_raise(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', port) }
      assert_raise(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', api) }
      assert_true(lines.closed?)
      @server = nil
    end
  end

  # A failed start stops what it had started: here the listener, when
  # the API's port is taken.
  def test_a_failed_start_stops_the_rest
    taken = TCPServer.new('127.0.0.1', 0)
    s = Server.new(StringIO.new, err = StringIO.new)
    assert_equal(1, s.start(['--listen', '127.0.0.1:0', '--api', "127.0.0.1:#{taken.addr[1]}"], wait: false))
    assert_match(/\Abgp4r-bmp: .*Address already in use/, err.string)
    assert_raise(Errno::ECONNREFUSED) { TCPSocket.new('127.0.0.1', s.station.port) }
  ensure
    taken&.close
  end

  # TERM stops it and it exits 0.
  def test_a_signal_stops_it
    exe = File.expand_path('../../exe/bgp4r-bmp', __dir__)
    r, w = IO.pipe
    pid = spawn(RbConfig.ruby, exe, '--listen', '127.0.0.1:0', '--api', '127.0.0.1:0', :err => w, :out => File::NULL)
    w.close
    text = +''
    deadline = Time.now + 10
    until text.include?(' up, ') || Time.now > deadline
      text << r.readpartial(4096) if r.wait_readable(deadline - Time.now)
    end
    assert_include(text, ' up, ')
    port = Integer(text[/routers on 127\.0\.0\.1:(\d+)/, 1])
    router = TCPSocket.new('127.0.0.1', port)
    sleep 0.5
    assert_nil(Process.waitpid(pid, Process::WNOHANG), 'up until a signal')
    Process.kill('TERM', pid)
    _, status = Process.wait2(pid)
    text << r.read
    assert_equal(0, status.exitstatus)
    assert_match(/bgp4r-bmp stopping/, text)
    assert_match(/closed: BMP session closed: station stopped/, text)
  ensure
    router&.close
    r&.close
  end

  def test_the_program_runs
    exe = File.expand_path('../../exe/bgp4r-bmp', __dir__)
    out = IO.popen([RbConfig.ruby, exe, '--version'], &:read)
    assert_equal(BGP::VERSION, out.strip)
  end
end
