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
require 'rbconfig'
require 'bgp/observable'

class TestBgpObservable < Test::Unit::TestCase

  class Subject
    include BGP::Observable
    def fire(*args)
      changed
      notify_observers(*args)
    end
  end

  class Recorder
    attr_reader :calls
    def initialize ; @calls = [] ; end
    def update(*args) ; @calls << args ; end
    def other(*args) ; @calls << [:other, *args] ; end
  end

  def test_notify_calls_update_with_args
    s, r = Subject.new, Recorder.new
    s.add_observer r
    s.fire(:ev_msg, 1, 'x')
    assert_equal([[:ev_msg, 1, 'x']], r.calls)
  end

  def test_custom_func
    s, r = Subject.new, Recorder.new
    s.add_observer r, :other
    s.fire(42)
    assert_equal([[:other, 42]], r.calls)
  end

  def test_notify_needs_changed_and_resets_it
    s, r = Subject.new, Recorder.new
    s.add_observer r
    s.notify_observers(:ignored)
    assert_equal([], r.calls)
    s.changed
    assert s.changed?
    s.notify_observers(:once)
    assert ! s.changed?
    s.notify_observers(:ignored)
    assert_equal([[:once]], r.calls)
  end

  def test_changed_and_notify_idiom_used_by_bgp4r
    # bgp4r writes: changed and notify_observers(...)
    s, r = Subject.new, Recorder.new
    s.add_observer r
    s.changed and s.notify_observers(:ev_conn_reset)
    assert_equal([[:ev_conn_reset]], r.calls)
  end

  def test_add_observer_without_func_raises
    assert_raise(NoMethodError) { Subject.new.add_observer(Object.new) }
  end

  def test_count_and_delete
    s, r1, r2 = Subject.new, Recorder.new, Recorder.new
    assert_equal(0, s.count_observers)
    s.delete_observer(r1)
    s.add_observer r1
    s.add_observer r2
    assert_equal(2, s.count_observers)
    s.delete_observer r1
    s.fire(:a)
    assert_equal([], r1.calls)
    assert_equal([[:a]], r2.calls)
    s.delete_observers
    assert_equal(0, s.count_observers)
  end

  def test_observer_may_delete_itself_while_notified
    s = Subject.new
    quitter = Object.new
    quitter.define_singleton_method(:update) { |*| s.delete_observer(self) }
    r = Recorder.new
    s.add_observer quitter
    s.add_observer r
    s.fire(:a)
    assert_equal(1, s.count_observers)
    assert_equal([[:a]], r.calls)
  end

  def test_neighbor_and_io_use_this_module
    require 'bgp4r'
    assert BGP::Neighbor.include?(BGP::Observable)
    assert BGP::IO::Output.include?(BGP::Observable)
    assert BGP::IO::Input.include?(BGP::Observable)
  end

  def test_bgp4r_does_not_load_the_observer_library
    # Ruby 3.4 moved 'observer' out of the default gems. Under Bundler it
    # can't load unless listed in the Gemfile, and bgp4r has no runtime gems.
    root = File.expand_path('../..', __dir__)
    code = 'require "bgp4r"; puts $LOADED_FEATURES.grep(%r{/observer\.rb\z}).size'
    out = IO.popen([RbConfig.ruby, '-W0', "-I#{root}", '-e', code], err: [:child, :out], &:read)
    assert_equal('0', out.strip, out)
  end

end
