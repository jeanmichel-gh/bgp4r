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
# loopback: the verbs in process, then `bgp4r routegen --interact` as a
# program, driven by lines on its standard input the way a person types
# them. No privilege, no router, no Docker.
#
#   ruby -I. test/functional/console_test.rb

require 'test/unit'
require 'stringio'
require 'bgp4r'
require 'bgp/sim/console'
require 'test/helpers/server'
require 'rbconfig'

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
      io.puts 'exit'
      io.close_write
      io.read
    end
    assert_equal(0, $?.exitstatus, out)
    assert_match(/session to 127\.0\.0\.1 up/, out)
    assert_match(/"Established"/, out, 'the prompt answered a verb')
    u = @catcher.shift
    assert_kind_of(BGP::Update, u, 'nothing crossed: ' + out)
    assert_equal(['10.6.0.0/24'], nlri_of(u))
    assert_nil(@catcher.shift(0.5), 'it started silent: one UPDATE, the one typed')
    assert(wait { !@s.is_established? }, 'exit left the session up')
  end

end
