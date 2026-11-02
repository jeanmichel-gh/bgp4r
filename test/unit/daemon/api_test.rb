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

# The request envelope and the method registry, with no socket:
# Api#handle takes a request Hash and answers a response Hash, which is
# why it is shaped that way. The socket itself is
# test/functional/daemon_test.rb, which is the only thing that can say
# the two halves of a line agree.
#
#   ruby -I. test/unit/daemon/api_test.rb

require 'test/unit'
require 'bgp/daemon/api'

class BGP_Daemon_Api_Test < Test::Unit::TestCase

  def setup
    @speaker = BGP::Daemon::Speaker.new('as' => 65_000, 'router_id' => '10.0.0.1', 'rib' => true,
                                        'neighbors' => [{ 'address' => '10.0.0.2', 'as' => 65_001 }])
    @speaker.start_rib
    @speaker.rib.originate('10.255.0.0/24', :path_attribute => pa)
    @speaker.rib.drain
    @api = BGP::Daemon::Api.new(BGP::Daemon::Views.new(@speaker))
  end

  def req(method, params = {}, id = 1)
    @api.handle('id' => id, 'method' => method, 'params' => params)
  end

  # Request and reply, as routescope's one line client writes and reads
  # them: an id, a method, params in; the same id and a result out.
  def test_a_reply_carries_the_id_it_was_asked_with
    r = req('show.status', {}, 42)
    assert_equal(42, r[:id])
    assert_equal(false, r.has_key?(:error))
    assert_equal('10.0.0.1', r[:result][:router_id])
  end

  # **Not stubbed, named.** The methods this daemon does not have are
  # each their own later piece of work, and an unknown one answers the
  # list rather than nothing, which is the shape Events#publish answers
  # an unknown kind with. The streams are in that list too, since a
  # reader guessing a name wants every name.
  def test_an_unknown_method_names_the_ones_there_are
    r = req('show.nonsense')
    assert_nil(r[:result])
    assert_match(/unknown method "show\.nonsense"/, r[:error])
    BGP::Daemon::Api.names.each { |m| assert_match(/#{Regexp.escape(m)}/, r[:error]) }
    BGP::Daemon::Api::STREAM_METHODS.each { |m| assert_match(/#{Regexp.escape(m)}/, r[:error]) }
  end

  # **Two sided, because the example in it has expired once already.**
  # **Every method docs/daemon.md's table names now answers**, so there
  # is no design left in it. This guard asserted the opposite half for
  # `config.*` until the candidate configuration landed; it is
  # re-pointed rather than taken out, because what it is for is keeping
  # the document and the registry in step.
  #
  # **The nine a console calls are routescope's and not this
  # document's**, read in `Drivers::Ospfd` at `7eabde1`, and the table in
  # docs/daemon.md named three of them. A driver that answers
  # `candidate?` true needs all nine: `discard_candidate`, `rollbacks`
  # and `load_rollback` are each a route in routescope's `app.rb`, and
  # `Config#with_candidate` refuses the whole pane without them.
  DRIVER_CALLS = %w[show.configuration config.changed config.replace config.compare
                    config.commit config.discard config.history config.rollback].freeze

  def test_every_method_the_document_names_answers
    %w[show.adj_in show.adj_out show.fib show.log events.subscribe
       events.unsubscribe peer.clear peer.stop peer.start peer.refresh
       route.originate route.withdraw].each do |m|
      assert_include(BGP::Daemon::Api.names, m)
    end
    DRIVER_CALLS.each { |m| assert_include(BGP::Daemon::Api.names, m) }
    # The tenth, which no driver calls and a person does: changing one
    # key without sending the whole configuration back.
    assert_include(BGP::Daemon::Api.names, 'config.load')
  end

  # Each of them answers over `handle` rather than only being registered,
  # which is the half a name list cannot say.
  def test_the_config_methods_answer_over_handle
    assert_equal(false, req('config.changed')[:result])
    assert_equal([], req('config.compare')[:result])
    assert_equal([], req('config.history')[:result])
    assert_match(/^set as 65000$/, req('show.configuration', 'format' => 'set')[:result])
    assert_equal({ :errors => [] },
                 req('config.load', 'lines' => ['set log_level warn'])[:result])
    assert_equal(true, req('config.changed')[:result])
    assert_equal(['set log_level warn'], req('config.compare')[:result])
    assert_equal(true, req('config.commit', 'check' => true)[:result][:ok])
    assert_equal(true, req('config.commit')[:result][:ok])
    assert_equal(1, req('config.history')[:result].size)
    assert_equal(0, req('config.rollback')[:result][:rollback])
    assert_equal(true, req('config.discard')[:result][:discarded])
  end

  def test_a_config_methods_refusal_is_an_error_line
    assert_match(/unknown parameter/, req('config.compare', 'format' => 'set')[:error])
    assert_match(/rollback 9 does not exist/, req('config.rollback', 'number' => 9)[:error])
    # A text it cannot read is `errors` in the result and not an error
    # line, because the driver reads `['errors']` and treats an empty
    # Array as success.
    r = req('config.replace', 'lines' => ['nonsense'])
    assert_nil(r[:error])
    assert_equal(1, r[:result][:errors].size)
  end

  # A request with no method at all is a request for a method named "",
  # which is unknown. It must not raise: a console can send anything.
  def test_a_request_with_no_method_is_an_unknown_method
    r = @api.handle('id' => 1)
    assert_match(/unknown method ""/, r[:error])
    assert_equal(1, r[:id])
  end

  def test_params_that_are_not_an_object_are_read_as_none
    assert_equal(req('show.routes')[:result], @api.handle('id' => 1, 'method' => 'show.routes',
                                                          'params' => 'nonsense')[:result])
  end

  # A refusal a caller can fix comes back as its own message; anything
  # else is this daemon's fault and says so without leaking a backtrace.
  def test_a_refusal_the_caller_can_fix_is_its_own_message
    r = req('show.routes', 'limit' => 'lots')
    assert_match(/limit must be an integer/, r[:error])
  end

  def test_a_method_that_raises_answers_an_internal_error_and_logs_it
    logged = []
    api = BGP::Daemon::Api.new(Boom.new, :logger => ->(level, msg) { logged << [level, msg] })
    r = api.handle('id' => 7, 'method' => 'show.status')
    assert_equal(7, r[:id])
    assert_equal('internal error: RuntimeError', r[:error])
    assert_equal([:error], logged.collect(&:first))
    assert_match(/show\.status/, logged.first.last)
  end

  def test_api_info_names_the_version_the_methods_and_the_event_sequence
    i = req('api.info')[:result]
    assert_equal(BGP::VERSION, i[:version])
    assert_equal(BGP::Daemon::Api::VERSION, i[:api])
    assert_equal(BGP::Daemon::Api.names, i[:methods])
    assert_include(i[:methods], 'events.subscribe')
    assert_include(i[:event_kinds], 'session')
    assert_equal(0, i[:event_seq])
    @speaker.events.publish(:kind => :log, :message => 'something happened')
    assert_equal(1, req('api.info')[:result][:event_seq])
  end

  def test_show_peers_is_a_bare_array_and_the_two_rib_views_are_pages
    assert_kind_of(Array, req('show.peers')[:result])
    assert_kind_of(Hash, req('show.routes')[:result])
    assert_kind_of(Hash, req('show.rib')[:result])
    assert_equal(1, req('show.rib')[:result][:total])
  end

  def test_show_text_answers_a_string
    assert_match(/10\.255\.0\.0\/24/, req('show.text')[:result])
    assert_kind_of(String, req('show.text', 'style' => 'junos')[:result])
  end

  # Every result has to survive JSON.generate, because that is the only
  # thing the socket does with it. A Symbol value is fine, since JSON
  # writes it as a String; an object with no JSON form is not.
  def test_every_result_serialises
    require 'json'
    BGP::Daemon::Api::METHODS.each_key do |m|
      assert_nothing_raised("#{m} must serialise") { JSON.generate(req(m)) }
    end
  end

  # ====================================================================
  # The write side, and the streams

  # **A mutating method is a name of its own and never a flag on a
  # read**, which is docs/daemon.md's decision: a read-only client is
  # then a list of methods and not a trust decision. So no read method
  # takes a parameter that changes anything, and the test for it is that
  # the write methods are all named `peer.` or `route.`.
  # **`config.` is the one prefix with a method of each kind in it**, and
  # that is the candidate configuration's shape rather than a hole in
  # this rule: `config.compare` and `config.history` ask a question and
  # `config.commit` changes a router. So the mutating ones are named here
  # one by one, and what the rule still says is that no **read** takes a
  # parameter that changes anything.
  CONFIG_WRITES = %w[config.commit config.discard config.load
                     config.replace config.rollback].freeze

  def test_the_write_side_is_separate_names_and_not_a_flag
    writes = BGP::Daemon::Api::METHODS.keys.select { |m| m.start_with?('peer.', 'route.') }
    assert_equal(%w[peer.clear peer.refresh peer.start peer.stop
                    route.originate route.withdraw].sort, writes.sort)
    reads = BGP::Daemon::Api::METHODS.keys - writes - CONFIG_WRITES
    reads.each do |m|
      assert_equal(true, m.start_with?('show.', 'api.', 'config.'), m)
    end
    # And every `config.` method is on one side or the other, so one
    # added later cannot be left out of this test by being overlooked.
    CONFIG_WRITES.each { |m| assert_include(BGP::Daemon::Api::METHODS.keys, m) }
    assert_equal(%w[config.changed config.compare config.history],
                 (BGP::Daemon::Api::METHODS.keys.select { |m| m.start_with?('config.') } -
                  CONFIG_WRITES).sort)
  end

  def test_the_write_methods_answer_over_handle
    assert_equal(['10.255.1.0/24'],
                 req('route.originate', 'prefix' => '10.255.1.0/24')[:result][:originated])
    assert_equal(2, req('show.routes')[:result][:total])
    assert_equal(['10.255.1.0/24'],
                 req('route.withdraw', 'prefix' => '10.255.1.0/24')[:result][:withdrawn])
    assert_equal(true, req('peer.stop', 'peer' => '10.0.0.2')[:result][:shutdown])
    assert_equal(false, req('peer.start', 'peer' => '10.0.0.2')[:result][:shutdown])
    assert_equal(true, req('peer.clear', 'peer' => '10.0.0.2')[:result][:cleared])
  end

  # A refusal a caller can fix comes back as its own message, as a view's
  # does, and the daemon goes on answering.
  def test_a_write_method_refuses_by_name
    assert_match(/peer is required/, req('peer.clear')[:error])
    assert_match(/no neighbor "9\.9\.9\.9"/, req('peer.stop', 'peer' => '9.9.9.9')[:error])
    assert_match(/prefix or prefixes is required/, req('route.originate')[:error])
    assert_match(/not established/, req('peer.refresh', 'peer' => '10.0.0.2')[:error])
  end

  def test_the_new_read_methods_answer_pages_and_lines
    assert_match(/peer is required/, req('show.adj_in')[:error])
    assert_kind_of(Hash, req('show.adj_in', 'peer' => '10.0.0.2')[:result])
    assert_equal(0, req('show.adj_out', 'peer' => '10.0.0.2')[:result][:total])
    assert_equal(false, req('show.fib')[:result][:fib][:configured])
    assert_equal([], req('show.log')[:result][:lines])
  end

  # **`handle` cannot answer a stream**, since a stream is many lines, so
  # the two event methods are registered apart and the socket loop
  # dispatches them. They are still in the one name list, because a
  # reader guessing a method name wants every name.
  def test_the_streams_are_registered_apart_and_listed_together
    BGP::Daemon::Api::STREAM_METHODS.each do |m|
      assert_equal(false, BGP::Daemon::Api::METHODS.key?(m),
                   "#{m} is a stream and handle cannot answer it")
      assert_include(BGP::Daemon::Api.names, m)
    end
    assert_equal(%w[events.subscribe events.unsubscribe], BGP::Daemon::Api::STREAM_METHODS)
  end

  # Asked through handle rather than over a socket, a stream method is
  # an unknown method: the only thing that can answer one is the loop
  # that owns the connection. Over the socket it works, which is
  # test/functional/daemon_test.rb.
  def test_a_stream_method_through_handle_is_not_answered
    assert_match(/unknown method "events\.subscribe"/, req('events.subscribe')[:error])
  end

  private

  # A Views that raises, for the internal error path.
  class Boom
    def status ; raise 'the table fell over' ; end
    def speaker ; nil ; end
  end

  def pa
    BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new,
                            BGP::Next_hop.new('10.0.0.1'))
  end

end
