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

# Installs the BGP4R_LOG switch as a side effect of being required, so
# one test file can be run with logging on and no runner:
#
#   BGP4R_LOG=debug ruby -I. -rtest/log_on test/functional/rib_router_test.rb
#
# **This file exists because the three runners are not the only way a
# test is run, and the first draft of docs/running-tests.md claimed the
# switch reached a single file when it did not.** `run_unit.rb`,
# `run_feature.rb` and `run_lab.rb` each call `LogSwitch.install`
# themselves, which does nothing for `ruby -I. <one file>`: there is no
# shared test helper in this tree for 170 files to require, and adding
# one is a change to every one of them. `-r` is Ruby's own hook for
# exactly this, so this is the whole of what is needed.
#
# A side effect on require is deliberate here and is why it is a file of
# its own rather than a method on `LogSwitch`: requiring
# `test/log_switch` must stay free of side effects, since
# `test/unit/features_test.rb` requires it to assert on its table.
require './test/log_switch'

LogSwitch.install
