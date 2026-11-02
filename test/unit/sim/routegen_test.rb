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

# `bgp4r routegen`: what it reads and what it would send. No session
# here, because the sending is `Injector#act`'s and is asserted in
# test/unit/sim/injector_test.rb and over a socket in
# test/functional/sim_test.rb. What is this file's own is the planning:
# the flags, the node file, and the one thing a reader would not guess,
# which is that the file's announce blocks are moved out of the config.
#
#   ruby -I. test/unit/sim/routegen_test.rb

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'bgp/sim/routegen'
require 'bgp/capture/cli'

class BGP_Sim_Routegen_Test < Test::Unit::TestCase

  CONFIG = <<~YAML
    router_id: 10.0.0.1
    as: 65001
    neighbors:
      - address: 10.0.0.2
        as: 65002
        connect: true
    announce:
      - generate: { start: 11.0.0.0/28, count: 10, per_update: 4 }
        med: 100
  YAML

  def routegen
    @routegen ||= BGP::Sim::Routegen.new(@out = StringIO.new, @err = StringIO.new)
  end

  def plan(argv)
    opts = routegen.send(:parse, argv)
    routegen.plan(opts)
  end

  def with_config(text = CONFIG)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sim.yml')
      File.write(path, text)
      yield path
    end
  end

  def test_help_is_the_usage_and_a_success
    status = routegen.start(['--help'])
    assert_equal(0, status)
    assert_match(/Usage: bgp4r routegen/, @out.string)
    assert_match(/ROUTEGEN_COUNT/, @out.string)
  end

  def test_the_umbrella_runs_it
    out, err = StringIO.new, StringIO.new
    assert_equal(0, BGP::Capture::CLI.new(out, err).start(%w[routegen --help]))
    assert_match(/Usage: bgp4r routegen/, out.string)
  end

  # ---- the flags -----------------------------------------------------

  def test_the_flags_build_a_dialling_node_file
    config, blocks = plan(%w[--peer 10.0.0.2 --peer-as 65002 --count 200 --per-update 50])
    assert_equal(65_001, config['as'])
    assert_equal('10.0.0.1', config['router_id'])
    neighbor = config['neighbors'].first
    assert_equal('10.0.0.2', neighbor['address'])
    assert_equal(65_002, neighbor['as'])
    assert_equal(true, neighbor['connect'], 'the sim dials, which is the recorded decision')
    assert_equal(1, blocks.size)
    assert_equal({ 'start' => BGP::Sim::Routegen::DEFAULT_START,
                   'count' => 200, 'per_update' => 50 },
                 blocks.first['generate'])
  end

  def test_the_attribute_flags_reach_the_announce_block
    _config, blocks = plan(['--peer', '10.0.0.2', '--peer-as', '65002',
                            '--med', '100', '--as-path', '90 80',
                            '--communities', '100:1 200:1',
                            '--next-hop', '10.0.0.9'])
    block = blocks.first
    assert_equal(100, block['med'])
    assert_equal([90, 80], block['as_path'])
    assert_equal(['100:1', '200:1'], block['communities'])
    assert_equal('10.0.0.9', block['next_hop'])
  end

  # The defaults are the numbers every example in the repository uses,
  # so a reader meets the prefix they expect.
  def test_the_defaults_are_the_documented_ones
    _config, blocks = plan(%w[--peer 10.0.0.2 --peer-as 65002])
    assert_equal({ 'start' => '11.0.0.0/28', 'count' => 1, 'per_update' => 1 },
                 blocks.first['generate'])
    assert_equal('11.0.0.0/28', BGP::Sim::Routegen::DEFAULT_START)
  end

  def test_no_file_and_no_peer_is_refused_and_says_what_to_give
    status = routegen.start([])
    assert_equal(1, status)
    assert_match(/node file, or --peer ADDR and --peer-as AS/, @err.string)
  end

  def test_an_unknown_flag_is_the_usage_and_a_failure
    assert_equal(1, routegen.start(['--nonsense']))
    assert_match(/Usage: bgp4r routegen/, @err.string)
  end

  # ---- the node file -------------------------------------------------

  # **The one thing a reader would not guess.** `Peer#announce` sends
  # `Speaker#announcements` by itself on every establishment, so leaving
  # the blocks in the config would send each one twice, once by the
  # Speaker and once as an action, and the report would count one of
  # them.
  def test_the_files_announce_blocks_are_moved_out_of_the_config
    with_config do |path|
      config, blocks = plan([path])
      assert_equal(false, config.key?('announce'),
                   'left in, the Speaker would send it as well and the count would lie')
      assert_equal(1, blocks.size)
      assert_equal(100, blocks.first['med'])
      assert_equal('11.0.0.0/28', blocks.first['generate']['start'])
      # And what is left is still a node file the Injector accepts.
      assert_equal(0, BGP::Sim::Injector.new(config).speaker.announcements.size)
    end
  end

  def test_a_file_with_no_announce_block_is_refused_and_says_why
    with_config("router_id: 10.0.0.1\nas: 65001\nneighbors: []\n") do |path|
      assert_equal(1, routegen.start([path]))
      assert_match(/no announce block/, @err.string)
      assert_match(/use the flags/, @err.string)
    end
  end

  def test_a_file_that_is_not_there_says_so
    assert_equal(1, routegen.start(['/no/such/sim.yml']))
    assert_match(%r{/no/such/sim\.yml: no such file}, @err.string)
  end

  def test_a_file_that_is_not_a_mapping_says_so
    with_config("- one\n") do |path|
      assert_equal(1, routegen.start([path]))
      assert_match(/is not a YAML mapping/, @err.string)
    end
  end

  # A `prefixes` block works too, because the blocks are the node file's
  # own announce blocks and a generated range is one shape of them.
  def test_a_prefixes_block_is_a_block_like_any_other
    with_config(<<~YAML) do |path|
      router_id: 10.0.0.1
      as: 65001
      neighbors: []
      announce:
        - prefixes: [10.1.0.0/24]
    YAML
      _config, blocks = plan([path])
      assert_equal(['10.1.0.0/24'], blocks.first['prefixes'])
    end
  end

  # The environment overrides already in Speaker.generate_options reach
  # this the same way they reach a lab topology, which is one run
  # changing every feed's size.
  def test_the_environment_overrides_the_count
    with_config do |path|
      _config, blocks = plan([path])
      g = BGP::Daemon::Speaker.generate_options(blocks.first['generate'],
                                                'ROUTEGEN_COUNT' => '7',
                                                'ROUTEGEN_PER_UPDATE' => '3')
      assert_equal(7, g['count'])
      assert_equal(3, g['per_update'])
    end
  end

end
