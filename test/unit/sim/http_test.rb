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

# The injector's HTTP API: every path, every status code and every
# refusal, through `handle` and with no socket.
#
#   ruby -I. test/unit/sim/http_test.rb
#
# `handle` takes a method, a path, headers and a body and answers
# `[status, data]`, which is why none of this needs a port: the socket's
# own job is parsing and writing, and `test/functional/sim_test.rb` is
# what drives it over a real one with `Net::HTTP`, which is the client
# routescope's driver inlines.

require 'test/unit'
require 'json'
require 'bgp/sim/http'
require 'bgp/sim/views'

class BGP_Sim_Http_Test < Test::Unit::TestCase

  CONFIG = { 'router_id' => '10.0.0.1', 'as' => 65_001,
             'neighbors' => [{ 'address' => '10.0.10.2', 'as' => 65_000,
                               'description' => 'rtr' }] }.freeze

  def http
    @http ||= begin
      @injector = BGP::Sim::Injector.new(CONFIG)
      BGP::Sim::Http.new(BGP::Sim::Views.new(@injector), @injector)
    end
  end

  def get(path) ; http.handle('GET', path) ; end

  def post(path, body = {}, headers = nil)
    headers ||= { BGP::Sim::Http::HEADER => BGP::Sim::Http::HEADER_VALUE }
    http.handle('POST', path, headers, body.is_a?(String) ? body : JSON.generate(body))
  end

  # ---- the reads -----------------------------------------------------

  # `/api/peers` answers an Array where the rest answer an object, which
  # is `bgp4rd`'s `show.peers` shape: the read table's requirement is
  # that one driver reads both programs, so the data is the daemon's and
  # is not wrapped here to look tidier.
  def test_every_documented_read_answers
    BGP::Sim::Http::READS.each_key do |path|
      status, answer = get(path)
      assert_equal(200, status, "#{path} answered #{status}: #{answer.inspect}")
      assert_equal(path == '/api/peers' ? Array : Hash, answer.class, path)
    end
  end

  def test_the_five_reads_are_the_documented_ones
    assert_equal(%w[/api/events /api/peers /api/sent /api/status /api/topology],
                 BGP::Sim::Http::READS.keys.sort)
  end

  def test_the_ten_actions_are_the_documented_ones
    assert_equal(%w[/api/announce /api/attribute /api/fault /api/notification
                    /api/refresh /api/replay /api/session/flap /api/session/start
                    /api/session/stop /api/withdraw],
                 BGP::Sim::Http::ACTIONS.keys.sort)
  end

  # The path table and the key table are two halves of
  # `Drivers::Sim::ACTIONS`, whose entry is `[path, body keys]`, so
  # neither half may name an action the other does not.
  def test_every_path_has_an_action_and_every_action_a_path
    assert_equal(BGP::Sim::Injector::ACTIONS.keys.sort,
                 BGP::Sim::Http::ACTIONS.values.sort)
  end

  def test_a_read_is_not_a_post_and_a_post_is_not_a_read
    assert_equal(405, post('/api/status').first)
    assert_equal(405, get('/api/announce').first)
  end

  def test_the_index_names_every_path_so_curl_needs_no_document
    status, answer = get('/')
    assert_equal(200, status)
    assert_equal(BGP::Sim::Http::READS.keys.sort, answer[:reads])
    assert_equal(BGP::Sim::Http::ACTIONS.keys.sort, answer[:actions].keys)
    assert_match(/X-BGP4R: routescope/, answer[:post_header])
    assert_equal(get('/api'), get('/'))
  end

  def test_an_unknown_path_is_a_404_naming_the_paths
    status, answer = get('/api/nonsense')
    assert_equal(404, status)
    assert_match(%r{/api/status}, answer[:error])
    assert_match(%r{/api/announce}, answer[:error])
  end

  def test_a_query_string_reaches_the_view
    status, answer = get('/api/events?since=0')
    assert_equal(200, status)
    assert_kind_of(Array, answer[:events])
  end

  def test_a_query_parameter_that_is_not_a_number_is_a_400
    status, answer = get('/api/events?since=soon')
    assert_equal(400, status)
    assert_match(/since must be an integer/, answer[:error])
  end

  # ---- the header ----------------------------------------------------

  # **Measured, not assumed: `Net::HTTP` capitalises a header name per
  # word, so `X-BGP4R` arrives as `X-Bgp4r`.** A case sensitive match
  # would refuse every POST routescope's driver makes, with a 403 and
  # nothing saying why.
  def test_the_post_header_is_matched_whatever_its_case
    ['X-BGP4R', 'X-Bgp4r', 'x-bgp4r'].each do |spelling|
      headers = { spelling.downcase => BGP::Sim::Http::HEADER_VALUE }
      assert_equal(409, post('/api/announce', { 'prefixes' => ['10.1.0.0/24'] }, headers).first,
                   "#{spelling} was refused: the header check is case sensitive")
    end
  end

  def test_a_post_without_the_header_is_a_403
    status, answer = post('/api/announce', { 'prefixes' => ['10.1.0.0/24'] }, {})
    assert_equal(403, status)
    assert_match(/X-BGP4R: routescope/, answer[:error])
  end

  def test_a_post_with_the_wrong_header_value_is_a_403
    headers = { BGP::Sim::Http::HEADER => 'somebody else' }
    assert_equal(403, post('/api/announce', {}, headers).first)
  end

  # ---- the status codes ----------------------------------------------

  # **A refusal is a 4xx because that is the whole of how it reaches a
  # scenario**: routescope's driver prints the body and exits
  # `code < 300 ? 0 : 1`.
  def test_a_body_the_injector_refuses_is_a_400_with_a_reason
    status, answer = post('/api/announce', 'bogus' => 1)
    assert_equal(400, status)
    assert_match(/unknown key/, answer[:error])
  end

  # A session that is not there is a 409 rather than a 400: both are
  # 4xx, so a driver tells them apart by exit status alike, and a person
  # reading the body can tell "you asked for something odd" from "it is
  # not up yet".
  def test_no_session_is_a_409
    status, answer = post('/api/announce', 'prefixes' => ['10.1.0.0/24'])
    assert_equal(409, status)
    assert_match(/no established session/, answer[:error])
  end

  def test_a_body_that_is_not_json_is_a_400_and_says_so
    status, answer = post('/api/announce', 'this is not json')
    assert_equal(400, status)
    assert_match(/bad JSON/, answer[:error])
  end

  def test_a_body_that_is_json_but_not_an_object_is_a_400
    assert_equal(400, post('/api/announce', '[1,2,3]').first)
    assert_match(/JSON object/, post('/api/announce', '[1,2,3]').last[:error])
  end

  # An empty body is no body, not a bad one: `session.stop` with nothing
  # in it reaches every configured peer.
  def test_an_empty_body_is_no_parameters
    status, answer = post('/api/session/stop', '')
    assert_equal(200, status)
    assert_equal(['10.0.10.2'], answer[:peers])
  end

  # A library constructor refusing a value it cannot represent is the
  # caller's to fix, so a 400 and not a 500.
  def test_a_value_the_library_cannot_represent_is_a_400
    status, answer = post('/api/announce', 'prefixes' => ['not a prefix'], 'peer' => '10.0.10.2')
    assert_equal(400, status)
    assert_not_match(/internal error/, answer[:error])
  end

  # ---- the address ---------------------------------------------------

  def test_the_loopback_is_the_default
    assert_equal('127.0.0.1', BGP::Sim::Http::DEFAULT_BIND)
    assert_equal('127.0.0.1', http.bind)
    assert_equal(8080, http.port)
  end

  def test_an_address_is_read_as_host_and_port
    assert_equal({ :bind => '0.0.0.0', :port => 8080 },
                 BGP::Sim::Http.address('0.0.0.0:8080'))
    assert_equal({ :bind => '127.0.0.1', :port => 9000 },
                 BGP::Sim::Http.address('9000'))
    assert_equal({ :bind => '127.0.0.1', :port => 9000 },
                 BGP::Sim::Http.address(':9000'))
  end

  # A bare `::1:8080` cannot be split, because the last colon is part of
  # the address as readily as it is the separator, so an IPv6 address is
  # written in brackets.
  def test_an_ipv6_address_is_read_from_its_brackets
    assert_equal({ :bind => '::1', :port => 8080 }, BGP::Sim::Http.address('[::1]:8080'))
    assert_raise(ArgumentError) { BGP::Sim::Http.address('::1:8080') }
  end

  def test_an_address_that_is_not_one_is_refused_and_says_how_to_write_it
    e = assert_raise(ArgumentError) { BGP::Sim::Http.address('somewhere') }
    assert_match(/HOST:PORT/, e.message)
  end

  def test_the_url_brackets_an_ipv6_bind
    h = BGP::Sim::Http.new(nil, nil, :bind => '::1', :port => 8080)
    assert_equal('http://[::1]:8080', h.url)
  end

end
