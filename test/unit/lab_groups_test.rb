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
require 'test/lab_groups'

# CI runs the lab tests as a matrix, a job per group in
# test/lab_groups.rb. A file in no group would run in no job, and a CI
# job that runs nothing reports a pass, so nothing would say so.
#
# This is the guard. It is in the **unit** suite on purpose: it needs no
# router, no Docker and no socket, it is the cheap half of the lab
# arrangement, and run_unit.rb globs test/unit so it is picked up with no
# wiring. It mirrors no file under bgp/, which is why it is not in a
# subfolder.
class LabGroupsTest < Test::Unit::TestCase

  # The one that matters. Add a lab test, forget to assign it, and this
  # fails naming the file.
  def test_every_lab_test_file_is_in_exactly_one_group
    unassigned = LabGroups.present.reject { |n| LabGroups.group_of(n) }
    assert_equal([], unassigned,
      "lab test files in no group, so they would run in no CI job: " \
      "#{unassigned.join(', ')}. Assign them in test/lab_groups.rb.")

    twice = LabGroups.present.select do |n|
      LabGroups::GROUPS.count { |_, names| names.include?(n) } > 1
    end
    assert_equal([], twice,
      "lab test files in more than one group, so they would run twice: " \
      "#{twice.join(', ')}")
  end

  # The mirror image: a name that no longer exists, left behind by a
  # rename, would make its job require a missing file and error with
  # nothing saying which group was stale.
  def test_every_name_a_group_lists_is_a_file_on_disk
    listed = LabGroups::GROUPS.values.flatten
    missing = listed.reject { |n| LabGroups.present.include?(n) }
    assert_equal([], missing,
      "test/lab_groups.rb names files that do not exist: " \
      "#{missing.join(', ')}")
  end

  # Stated as a set equality as well, because that is the sentence the
  # arrangement rests on and it fails more readably than either half.
  def test_the_groups_together_are_exactly_what_is_on_disk
    assert_equal(LabGroups.present.sort,
                 LabGroups::GROUPS.values.flatten.sort)
  end

  # Running every file must stay a glob and not the union of the groups.
  # If it were the union, `ruby test/run_lab.rb` with no argument would
  # silently skip a new file too, and the guard above would be the only
  # thing left standing between a new lab test and nothing running it.
  def test_running_everything_reads_the_directory_and_not_the_groups
    assert_equal(Dir['test/functional/lab/*_test.rb'].sort,
                 LabGroups.all_files)
  end

  def test_each_group_resolves_to_files_that_exist
    LabGroups.groups.each do |g|
      paths = LabGroups.files(g)
      refute_empty(paths, "group #{g} is empty")
      paths.each { |p| assert(File.exist?(p), "#{g}: #{p} is missing") }
    end
  end

  # An unknown name raises rather than running nothing, because a job
  # that runs nothing exits 0 and reads as a pass. This is what catches
  # a group renamed here and not in the workflow.
  def test_an_unknown_group_raises_rather_than_running_nothing
    assert_raise(ArgumentError) { LabGroups.files('no-such-group') }
    assert_raise(ArgumentError) { LabGroups.files(nil) }
  end

  WORKFLOW = '.github/workflows/test.yml'

  # The other half of the arrangement, and the half the file to group
  # guard above does not reach: a group defined here and missing from the
  # workflow matrix runs in no job, silently, exactly like an unassigned
  # file. So the matrix is read back out of the YAML.
  #
  # Read with a regexp and not a YAML parser, deliberately. Conventions
  # says to check a standard library is still a default gem before
  # requiring it, and this needs nothing from one: `group: name` under
  # the lab matrix is the only place that string appears.
  def test_the_workflow_runs_a_job_for_every_group
    assert(File.exist?(WORKFLOW), WORKFLOW)
    in_yaml = File.read(WORKFLOW).scan(/^\s*- group:\s*(\S+)/).flatten
    assert_equal(LabGroups.groups.sort, in_yaml.sort,
      "the lab matrix in #{WORKFLOW} and LabGroups::GROUPS disagree. A " \
      'group in only one of them runs in no job, or names a group ' \
      'run_lab.rb will raise on.')
  end

  # Each group's job has to install what its tests need, and the matrix
  # entry is what says so. A gobgp group with no gobgp flag would omit
  # every test in it and report a pass.
  def test_every_group_declares_a_dependency_in_the_workflow
    yaml = File.read(WORKFLOW)
    LabGroups.groups.each do |g|
      entry = yaml[/^\s*- group:\s*#{Regexp.escape(g)}\s*\n((?:\s{12,}\S.*\n)*)/, 1]
      refute_nil(entry, "no matrix entry for #{g} in #{WORKFLOW}")
      assert_match(/\b(docker|gobgp|frr|netns):\s*true/, entry,
        "the #{g} matrix entry names no dependency, so its job installs " \
        'nothing and every test in it omits itself')
    end
  end

  # The helper files beside the tests are not tests and must not be in a
  # group: requiring fault_matrix_scenario.rb on its own defines no test
  # case, and lab_helper.rb is loaded by the tests that need it.
  def test_the_helpers_are_not_groupable
    %w[lab_helper fault_matrix_scenario routegen_scenario
       two_speakers_scenario].each do |helper|
      assert(File.exist?("test/functional/lab/#{helper}.rb"), helper)
      assert_nil(LabGroups.group_of(helper),
        "#{helper} is a helper, not a test, and must not be in a group")
    end
  end

end
