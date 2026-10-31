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

# Which lab test goes in which CI job.
#
# The lab tests used to run as one serial suite, which made the lab job
# the sum of every file and the whole workflow's clock: 12m42s on
# 95fe87b where no other job reached 50s. They are independent, so CI
# runs them as a matrix and the job's cost becomes the slowest group
# rather than the total.
#
# **The grouping lives here and not in the workflow**, for one reason: a
# list in the YAML would let a new lab test run in no job at all, and
# nothing would say so. `test/unit/lab_groups_test.rb` requires every
# file under test/functional/lab to be in exactly one group, so a new
# one fails the unit suite until it is assigned. That is the same guard
# shape as the discovered tables in evpn_doc_test.rb.
#
# Each group's name says the rule for where a new file goes, and the
# split is balanced against measured times so no group dominates. The
# times are from 2026-10-31, gobgpd 3.23.0 and bgpd 8.4.4, and are
# comments rather than assertions because a runner is not this machine.
module LabGroups

  DIR = 'test/functional/lab'

  GROUPS = {
    # Needs a Docker daemon. The fault matrix here is the GoBGP **4**
    # measurement, where gobgp-matrix below is GoBGP 3, which is
    # deliberate: the two versions do not answer alike.
    'compose' => %w[
      fault_matrix_test
      routegen_test
      two_speakers_test
    ],

    # The RFC 7606 fault matrix against a native gobgpd. One file, and
    # still the heaviest: 18 cases, each on a session of its own. 123s.
    'gobgp-matrix' => %w[
      fault_matrix_native_test
    ],

    # What GoBGP makes of something bgp4r learned to speak. A new EVPN,
    # flow spec or RT-constrain test goes here, and so does an
    # attribute's, which `attr_set_gobgp_test` is: the group is about
    # where the outside opinion comes from, not about the NLRI. ~273s as
    # a group, measured on 2026-10-31, where it was 139s with two files
    # and 223s with three. Each entry costs 50 to 90s, because every
    # case wants a session of its own.
    #
    # The rule stays the rule, so a new one goes here even though that
    # makes this group the lab job's clock. **Splitting it is now the
    # obvious next lever**, since it is roughly double the next group
    # and growing by a file a day; it is a line here plus a matrix
    # entry. Rebalancing instead by moving a file into a group whose
    # name does not describe it is not, because the names are what tell
    # the next person where to put things.
    'gobgp-families' => %w[
      attr_set_gobgp_test
      evpn_gobgp_test
      flow_spec_gobgp_test
      rt_constrain_gobgp_test
    ],

    # What GoBGP makes of our export side and of RFC 7911. A new
    # send-side lab test against GoBGP goes here. 74s.
    'gobgp-router' => %w[
      add_path_gobgp_test
      rib_router_gobgp_test
    ],

    # Everything needing FRR's bgpd. Small enough to stay one group:
    # 87s all together, under every group above.
    'frr' => %w[
      evpn_frr_test
      fault_matrix_frr_test
      flow_spec_frr_test
      rib_router_frr_test
    ],

    # No router binary and no Docker. fib_test is here and needs
    # CAP_NET_ADMIN, which is why this group's job runs it a second time
    # under sudo; see the workflow. 10s.
    'local' => %w[
      fib_test
      generate_test
      log_level_test
      routegen_loopback_test
      speaker_test
    ],
  }.freeze

  class << self

    # Every lab test file on disk, as paths. This is a glob and not the
    # union of GROUPS, so `ruby test/run_lab.rb` with no argument runs a
    # new file the day it lands, whether or not it has been assigned.
    # The guard test is what makes the assignment happen.
    def all_files
      Dir["#{DIR}/*_test.rb"].sort
    end

    # The basenames on disk, without the extension, which is the form
    # GROUPS lists.
    def present
      all_files.collect { |f| File.basename(f, '.rb') }.sort
    end

    def groups
      GROUPS.keys
    end

    # The paths of one group. Raises on a name that is not a group,
    # rather than running nothing and exiting 0, which would read as a
    # passing job.
    def files(group)
      names = GROUPS[group]
      unless names
        raise ArgumentError,
          "unknown lab group #{group.inspect}, have #{groups.join(', ')}"
      end
      names.sort.collect { |n| "#{DIR}/#{n}.rb" }
    end

    # The group a file belongs to, or nil. Used by the guard test to
    # name what is unassigned.
    def group_of(name)
      GROUPS.each { |g, names| return g if names.include?(name) }
      nil
    end

  end

end
