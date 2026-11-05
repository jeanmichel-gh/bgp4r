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


# Examples 1 and 2 of docs/console-examples.md, typed into the program
# straight from the document: every `# =>` in a block is compared with
# what the prompt answered. The other four need several terminals and
# are held by test/unit/console_examples_doc_test.rb instead. No
# privilege, no router, no Docker.
#
#   ruby -I. test/functional/console_examples_test.rb

require 'test/unit'
require 'bgp/sim/console'
require 'rbconfig'
require 'tmpdir'

class TestConsoleExamples < Test::Unit::TestCase

  ROOT = File.expand_path('../..', __dir__)
  DOC = File.join(ROOT, 'docs', 'console-examples.md')

  # The ruby block after `<!-- example: NAME -->`.
  def self.block(name)
    text = File.read(DOC, :encoding => 'UTF-8')
    m = text.match(/<!-- example: #{Regexp.escape(name)} -->\n```ruby\n(.*?)```/m)
    m ? m[1].lines.collect(&:chomp) : nil
  end

  # Each line as typed, and a line printing a marker with the answer
  # for each `# =>`. A short sleep first, because a send returns before
  # the other side has read the message, where a person typing does not.
  def self.script(lines)
    checks = []
    typed = lines.collect do |line|
      code, expected = line.split(/\s+# => /, 2)
      next code unless expected
      checks << [code.strip, expected.strip]
      "sleep 0.5 ; puts 'CHECK#{checks.size - 1} ' + (#{code.strip}).inspect"
    end
    [typed, checks]
  end

  def run_example(name, *flags)
    begin
      BGP::Sim::Console.load_irb
    rescue LoadError => e
      omit(e.message)
    end
    lines = self.class.block(name)
    assert(lines, "docs/console-examples.md has an example named #{name}")
    assert_equal('exit', lines.last, 'the example ends with exit')
    typed, checks = self.class.script(lines)
    assert_operator(checks.size, :>, 0, 'the example has something to compare')
    Dir.mktmpdir do |d|
      argv = [RbConfig.ruby, '-I', ROOT, File.join(ROOT, 'exe', 'bgp4r'), 'console',
              *flags, '-l', File.join(d, 'c.log')]
      out = ::IO.popen(argv, 'r+', :err => [:child, :out]) do |io|
        typed.each { |l| io.puts l }
        io.close_write
        io.read
      end
      assert_equal(0, $?.exitstatus, out)
      assert_no_match(/Error\b.*\(|NoMethodError|NameError/, out)
      checks.each_with_index do |(code, expected), n|
        got = out[/^CHECK#{n} (.*)$/, 1]
        assert_equal(expected, got, "#{name}: #{code}\n#{out}")
      end
    end
  end

  def test_example_1_no_session
    run_example('no-session')
  end

  def test_example_2_back_to_back
    run_example('back-to-back', '--back-to-back', '--timeout', '10')
  end

  # The marker split, on its own, so a broken split does not read as a
  # failing example.
  def test_a_line_with_an_answer_becomes_a_check
    typed, checks = self.class.script(["a = 1", "a + 1   # => 2"])
    assert_equal('a = 1', typed[0])
    assert_equal([['a + 1', '2']], checks)
    assert_match(/CHECK0 .*\(a \+ 1\)\.inspect/, typed[1])
  end

end
