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

# Runs every lab test under test/functional/lab: the loopback speaker test
# and one Docker Compose test per topology.
#
#   ruby test/run_lab.rb
#
# Compose tests are skipped when Docker is not available, unless
# LAB_REQUIRE_DOCKER=1 is set, as in CI.
#
# One group, which is how CI runs them, a job each, so the lab's cost is
# the slowest group and not the total. test/lab_groups.rb says which
# file is in which group and why:
#
#   ruby test/run_lab.rb gobgp-matrix
#   ruby test/run_lab.rb --groups          # print the names and exit
#
# With no argument every file on disk runs, as it always did, and that
# stays a glob rather than the union of the groups: a new lab test runs
# here the day it lands whether or not it has been assigned to a group.
# test/unit/lab_groups_test.rb is what makes it get assigned.

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
Dir.chdir(root)

require './test/lab_groups'

if ARGV.first == '--groups'
  puts LabGroups.groups
  exit 0
end

# ArgumentError on an unknown name, rather than running nothing and
# exiting 0, which a CI job would report as a pass.
files = ARGV.first ? LabGroups.files(ARGV.shift) : LabGroups.all_files

files.each { |f| require "./#{f}" }
