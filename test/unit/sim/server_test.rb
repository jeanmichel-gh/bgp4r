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

# bgp4r-sim's command line and its node file. Nothing here opens a
# socket or a log, which is why `load_config` is separate from `build`:
# starting it all is test/functional/sim_test.rb.
#
#   ruby -I. test/unit/sim/server_test.rb

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'bgp/sim/server'
require 'bgp/capture/cli'

class BGP_Sim_Server_Test < Test::Unit::TestCase

  CONFIG = <<~YAML
    router_id: 10.255.10.1
    as: 65010
    api: 127.0.0.1:0
    neighbors:
      - address: 10.0.10.2
        as: 65000
        connect: true
  YAML

  def run_server(argv, env = {})
    out, err = StringIO.new, StringIO.new
    status = BGP::Sim::Server.new(out, err).start(argv, env, :wait => false)
    [status, out.string, err.string]
  end

  def server
    @server ||= BGP::Sim::Server.new(@out = StringIO.new, @err = StringIO.new)
  end

  # **Every start in this file logs to a file in its own temporary
  # directory, and the logger is put back afterwards.** `Log` is the
  # library's one logger and `Log.set_filename` replaces it for every
  # other test in the process, which `run_unit.rb` runs in one: a test
  # here that let the default stand would send every later test's log
  # lines to this file's standard output. test/functional/daemon_test.rb
  # records the same thing for the daemon.
  def teardown
    @server.stop if @server
    Log.set_filename(STDERR)
  end

  def with_config(text = CONFIG)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sim.yml')
      File.write(path, text)
      @log = File.join(dir, 'sim.log')
      yield path, dir
    end
  end

  # The flags a start needs on top of what a test asked for.
  def quiet(argv)
    argv + ['-l', @log || File.join(Dir.tmpdir, 'bgp4r-sim-test.log')]
  end

  # ---- the command line ----------------------------------------------

  def test_help_is_the_usage_and_a_success
    status, out, err = run_server(['--help'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_match(/Usage: bgp4r-sim/, out)
    assert_match(/--api/, out)
    assert_match(/starts silent/, out, 'the usage says the rule the program is for')
  end

  def test_version_is_the_library_version
    status, out, = run_server(['--version'])
    assert_equal(0, status)
    assert_equal("#{BGP::VERSION}\n", out)
  end

  # The file is positional, because `bgp4r sim /lab/sim.yml` is a
  # container command, and `-f` works too so neither habit is wrong.
  def test_the_file_is_positional_and_named
    with_config do |path|
      assert_equal(0, run_server(quiet([path])).first)
    end
    with_config do |path|
      assert_equal(0, run_server(quiet(['-f', path])).first)
    end
  end

  def test_no_file_is_the_usage_and_a_failure
    status, out, err = run_server([])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/Usage: bgp4r-sim/, err)
  end

  def test_an_unknown_flag_says_which_one
    status, _out, err = run_server(['--nonsense'])
    assert_equal(1, status)
    assert_match(/unknown argument "--nonsense"/, err)
  end

  def test_a_second_positional_argument_is_an_error_rather_than_a_silent_drop
    with_config do |path|
      status, _out, err = run_server(quiet([path, 'extra']))
      assert_equal(1, status)
      assert_match(/unknown argument "extra"/, err)
    end
  end

  # ---- the node file -------------------------------------------------

  def test_a_file_that_is_not_there_says_so
    status, _out, err = run_server(['/no/such/sim.yml'])
    assert_equal(1, status)
    assert_match(%r{/no/such/sim\.yml: no such file}, err)
  end

  def test_a_file_that_is_not_a_mapping_says_so
    with_config("- one\n- two\n") do |path|
      status, _out, err = run_server([path])
      assert_equal(1, status)
      assert_match(/is not a YAML mapping/, err)
    end
  end

  def test_yaml_that_does_not_parse_says_so
    with_config("as: 65010\nneighbors: [\n") do |path|
      status, _out, err = run_server([path])
      assert_equal(1, status)
      assert_match(/sim\.yml:/, err)
    end
  end

  # A node file asking for a Loc-RIB is refused by name, which is the
  # first row of docs/daemon.md's two-programs table reaching the
  # command line rather than stopping at the Injector.
  def test_a_router_key_in_the_node_file_is_refused_on_the_command_line
    with_config("#{CONFIG}export: {}\n") do |path|
      status, _out, err = run_server([path])
      assert_equal(1, status)
      assert_match(/export/, err)
      assert_match(/bgp4rd/, err)
    end
  end

  def test_a_node_file_with_no_as_says_which_key_is_missing
    with_config("router_id: 10.0.0.1\nneighbors: []\n") do |path|
      status, _out, err = run_server([path])
      assert_equal(1, status)
      assert_match(/as/, err)
    end
  end

  # ---- where it binds ------------------------------------------------

  def test_the_api_address_comes_from_the_node_file
    with_config do |path|
      assert_not_nil(server.start(quiet([path]), {}, :wait => false))
      assert_equal('127.0.0.1', server.http.bind)
      assert(server.http.port.positive?, 'port 0 means the system picked one')
    end
  end

  def test_the_flag_wins_over_the_node_file
    with_config do |path|
      server.start(quiet([path, '--api', '127.0.0.2:0']), {}, :wait => false)
      assert_equal('127.0.0.2', server.http.bind)
    end
  end

  def test_an_api_address_that_is_not_one_is_refused_and_says_how_to_write_it
    with_config do |path|
      status, _out, err = run_server(quiet([path, '--api', 'somewhere']))
      assert_equal(1, status)
      assert_match(/HOST:PORT/, err)
    end
  end

  # **The loopback is the default and that is a decision**: an API on
  # 0.0.0.0 is reachable from every other node on a lab segment, which
  # turns an injector into something any container can drive.
  def test_with_no_api_key_and_no_flag_it_binds_the_loopback
    with_config("router_id: 10.0.0.1\nas: 65010\nneighbors: []\n") do |path|
      server.start(quiet([path]), {}, :wait => false)
      assert_equal('127.0.0.1', server.http.bind)
      assert_equal(8080, server.http.port)
    end
  end

  # ---- what it starts ------------------------------------------------

  def test_it_starts_silent
    with_config do |path|
      server.start(quiet([path]), {}, :wait => false)
      assert_equal(0, server.injector.speaker.announcements.size)
      assert_equal([], server.injector.announced)
      assert_equal(0, server.injector.sent.summary[:prefixes_sent])
    end
  end

  def test_it_builds_no_table
    with_config do |path|
      server.start(quiet([path]), {}, :wait => false)
      assert_nil(server.injector.speaker.rib)
    end
  end

  # ---- the umbrella --------------------------------------------------

  # `bgp4r sim` and `bgp4r-sim` are one implementation, so the alias
  # cannot drift from the subcommand.
  def test_bgp4r_sim_is_the_same_program_as_the_subcommand
    out, err = StringIO.new, StringIO.new
    status = BGP::Capture::CLI.new(out, err).start(%w[sim --help])
    assert_equal(0, status)
    assert_match(/Usage: bgp4r-sim/, out.string)
    assert_equal('', err.string)
  end

  def test_the_umbrella_names_its_four_subcommands
    out = StringIO.new
    BGP::Capture::CLI.new(out, StringIO.new).start([])
    %w[capture sim routegen version].each { |s| assert_match(/^  #{s}/, out.string) }
    assert_equal(%w[capture sim routegen version], BGP::Capture::CLI::SUBCOMMANDS)
    assert_not_match(/Not yet implemented:.*\bsim\b/, out.string,
                     'sim is built, so the usage must not still list it as missing')
  end

end
