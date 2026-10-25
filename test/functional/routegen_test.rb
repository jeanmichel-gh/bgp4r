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

# Runs examples/routegen against the test BGP server over loopback.
#
#   ruby -I. test/functional/routegen_test.rb

require 'test/unit'
require 'bgp4r'
require 'test/helpers/server'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'timeout'

class TestRoutegen < Test::Unit::TestCase
  include BGP
  include BGP::TestHelpers

  ROOT = File.expand_path('../..', __dir__)
  ROUTEGEN = File.join(ROOT, 'examples', 'routegen')

  class Recorder
    attr_reader :updates, :prefixes, :attrs
    def initialize ; @updates, @prefixes, @attrs, @lock = 0, [], nil, Mutex.new ; end
    def update(msg)
      return unless msg.is_a?(BGP::Update) && msg.nlri
      @lock.synchronize do
        @updates += 1
        @prefixes.concat(msg.nlri.to_ary)
        @attrs ||= msg.path_attribute
      end
    end
    def count ; @lock.synchronize { @prefixes.size } ; end
  end

  def setup
    @port = start_server
    @rec = Recorder.new
    @s.add_observer @rec
    @dir = Dir.mktmpdir('routegen')
  end

  def teardown
    if @pid
      Process.kill('TERM', @pid) rescue nil
      Process.wait(@pid) rescue nil
    end
    stop_server
    FileUtils.rm_rf(@dir)
  end

  def test_sends_all_routes_with_their_attributes
    spawn_routegen(config('nlris' => '11.0.0.0/28, 300, 50'))
    wait_until('300 prefixes received') { @rec.count >= 300 }
    assert_equal(300, @rec.count)
    assert_equal(6, @rec.updates, '300 prefixes at 50 per UPDATE')
    assert_equal('11.0.0.0/28', @rec.prefixes.first, 'the first prefix is start itself')
    assert_equal('11.0.18.176/28', @rec.prefixes.last)
    assert_equal('100:1 200:1 300:1', @rec.attrs[:communities].communities, 'communities kept as written')
    assert_equal(100, @rec.attrs[:multi_exit_disc].to_i, 'MED is sent')
    assert_equal('100 90 80', @rec.attrs[:as_path].as_path)
    assert_equal('40.0.0.1', @rec.attrs[:next_hop].next_hop)
  end

  def test_stays_up_until_stopped_then_exits_cleanly
    spawn_routegen(config('nlris' => '11.0.0.0/28, 10, 10'))
    wait_until('routes received') { @rec.count >= 10 }
    sleep 1
    assert(@s.is_established?, 'routegen keeps the session up after sending')
    Process.kill('INT', @pid)
    status = wait_exit
    assert(status.success?, "routegen should exit 0 on Ctrl-C:\n#{output}")
    assert_match(/sent 10 prefixes, 11\.0\.0\.0\/28 to 11\.0\.0\.144\/28, in 1 updates/, output)
  end

  def test_exits_with_an_error_when_the_peer_goes_away
    spawn_routegen(config('nlris' => '11.0.0.0/28, 10, 10'))
    wait_until('routes received') { @rec.count >= 10 }
    stop_server
    status = wait_exit
    assert(!status.success?)
    assert_match(/session went down/, output)
  end

  def test_bad_config_is_reported
    spawn_routegen(config('nlris' => '2001:db8::/48, 10, 10'))
    status = wait_exit
    assert(!status.success?)
    assert_match(/only IPv4/, output)
  end

  private

  # The test server is AS 100, so this is an iBGP session, as in routegen.yml.
  def config(routes)
    {
      'neighbor' => {
        'router id' => '1.1.1.1', 'my as' => 100, 'holdtime' => 30,
        'neighbor address' => '127.0.0.1', 'port' => @port,
        'capabilities' => ['four byte as'], 'log level' => 'warn',
      },
      'routes' => {
        'next hop' => '40.0.0.1', 'local pref' => 100, 'med' => 100, 'origin' => 0,
        'communities' => '100:1 200:1 300:1', 'as path' => '100 90 80',
      }.merge(routes),
    }
  end

  def spawn_routegen(cfg)
    file = File.join(@dir, 'routegen.yml')
    File.write(file, cfg.to_yaml)
    @log = File.join(@dir, 'routegen.log')
    @pid = Process.spawn(RbConfig.ruby, "-I#{ROOT}", ROUTEGEN, file, out: @log, err: [:child, :out])
  end

  def output
    File.exist?(@log) ? File.read(@log) : ''
  end

  def wait_exit(timeout=10)
    Timeout.timeout(timeout) { _, status = Process.wait2(@pid) ; @pid = nil ; status }
  end

  def wait_until(what, timeout=20)
    deadline = Time.now + timeout
    until yield
      flunk("#{what} (waited #{timeout}s)\n#{output}") if Time.now > deadline
      sleep 0.1
    end
  end
end
