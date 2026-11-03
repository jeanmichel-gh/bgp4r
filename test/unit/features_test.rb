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
require 'logger'
require 'stringio'
require './test/features'
require './test/features_doc'
require './test/log_switch'

# Holds `test/features.rb` and `docs/running-tests.md` to the tree.
#
# This is `test/unit/lab_groups_test.rb`'s shape, for the same reason: a
# list of test files kept by hand lets a new test file belong nowhere,
# and nothing says so. There the consequence is a file running in no CI
# job; here it is a file no `run_feature.rb` ever reaches, which is
# quieter and just as wrong.
#
# **The document is asserted byte for byte** rather than by pattern. That
# is stronger than the discovered tables in `evpn_doc_test.rb` and is
# available only because this document is generated: there is no prose in
# it a person maintains, so there is no half that can drift.
class TestFeatures < Test::Unit::TestCase

  DOC = 'docs/running-tests.md'

  # ---- the registry against the tree -------------------------------

  def test_every_test_file_carries_a_feature
    missed = Features.untagged
    assert_equal([], missed,
      "#{missed.size} test file(s) carry no feature. Tag each in " \
      "test/features.rb, then regenerate #{DOC}.")
  end

  def test_every_file_a_feature_names_is_on_disk
    gone = Features.missing
    assert_equal([], gone,
      "test/features.rb names #{gone.size} file(s) that are not there. " \
      'A renamed test otherwise runs one file fewer and says nothing.')
  end

  def test_no_feature_is_empty
    empty = Features.names.reject { |n| Features.all_files(n).any? }
    assert_equal([], empty, 'a feature with no tests is a typo')
  end

  def test_every_feature_is_in_a_known_area
    Features.names.each do |n|
      area = Features.feature(n)[:area]
      assert(Features.areas.include?(area),
             "#{n}: area #{area.inspect} is not one of #{Features.areas.join(', ')}")
    end
  end

  def test_every_area_has_a_feature
    Features.areas.each do |a|
      assert_not_equal([], Features.in_area(a), "area #{a} holds nothing")
    end
  end

  def test_an_unknown_feature_raises_rather_than_running_nothing
    e = assert_raise(ArgumentError) { Features.feature('nope') }
    assert_match(/unknown feature/, e.message)
    e = assert_raise(ArgumentError) { Features.in_area('nope') }
    assert_match(/unknown area/, e.message)
  end

  # The one file that must never run is excluded from the tagging rule,
  # and `run_feature.rb` refuses it by name. Both halves, because either
  # alone would let it run.
  def test_the_file_that_must_never_run_is_named_and_excluded
    assert_equal(['functional/live_feed_test'], Features::NEVER.keys)
    path = 'test/functional/live_feed_test.rb'
    assert(File.exist?(path), 'the file this excludes is still there')
    assert(Features.never?(path))
    assert_equal([], Features.features_of(path),
                 'a file that must never run must carry no feature either')
    assert_match(/hangs forever/, Features.never_reason(path))
    assert_equal(false, Features.untagged.include?(path))
    assert_match(/refusing/, File.read('test/run_feature.rb'))
  end

  # ---- what a tier needs, derived rather than restated --------------

  def test_every_lab_file_a_feature_names_resolves_to_a_need
    Features.names.each do |n|
      Features.files(n, :lab).each do |p|
        need = Features.needs(p)
        assert_not_nil(need,
          "#{p} is in no group in test/lab_groups.rb, so nothing says " \
          'what it needs')
        assert(Features::NEEDS.value?(need) || need == 'root',
               "#{p}: need #{need.inspect} is not one of the words " \
               "#{(Features::NEEDS.values + ['root']).uniq.join(', ')}")
      end
    end
  end

  # The needs vocabulary is derived from LabGroups, so a group added
  # there without a word here would answer nil for every file in it.
  def test_every_group_has_a_need
    LabGroups.groups.each do |g|
      assert(Features::NEEDS.key?(g),
             "group #{g} has no need in test/features.rb")
    end
    extra = Features::NEEDS.keys - LabGroups.groups
    assert_equal([], extra, 'a need for a group that does not exist')
  end

  def test_a_unit_or_functional_file_needs_nothing
    %i[unit functional].each do |tier|
      Features.names.each do |n|
        Features.files(n, tier).each do |p|
          assert_nil(Features.needs(p),
                     "#{p}: a #{tier} test must need no binary")
        end
      end
    end
  end

  # ---- the document -------------------------------------------------

  def test_the_document_is_what_the_generator_produces
    assert(File.exist?(DOC), "#{DOC} is missing: ruby test/features_doc.rb > #{DOC}")
    assert_equal(FeaturesDoc.document, File.read(DOC, :encoding => 'UTF-8'),
      "#{DOC} is stale. Regenerate it: ruby test/features_doc.rb > #{DOC}")
  end

  def test_the_document_says_it_is_generated
    doc = File.read(DOC, :encoding => 'UTF-8')
    assert_match(/\*\*Generated\. Do not edit\.\*\*/, doc)
    assert_match(%r{ruby test/features_doc\.rb > #{Regexp.escape(DOC)}}, doc)
  end

  # Every feature gets a heading and a command, so the document cannot
  # list a feature it does not say how to run.
  def test_the_document_names_every_feature_with_its_command
    doc = File.read(DOC, :encoding => 'UTF-8')
    Features.names.each do |n|
      assert_match(/^### `#{Regexp.escape(n)}`$/, doc, "#{n} has no heading")
      assert_match(/^ruby test\/run_feature\.rb #{Regexp.escape(n)}$/, doc,
                   "#{n} has no command")
    end
  end

  # Each doc a feature points at has to be there, since the whole value
  # of the pointer is that a reader follows it.
  def test_every_document_a_feature_points_at_exists
    Features.names.each do |n|
      d = Features.feature(n)[:doc]
      next unless d
      assert(File.exist?(d), "#{n} points at #{d}, which is not there")
    end
  end

  # ---- BGP4R_LOG ----------------------------------------------------

  # The switch the document promises. Asserted on the mapping and not by
  # installing one, because installing a logger here would change what
  # every test loaded after this one writes.
  def test_the_log_switch_reads_the_three_levels
    assert_equal(Logger::DEBUG, LogSwitch::LEVELS['debug'])
    assert_equal(Logger::DEBUG, LogSwitch::LEVELS['2'])
    assert_equal(Logger::INFO,  LogSwitch::LEVELS['info'])
    assert_equal(Logger::INFO,  LogSwitch::LEVELS['1'])
    assert_equal(Logger::WARN,  LogSwitch::LEVELS['warn'])
    assert_equal('BGP4R_LOG', LogSwitch::VAR)
  end

  def test_the_log_switch_does_nothing_without_the_variable
    assert_nil(LogSwitch.install({}, STDERR))
    assert_nil(LogSwitch.install({ 'BGP4R_LOG' => '  ' }, STDERR))
  end

  # An unknown value warns and does nothing. A typo must not silently
  # mean debug, and must not silently mean off either.
  def test_an_unknown_level_warns_and_installs_nothing
    out = StringIO.new
    got = nil
    begin
      saved, $stderr = $stderr, out
      got = LogSwitch.install({ 'BGP4R_LOG' => 'verbose' }, StringIO.new)
    ensure
      $stderr = saved
    end
    assert_nil(got)
    assert_match(/BGP4R_LOG="verbose"/, out.string)
    assert_match(/debug, 2, info, 1, warn/, out.string)
  end

  def test_the_three_runners_install_the_switch
    %w[test/run_unit.rb test/run_feature.rb test/run_lab.rb].each do |f|
      src = File.read(f, :encoding => 'UTF-8')
      assert_match(%r{^require './test/log_switch'$}, src, "#{f} does not require it")
      assert_match(/^LogSwitch\.install$/, src, "#{f} does not call it")
    end
  end

  # The `-r` hook for one file, and the asymmetry it rests on: requiring
  # `log_switch` must stay side-effect free, since this very file
  # requires it, and `log_on` is the one that installs.
  def test_the_r_hook_installs_and_the_switch_alone_does_not
    assert_match(/^LogSwitch\.install$/,
                 File.read('test/log_on.rb', :encoding => 'UTF-8'))
    refute_match(/^LogSwitch\.install$/,
                 File.read('test/log_switch.rb', :encoding => 'UTF-8'),
                 'requiring log_switch must not install anything')
    # Proved in a child process and not from the source, because what is
    # claimed is that a library log line reaches standard error. A line
    # the library writes is the only thing that can show it, so the child
    # writes one.
    say = 'require "bgp/common" ; Log.info("the hook is on")'
    noisy = `BGP4R_LOG=info ruby -I. -rtest/log_on -e '#{say}' 2>&1`
    quiet = `ruby -I. -rtest/log_on -e '#{say}' 2>&1`
    assert_match(/the hook is on/, noisy, 'BGP4R_LOG did not reach the library')
    assert_equal('', quiet, 'the hook must be silent without the variable')
  end

  # ---- the runner ---------------------------------------------------

  def test_the_runner_lists_the_features_with_no_argument
    out = `ruby test/run_feature.rb 2>&1`
    assert_equal(0, $?.exitstatus, out)
    Features.names.each { |n| assert_match(/\b#{Regexp.escape(n)}\b/, out) }
    Features.areas.each { |a| assert_match(/^#{Regexp.escape(a)}:/, out) }
  end

  def test_the_runner_lists_one_features_files
    out = `ruby test/run_feature.rb evpn --list 2>&1`
    assert_equal(0, $?.exitstatus, out)
    Features.all_files('evpn').each { |p| assert_match(/#{Regexp.escape(p)}/, out) }
    assert_match(/needs gobgpd/, out, 'the list says what a lab file wants')
    assert_match(/needs frr/, out)
  end

  def test_the_runner_runs_one_tier
    out = `ruby test/run_feature.rb rt-constrain --unit 2>&1`
    assert_equal(0, $?.exitstatus, out)
    assert_match(/1 file\(s\)/, out)
    assert_match(/0 failures, 0 errors/, out)
  end

  def test_the_runner_refuses_an_unknown_name
    out = `ruby test/run_feature.rb nope 2>&1`
    assert_not_equal(0, $?.exitstatus, 'an unknown feature must not exit 0')
    assert_match(/unknown feature/, out)
  end

  def test_the_runner_prints_the_document
    out = `ruby test/run_feature.rb --doc 2>&1`
    assert_equal(0, $?.exitstatus)
    assert_equal(FeaturesDoc.document, out)
  end

end
