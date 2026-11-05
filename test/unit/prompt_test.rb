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

# BGP::Prompt on a host that is not the injector's Console, which is
# what the daemon's prompt will be. test/unit/sim/console_test.rb holds
# the same behaviour through the Console.
#
#   ruby -I. test/unit/prompt_test.rb

require 'test/unit'
require 'stringio'
require 'rbconfig'
require 'bgp4r'
require 'bgp/prompt'
require 'bgp/sim/console'

class BGP_Prompt_Test < Test::Unit::TestCase

  ROOT = File.expand_path('../..', __dir__)

  # The smallest host: VERBS and an initialize.
  class Host
    include BGP::Prompt
    VERBS = "one verb\n"
    def initialize(out, keep = BGP::Prompt::KEEP)
      initialize_prompt(out, keep)
    end
    public :tap
  end

  # A Neighbor as far as a tap is concerned: it takes observers and
  # hands each one a message.
  class FakeNeighbor
    attr_reader :observers
    def initialize ; @observers = [] ; end
    def add_observer(o) ; @observers << o ; end
    def deliver(msg) ; @observers.each { |o| o.update(msg) } ; end
  end

  FakePeer = Struct.new(:address, :neighbor)

  def setup
    @out = StringIO.new
    @h = Host.new(@out, 3)
  end

  # ---- standing alone ---------------------------------------------------

  # The daemon must get a prompt without the injector, so this file is
  # loaded in a child with nothing else required first.
  def test_it_loads_without_the_injector
    code = 'require "bgp/prompt"; print defined?(BGP::Sim::Injector).inspect, " ", BGP::Prompt::KEEP'
    out = ::IO.popen([RbConfig.ruby, '-I', ROOT, '-e', code], :err => [:child, :out], &:read)
    assert_equal('nil 200', out)
  end

  # ---- what the host gets -----------------------------------------------

  def test_verbs_prints_the_hosts_own_list
    @h.verbs
    assert_equal("one verb\n", @out.string)
  end

  def test_the_default_banner_names_verbs_and_exit
    assert_match(/'verbs' lists what to type, exit quits\./, @h.banner)
  end

  def test_received_keeps_the_last_n_and_last_answers_the_object
    5.times { |i| @h.received_from('10.0.0.1', "m#{i}") }
    list = @h.received(10)
    assert_equal(%w[m2 m3 m4], list.messages)
    assert_equal('m4', @h.last)
    assert_equal('', @out.string, 'received answers a list and prints nothing')
  end

  # ---- received and last, picked and chosen -------------------------------

  def keepalive ; BGP::Keepalive.new ; end

  def update(prefix)
    BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(0)), BGP::Nlri.new(prefix))
  end

  def fill
    h = Host.new(@out)
    h.received_from('10.0.0.1', update('10.1.0.0/24'))
    3.times { h.received_from('10.0.0.1', keepalive) }
    h.received_from('10.0.0.2', update('10.2.0.0/24'))
    h.received_from('10.0.0.2', keepalive)
    h
  end

  # The reported case: a keepalive every holdtime/3 seconds pushed the
  # UPDATE out of view and made `last` answer a Keepalive.
  def test_keepalives_are_left_out_by_default
    h = fill
    assert_kind_of(BGP::Update, h.last)
    assert_equal(['10.2.0.0/24'], h.last.nlri.to_ary)
    assert_equal(%i[update update], h.received.collect(&:kind))
  end

  def test_all_and_one_kind_can_be_asked_for
    h = fill
    assert_equal(6, h.received(:all).size)
    assert_equal(4, h.received(:keepalive).size)
    assert_kind_of(BGP::Keepalive, h.last(:keepalive))
    assert_kind_of(BGP::Keepalive, h.last(:all))
    assert_equal(%i[update keepalive], h.received(:all).last(2).collect(&:kind))
  end

  def test_a_count_and_a_kind_in_either_order
    h = fill
    assert_equal(2, h.received(2, :all).size)
    assert_equal(2, h.received(:all, 2).size)
    assert_equal(1, h.received(1).size)
    assert_equal(['10.2.0.0/24'], h.received(1).first.message.nlri.to_ary)
  end

  def test_one_peer_can_be_asked_for
    h = fill
    assert_equal(['10.1.0.0/24'], h.received(peer: '10.0.0.1').messages.collect { |m| m.nlri.to_ary }.flatten)
    assert_equal(['10.1.0.0/24'], h.last(peer: '10.0.0.1').nlri.to_ary)
    assert_nil(h.last(:notification))
  end

  # A list is an Array, so it can be indexed, selected and mapped, and
  # each row answers its message.
  def test_the_list_is_an_array_of_rows
    h = fill
    list = h.received(:all)
    assert_kind_of(Array, list)
    assert_kind_of(BGP::Update, list[0].message)
    assert_same(list[0].message, list[0].msg)
    assert_equal('10.0.0.1', list[0].peer)
    assert_kind_of(Time, list[0].at)
    assert_equal(2, list.select { |r| r.kind == :update }.size)
  end

  # irb shows the inspect, so a list reads as the lines `received` used
  # to print, and a row read alone is one of those lines.
  def test_the_list_reads_one_line_per_message
    h = fill
    lines = h.received(:all).inspect.lines
    assert_equal(6, lines.size)
    assert_match(/ 10\.0\.0\.1 Update, 1 prefixes, 0 withdrawn$/, lines.first)
    assert_match(/ 10\.0\.0\.2 Keepalive$/, lines.last)
    assert_equal(h.received.first.to_s, h.received.first.inspect)
    assert_equal('(none)', h.received(:notification).inspect)
  end

  # irb prints a result with pp, not inspect, which is how the first
  # version of this printed every field of every message.
  def test_pp_prints_the_same_lines
    require 'pp'
    h = fill
    assert_equal(h.received(:all).inspect + "\n", h.received(:all).pretty_inspect)
    assert_equal(h.received.first.to_s + "\n", h.received.first.pretty_inspect)
  end

  def test_an_unknown_kind_names_the_kinds
    e = assert_raise(ArgumentError) { fill.received(:updates) }
    assert_match(/no kind :updates; the kinds are update, keepalive/, e.message)
    assert_raise(ArgumentError) { fill.last(1.5) }
  end

  def test_each_message_class_has_its_kind
    assert_equal(:update, BGP::Prompt.kind(update('10.0.0.0/8')))
    assert_equal(:keepalive, BGP::Prompt.kind(keepalive))
    assert_equal(:notification, BGP::Prompt.kind(BGP::Notification.new(6, 2)))
    assert_equal(:open, BGP::Prompt.kind(BGP::Open.new(4, 100, 180, '10.0.0.1')))
    assert_equal(:route_refresh, BGP::Prompt.kind(BGP::Route_refresh.new(1, 1)))
    assert_equal(:route_refresh, BGP::Prompt.kind(BGP::Orf_route_refresh.new))
    assert_equal(:malformed, BGP::Prompt.kind(RuntimeError.new('x')))
    assert_equal(:other, BGP::Prompt.kind('m0'))
    assert_equal(BGP::Prompt::KINDS - [:keepalive], BGP::Prompt::DEFAULT_KINDS)
  end

  def test_last_is_nil_before_anything_arrives
    assert_nil(@h.last)
  end

  def test_watch_prints_as_it_arrives_and_quiet_stops_it
    @h.received_from('10.0.0.1', 'before')
    assert_equal('', @out.string)
    @h.watch
    assert(@h.watching?)
    @h.received_from('10.0.0.1', 'during')
    assert_match(/10\.0\.0\.1 during/, @out.string)
    assert_equal(true, @h.quiet)
    @out.truncate(0) ; @out.rewind
    @h.received_from('10.0.0.1', 'after')
    assert_equal('', @out.string)
  end

  # One tap per Neighbor object, since a peer gets a new Neighbor on
  # every reconnect and an old one keeps its observers.
  def test_one_tap_per_neighbor_and_a_new_neighbor_gets_its_own
    n1 = FakeNeighbor.new
    peer = FakePeer.new('10.0.0.1', n1)
    @h.tap(peer)
    @h.tap(peer)
    assert_equal(1, n1.observers.size)
    n1.deliver(BGP::Keepalive.new)
    assert_kind_of(BGP::Keepalive, @h.last(:all))
    n2 = FakeNeighbor.new
    @h.tap(FakePeer.new('10.0.0.1', n2))
    assert_equal(1, n2.observers.size)
  end

  def test_a_peer_with_no_session_is_not_tapped
    assert_nil(@h.tap(FakePeer.new('10.0.0.1', nil)))
  end

  def test_guide_prints_a_section_on_a_pipe
    @h.guide(5)
    assert_match(/^5\. Leaving$/, @out.string)
  end

  # ---- class level ------------------------------------------------------

  def test_describe_counts_both_fields_of_an_update
    u = BGP::Update.new(
      BGP::Path_attribute.new(
        BGP::Origin.new(0), BGP::As_path.new(1),
        BGP::Mp_reach.new(:afi => 2, :safi => 1, :nexthop => ['2001:db8::1'],
                          :nlris => ['2001:db8:1::/48', '2001:db8:2::/48'])),
      BGP::Nlri.new('10.0.0.0/8'))
    assert_equal('Update, 3 prefixes, 0 withdrawn', BGP::Prompt.describe(u))
    w = BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8', '10.1.0.0/16'))
    assert_equal('Update, 0 prefixes, 2 withdrawn', BGP::Prompt.describe(w))
  end

  def test_describe_a_message_an_exception_and_a_string
    assert_equal('Keepalive', BGP::Prompt.describe(BGP::Keepalive.new))
    assert_equal('malformed: bad', BGP::Prompt.describe(RuntimeError.new('bad')))
    assert_equal('Cease', BGP::Prompt.describe('Cease'))
  end

  # `require` is a Kernel method called on the module itself, so a
  # singleton method on it stands in for an irb that is not there.
  def test_a_missing_irb_says_how_to_get_it
    BGP::Prompt.define_singleton_method(:require) { |*| raise LoadError, 'no irb' }
    e = assert_raise(LoadError) { BGP::Prompt.load_irb }
    assert_equal(BGP::Prompt::IRB_MISSING, e.message)
    e = assert_raise(LoadError) { Host.load_irb }
    assert_equal(BGP::Prompt::IRB_MISSING, e.message)
  ensure
    BGP::Prompt.singleton_class.send(:remove_method, :require)
  end

  # The host answers the class methods its callers already use.
  def test_a_host_answers_describe_and_load_irb
    assert_equal('Cease', Host.describe('Cease'))
    assert_respond_to(Host, :load_irb)
  end

  # ---- the Console is a host --------------------------------------------

  # What moved is still reachable under the Console's own name, which is
  # how bgp/sim/ and the tests ask for it.
  def test_the_console_is_a_host_and_keeps_its_names
    c = BGP::Sim::Console
    assert(c.include?(BGP::Prompt))
    assert_equal(BGP::Prompt::KEEP, c::KEEP)
    assert_same(BGP::Prompt::IRB_MISSING, c::IRB_MISSING)
    assert_same(BGP::Prompt::Received, c::Received)
    assert_equal('Cease', c.describe('Cease'))
  end

  # One definition of the counting, which the injector's report uses.
  def test_the_injector_counts_with_the_prompts_counter
    w = BGP::Update.new(BGP::Withdrawn.new('10.0.0.0/8'))
    assert_equal(1, BGP::Sim::Injector.withdrawn_count(w))
    assert_equal(BGP::Prompt.withdrawn_count(w), BGP::Sim::Injector.withdrawn_count(w))
    assert_equal(0, BGP::Sim::Injector.prefix_count(w))
  end

end
