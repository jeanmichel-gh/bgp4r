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


# docs/console-examples.md, held to the programs it drives. Examples 1
# and 2 are typed into the program by
# test/functional/console_examples_test.rb. The other four need several
# terminals, so this file checks what can be checked with none: every
# command line parses with the program's own option parser, both node
# files load through the program that reads them, and every line typed
# at a prompt starts with a verb that prompt has.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'shellwords'
require 'bgp4r'
require 'bgp/sim'
require 'bgp/sim/console'
require 'bgp/sim/console_command'
require 'bgp/daemon'

class TestConsoleExamplesDoc < Test::Unit::TestCase

  ROOT = File.expand_path('../..', __dir__)
  DOC = File.join(ROOT, 'docs', 'console-examples.md')

  # The prompt each example block is typed into. A block that is not
  # here fails test_every_example_block_has_a_prompt.
  PROMPTS = {
    'no-session'      => BGP::Sim::Console,
    'back-to-back'    => BGP::Sim::Console,
    'two-consoles-a'  => BGP::Sim::Console,
    'two-consoles-b'  => BGP::Sim::Console,
    'two-consoles-a2' => BGP::Sim::Console,
    'sim-a'           => BGP::Sim::Console,
    'sim-b'           => BGP::Sim::Console,
    'routegen'        => BGP::Sim::Console,
    'daemon-up1'      => BGP::Sim::Console,
    'daemon-dn1'      => BGP::Sim::Console,
    'daemon-rtr'      => BGP::Daemon::Console,
    'daemon-rtr2'     => BGP::Daemon::Console,
  }

  # What irb itself answers rather than the console.
  IRB_WORDS = %w[exit]

  def doc
    @doc ||= File.read(DOC, :encoding => 'UTF-8')
  end

  def blocks(kind)
    doc.scan(/<!-- #{kind}: ([\w-]+) -->\n```\w+\n(.*?)```/m)
  end

  def commands
    doc.scan(/```sh\n(.*?)```/m).flatten.join.lines.collect(&:strip).
      grep(/\Aruby -I\. exe\//).collect { |l| Shellwords.split(l.sub(/\s+#\s.*\z/, '')) }
  end

  def test_every_example_block_has_a_prompt
    names = blocks('example').collect(&:first)
    assert_equal(PROMPTS.keys.sort, names.sort)
  end

  # The first word of a typed line, unless the line assigns.
  def test_every_typed_line_starts_with_a_verb_of_its_prompt
    checked = 0
    blocks('example').each do |name, body|
      locals = []
      body.lines.each do |line|
        if (var = line[/\A\s*(\w+)\s*=[^=>]/, 1])
          locals << var
          next
        end
        verb = line[/\A\s*([a-z_]\w*[?!]?)/, 1] or next
        next if IRB_WORDS.include?(verb) || locals.include?(verb)
        assert(PROMPTS[name].method_defined?(verb),
               "#{name}: #{verb} is not a verb of #{PROMPTS[name]}")
        checked += 1
      end
    end
    assert_operator(checked, :>=, 40, 'the typed lines were read')
  end

  # Each program's own parser, so a flag it does not take fails here.
  def test_every_command_line_parses
    out, err = StringIO.new, StringIO.new
    parsed = commands.collect do |argv|
      exe, *rest = argv[2..-1]
      opts = case exe
             when 'exe/bgp4rd' then BGP::Daemon::Server.new(out, err).send(:parse, rest, {})
             when 'exe/bgp4r-cli' then BGP::Daemon::CLI.new(out, err).send(:parse, rest, {})
             when 'exe/bgp4r'
               sub, *args = rest
               case sub
               when 'console' then BGP::Sim::ConsoleCommand.new(out, err).send(:parse, args)
               when 'sim' then BGP::Sim::Server.new(out, err).send(:parse, args, {})
               when 'routegen' then BGP::Sim::Routegen.new(out, err).send(:parse, args)
               else flunk("no parser for bgp4r #{sub}")
               end
             else flunk("no parser for #{exe}")
             end
      assert(!opts[:error], "#{argv.join(' ')}\n#{err.string}")
      exe
    end
    assert_equal('', err.string)
    assert_equal(%w[exe/bgp4r exe/bgp4r-cli exe/bgp4rd], parsed.uniq.sort)
    assert_equal(14, parsed.size, 'every command line was read')
  end

  def node(name)
    body = blocks('node').assoc(name)
    assert(body, "the document has a #{name} node file")
    body[1]
  end

  # The real loader: Injector.new runs Injector.check_config.
  def test_the_sim_node_file_loads_as_an_injector
    require 'yaml'
    i = BGP::Sim::Injector.new(YAML.safe_load(node('sim')))
    assert_equal(['127.0.0.1'], i.speaker.peers.collect(&:address))
    assert_equal([], i.speaker.announcements, 'it starts silent')
  end

  # What `bgp4rd -f FILE` does: load_config, then with_defaults.
  def test_the_daemon_node_file_loads_as_a_daemon
    Dir.mktmpdir do |d|
      file = File.join(d, 'rtr.yml')
      File.write(file, node('daemon'))
      err = StringIO.new
      config = BGP::Daemon::Server.new(StringIO.new, err).load_config(:config => file)
      assert(config, err.string)
      speaker = BGP::Daemon::Speaker.new(BGP::Daemon::Server.with_defaults(config))
      assert_equal(%w[127.0.0.2 127.0.0.3], speaker.peers.collect(&:address))
      assert_equal(['65000:1:1'], config['mark']['large_communities'])
    end
  end

  # Both node files point at the address and port the consoles listen on.
  def test_the_node_files_agree_with_the_command_lines
    require 'yaml'
    sim = YAML.safe_load(node('sim'))
    rtr = YAML.safe_load(node('daemon'))
    assert_equal(1179, sim['neighbors'].first['port'])
    assert_equal(1179, rtr['port'])
    assert_match(/--port 1179 --local-address 127\.0\.0\.2/, doc)
    assert_match(/--port 1179 --local-address 127\.0\.0\.3/, doc)
  end

  def test_console_md_points_here
    text = File.read(File.join(ROOT, 'docs', 'console.md'), :encoding => 'UTF-8')
    assert_match(/console-examples\.md/, text)
  end

end
