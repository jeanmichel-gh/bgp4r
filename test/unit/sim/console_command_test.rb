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


# `bgp4r console`'s command line, with no session and no irb:
# test/functional/console_test.rb runs the program.
#
#   ruby -I. test/unit/sim/console_command_test.rb

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim/console_command'
require 'bgp/sim/routegen'

class BGP_Sim_ConsoleCommand_Test < Test::Unit::TestCase

  # What the command does with the Console it builds.
  class FakeConsole
    attr_reader :connects, :listens, :arg
    attr_accessor :remote
    def initialize(arg = {}) ; @connects = [] ; @listens = [] ; @arg = arg ; end
    def connect(addr, **kw) ; @connects << [addr, kw] ; { :address => addr, :state => @state || 'Established' } ; end
    def listen(addr, **kw) ; @listens << [addr, kw] ; { :address => addr, :state => 'Active' } ; end
    def stop ; @stopped = true ; end
    def stopped? ; @stopped ; end
    attr_writer :state
  end

  # **No test here may reach irb**: it reads standard input, so a refusal
  # that fell through to it would hang the suite. The prompt is a lambda
  # that records, and the log goes nowhere.
  def setup
    @out = StringIO.new
    @err = StringIO.new
    @fake = FakeConsole.new
    @prompts = []
    @cmd = BGP::Sim::ConsoleCommand.new(@out, @err,
                                        :console => -> { @fake },
                                        :interact => ->(c) { @prompts << c },
                                        :load_irb => false)
  end

  def teardown
    Log.set_filename(STDERR)
  end

  def test_no_peer_opens_the_prompt_on_no_session
    assert_equal(0, @cmd.start(['-l', File::NULL]))
    assert_equal([@fake], @prompts)
    assert_empty(@fake.connects)
    assert(@fake.stopped?, 'exit stops what the prompt opened')
  end

  def test_peer_connects_before_the_prompt
    assert_equal(0, @cmd.start(['--peer', '10.0.0.2', '--peer-as', '65002', '-l', File::NULL]))
    assert_equal([['10.0.0.2', { :remote_as => 65_002, :local_as => 65_001,
                                 :router_id => '10.0.0.1', :wait => 30.0 }]], @fake.connects)
    assert_match(/session to 10\.0\.0\.2 is established$/, @out.string)
    assert_equal([@fake], @prompts)
  end

  def test_a_session_not_up_still_opens_the_prompt
    @fake.state = 'Active'
    assert_equal(0, @cmd.start(['--peer', '10.0.0.2', '--peer-as', '65002', '-l', File::NULL]))
    assert_match(/session to 10\.0\.0\.2 is active, still trying/, @out.string)
    assert_equal(1, @prompts.size)
  end

  def test_the_log_goes_to_a_file_it_names_unless_l_says
    @cmd.start([])
    assert_match(%r{console: logging to .*bgp4r-console-\d+\.log}, @out.string)
  ensure
    path = @out.string[/logging to (\S+)/, 1]
    File.delete(path) if path && File.exist?(path)
  end

  def test_help
    assert_equal(0, @cmd.start(['--help']))
    assert_match(/^Usage: bgp4r console/, @out.string)
    assert_equal('', @err.string)
  end

  # Every flag the parser takes is in the usage, so the two cannot drift.
  def test_the_usage_names_every_flag
    src = File.read(File.expand_path('../../../bgp/sim/console_command.rb', __dir__))
    flags = src.scan(/o\.on\((?:'-\w', )?'(--[\w-]+)/).flatten
    assert_operator(flags.size, :>=, 10)
    flags.each { |f| assert_match(/^\s+(-\w, )?#{f}\b/, BGP::Sim::ConsoleCommand::USAGE, f) }
  end

  def test_no_peer_means_no_session
    assert_nil(@cmd.connect_args({}))
  end

  def test_peer_and_peer_as_go_together
    assert_equal(1, @cmd.start(['--peer-as', '100']))
    assert_match(/--peer-as needs --peer/, @err.string)
    assert_equal(1, @cmd.start(['--peer', '10.0.0.2']))
    assert_match(/--peer needs --peer-as/, @err.string)
    assert_nil(@cmd.console, 'no console was built on a bad flag')
    assert_empty(@prompts, 'no prompt opened on a bad flag')
  end

  def test_a_word_where_a_number_goes_is_refused
    assert_equal(1, @cmd.start(['--peer', '10.0.0.2', '--peer-as', 'abc']))
    assert_match(/invalid value for Integer/, @err.string)
  end

  def test_an_unexpected_argument_is_refused
    assert_equal(1, @cmd.start(['10.0.0.2']))
    assert_match(/unexpected 10\.0\.0\.2/, @err.string)
  end

  def test_an_unknown_flag_is_refused
    assert_equal(1, @cmd.start(['--count', '3']))
    assert_match(/invalid option: --count/, @err.string)
  end

  def test_the_flags_become_connect_arguments
    addr, kw = @cmd.connect_args(:peer => '10.0.0.2', :peer_as => '65002', :my_as => '65010',
                                 :id => '10.9.9.9', :port => '1179', :local_address => '10.0.0.1',
                                 :timeout => '5')
    assert_equal('10.0.0.2', addr)
    assert_equal({ :remote_as => 65_002, :local_as => 65_010, :router_id => '10.9.9.9',
                   :wait => 5.0, :port => 1179, :local_address => '10.0.0.1' }, kw)
  end

  # The console and routegen open a session with the same defaults, so
  # `routegen --interact` and `console --peer` are the same session.
  def test_the_defaults_are_routegens
    _, kw = @cmd.connect_args(:peer => '10.0.0.2', :peer_as => '65002')
    assert_equal(BGP::Sim::Routegen::DEFAULT_AS, kw[:local_as])
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, kw[:router_id])
    assert_equal(BGP::Sim::ConsoleCommand::DEFAULT_TIMEOUT, kw[:wait])
    assert_equal(BGP::Sim::Routegen::DEFAULT_AS, BGP::Sim::Console::DEFAULT_AS)
    assert_equal(BGP::Sim::Routegen::DEFAULT_ID, BGP::Sim::Console::DEFAULT_ID)
  end

  # ---- --back-to-back --------------------------------------------------

  # A command whose Console lambda builds a second fake for the remote
  # side, and whose remote logger writes nowhere.
  def back_to_back_command
    @remote_fakes = []
    BGP::Sim::ConsoleCommand.new(@out, @err,
                                 :console => ->(*a) { a.empty? ? @fake : (@remote_fakes << FakeConsole.new(a[0])).last },
                                 :interact => ->(c) { @prompts << c },
                                 :remote_logger => ->(_level, _message) {},
                                 :load_irb => false)
  end

  def test_back_to_back_listens_then_the_remote_side_dials_it
    assert_equal(0, back_to_back_command.start(['--back-to-back', '-l', File::NULL]))
    assert_equal(1, @fake.listens.size)
    assert_empty(@fake.connects, 'our side listens and does not dial')
    remote = @remote_fakes.first
    assert_equal(1, @remote_fakes.size)
    assert_same(remote, @fake.remote, 'remote at the prompt is the second console')
    assert_equal('remote', remote.arg[:name])
    assert_respond_to(remote.arg[:factory], :call, 'the remote side builds its own injectors')
    laddr, near = @fake.listens.first
    raddr, far = remote.connects.first
    assert_equal(['127.0.0.1', '127.0.0.1'], [laddr, raddr])
    assert_equal('127.0.0.1', near[:local_address])
    assert_equal(near[:port], far[:port], 'the remote side dials the port we listen on')
    assert_operator(near[:port], :>, 1023, 'a free port, so no root')
    assert_equal([65_001, 65_002], [near[:local_as], near[:remote_as]])
    assert_equal([65_002, 65_001], [far[:local_as], far[:remote_as]])
    assert_not_equal(near[:router_id], far[:router_id])
    assert_equal(0, near[:wait], 'the listen answers at once so the dial can find it')
    assert_equal(30.0, far[:wait])
    assert_equal(near[:capabilities], far[:capabilities], 'both sides offer the same families')
    assert_match(/back to back on 127\.0\.0\.1 port \d+, AS 65001 to AS 65002, eBGP/, @out.string)
    assert_equal([@fake], @prompts, 'the prompt opens on our side')
    assert(@fake.stopped? && remote.stopped?, 'exit stops both sides')
  end

  def test_equal_as_numbers_make_it_ibgp
    back_to_back_command.start(['--back-to-back', '--my-as', '65010', '--peer-as', '65010', '-l', File::NULL])
    assert_match(/AS 65010 to AS 65010, iBGP/, @out.string)
    assert_equal(65_010, @remote_fakes.first.connects.first[1][:local_as])
  end

  def test_port_and_id_reach_both_sides
    back_to_back_command.start(['--back-to-back', '--port', '1790', '--id', '10.0.0.2', '-l', File::NULL])
    near = @fake.listens.first[1]
    far = @remote_fakes.first.connects.first[1]
    assert_equal([1790, 1790], [near[:port], far[:port]])
    assert_equal('10.0.0.2', near[:router_id])
    assert_equal('10.0.0.1', far[:router_id], 'the remote side takes another id rather than ours')
  end

  def test_back_to_back_refuses_what_it_cannot_use
    assert_equal(1, @cmd.start(['--back-to-back', '--peer', '10.0.0.2', '--peer-as', '1']))
    assert_match(/--peer and --back-to-back: one or the other/, @err.string)
    assert_equal(1, @cmd.start(['--families', 'ipv4']))
    assert_match(/--families needs --back-to-back/, @err.string)
    assert_equal(1, @cmd.start(['--back-to-back', '--local-address', '10.0.0.1']))
    assert_match(/both ends are on 127\.0\.0\.1/, @err.string)
    assert_equal(1, @cmd.start(['--back-to-back', '--families', 'ipv5']))
    assert_match(/no family ipv5\. The words are ipv4, ipv6, unicast/, @err.string)
    assert_nil(@cmd.console, 'no console was built on a bad flag')
    assert_empty(@prompts)
  end

  # Every family the build gate knows, by both AFIs where there are two,
  # plus a 4-octet AS and ROUTE-REFRESH.
  def test_every_family_is_offered_by_default
    caps = BGP::Sim::ConsoleCommand.capabilities
    fams = caps.select { |c| c.is_a?(Hash) }.collect { |c| c['mbgp'] }
    assert_equal(%w[as4_byte route_refresh], caps.reject { |c| c.is_a?(Hash) })
    BGP::Specimen.families.each { |_, afi, safi| assert_include(fams, [afi, safi]) }
    BGP::Sim::ConsoleCommand::IPV6.each do |name|
      safi = BGP::Specimen.families.assoc(name)[2]
      assert_include(fams, [2, safi], name.to_s)
    end
    assert_not_include(fams, [2, 132], 'RFC 4684 gives RT-constrain AFI 1 only')
    assert_equal(fams.uniq, fams)
  end

  def test_families_narrows_by_afi_or_by_name
    afis = ->(list) { BGP::Sim::ConsoleCommand.capabilities(list).select { |c| c.is_a?(Hash) }.collect { |c| c['mbgp'] } }
    assert(afis['ipv4'].all? { |afi, _| afi == 1 })
    assert(afis['ipv6'].all? { |afi, _| afi == 2 })
    assert_equal([[1, 1], [2, 1], [25, 70]], afis['unicast, evpn'])
    assert_equal(afis['ipv4'], afis['ipv4,ipv4'], 'a word twice is one family')
    assert_raise_message(/--families names nothing/) { afis[' , '] }
  end

  # Every capability the list names builds on a Neighbor, so a family the
  # gate knows and Mbgp does not cannot reach a session.
  def test_every_capability_builds
    n = BGP::Neighbor.new(4, 65_001, 180, '10.0.0.1', '127.0.0.1', '127.0.0.1')
    BGP::Sim::ConsoleCommand.capabilities.each do |c|
      name, args = c.is_a?(Hash) ? c.first : [c, []]
      assert_nothing_raised(c.inspect) { n.capability(name, *args) }
    end
  end

  # The remote side's log is ours with -remote before the extension.
  def test_the_remote_side_logs_beside_us
    require 'tmpdir'
    Dir.mktmpdir do |d|
      cmd = BGP::Sim::ConsoleCommand.new(@out, @err,
                                         :console => ->(*a) { a.empty? ? @fake : FakeConsole.new(a[0]) },
                                         :interact => ->(c) { @prompts << c }, :load_irb => false)
      assert_equal(0, cmd.start(['--back-to-back', '-l', File.join(d, 'c.log')]))
      assert_match(/the remote side logs to .*c-remote\.log/, @out.string)
      cmd.remote.arg[:factory] # built, and nothing was called on it
      assert(File.exist?(File.join(d, 'c-remote.log')))
    end
  end

end
