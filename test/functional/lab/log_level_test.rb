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

# The speaker's log level: LAB_LOG_LEVEL overrides log_level in the node file.
#
#   ruby -I. test/functional/lab/log_level_test.rb

require 'test/unit'
require_relative 'lab_helper'
require_relative '../../../lab/speaker'

class LabLogLevelTest < Test::Unit::TestCase
  include LabHelper

  def test_default_is_info
    assert_equal(Logger::INFO, Lab::Speaker.log_level({}, {}))
  end

  def test_node_file_sets_the_level
    assert_equal(Logger::DEBUG, Lab::Speaker.log_level({ 'log_level' => 'debug' }, {}))
  end

  def test_env_overrides_the_node_file
    assert_equal(Logger::DEBUG, Lab::Speaker.log_level({ 'log_level' => 'info' }, 'LAB_LOG_LEVEL' => 'debug'))
    assert_equal(Logger::INFO, Lab::Speaker.log_level({ 'log_level' => 'debug' }, 'LAB_LOG_LEVEL' => 'INFO'))
  end

  def test_empty_env_falls_back_to_the_node_file
    assert_equal(Logger::WARN, Lab::Speaker.log_level({ 'log_level' => 'warn' }, 'LAB_LOG_LEVEL' => ''))
  end

  def test_unknown_level_is_an_error
    e = assert_raise(ArgumentError) { Lab::Speaker.log_level({}, 'LAB_LOG_LEVEL' => 'loud') }
    assert_match(/debug, info, warn/, e.message)
  end

  # Two speakers on loopback with LAB_LOG_LEVEL=debug: the decoded UPDATE
  # shows in the receiver's log. At info it does not.
  def test_debug_prints_decoded_messages
    debug = run_pair('debug')
    assert_match(/^D, /, debug, 'debug lines expected')
    assert_match(%r{192\.168\.1\.0/24}, debug, 'decoded UPDATE prefixes expected at debug')
    info = run_pair('info')
    assert_no_match(/^D, /, info)
    assert_match(/RecvUpdate/, info)
  end

  private

  def run_pair(level)
    port = Local.free_port
    r1 = { 'router_id' => '10.10.0.1', 'as' => 65001, 'listen_address' => '127.0.0.1', 'port' => port,
           'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65002 }],
           'announce' => [{ 'prefixes' => ['192.168.1.0/24'] }] }
    r2 = { 'router_id' => '10.10.0.2', 'as' => 65002,
           'neighbors' => [{ 'address' => '127.0.0.1', 'as' => 65001, 'port' => port, 'connect' => true, 'retry' => 0.5 }] }
    lab = Local.new({ 'r1' => r1, 'r2' => r2 }, env: { 'LAB_LOG_LEVEL' => level })
    lab.up
    wait_routes(lab, 'r2', '127.0.0.1', ['192.168.1.0/24'])
    sleep 0.5 # let the log line for the UPDATE reach the file
    lab.log('r2')
  ensure
    lab.down if lab
  end
end
