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
require 'bgp/rib'

# BGP:: names are written out in full here, see Conventions in CLAUDE.md.
class TestBgpRibVrf < Test::Unit::TestCase

  def list(*entries) ; BGP::Rib::Vrf.list(entries) ; end

  def refused(*entries)
    assert_raise(ArgumentError) { list(*entries) }.message
  end

  def test_a_vrf_as_configured
    v = list({ 'name' => 'A', 'table' => 100, 'rd' => '65000:1', 'import' => ['65000:100', '10.255.0.1:7'],
               'export' => ['65000:100'], 'prefixes' => ['192.168.1.1/24'] }).first
    assert_equal(['A', 100, '65000:1', ['65000:100', '10.255.0.1:7'], ['65000:100'], ['192.168.1.0/24']], v.to_a)
  end

  # How a configuration read back from set lines gives a list of one.
  def test_a_list_of_one_may_be_one_value
    v = list({ 'name' => 'A', 'table' => '100', 'import' => '65000:100' }).first
    assert_equal([100, ['65000:100'], [], nil], [v.table, v.import, v.export, v.rd])
  end

  # RFC 4364 section 4.3.1.
  def test_imports_needs_one_route_target_in_common
    v = list({ 'name' => 'A', 'table' => 100, 'import' => ['65000:100', '65000:101'] }).first
    assert(v.imports?(['65000:999', '65000:101']))
    assert(!v.imports?(['65000:999']))
    assert(!v.imports?([]))
  end

  # Section 4.3.2: a VRF sends its routes only with an RD to put on them
  # and Export Targets to carry.
  def test_exports_needs_an_rd_and_export_targets
    assert(list({ 'name' => 'A', 'table' => 100, 'rd' => '65000:1', 'export' => ['65000:100'] }).first.exports?)
    assert(!list({ 'name' => 'A', 'table' => 100, 'export' => ['65000:100'] }).first.exports?)
    assert(!list({ 'name' => 'A', 'table' => 100, 'rd' => '65000:1' }).first.exports?)
  end

  def test_what_is_refused
    assert_equal('vrf A: unknown key(s) imprt: use one of name, table, rd, import, export, prefixes',
                 refused({ 'name' => 'A', 'table' => 100, 'imprt' => ['65000:1'] }))
    assert_equal('vrf A: table is required, a number', refused({ 'name' => 'A' }))
    assert_equal('vrfs: entry 1 has no name', refused({ 'table' => 100 }))
    assert_equal('vrf A: import: "x:y" is not ADMIN:NUMBER', refused({ 'name' => 'A', 'table' => 100, 'import' => ['x:y'] }))
    assert_equal('vrf A: rd: "65000" is not ADMIN:NUMBER', refused({ 'name' => 'A', 'table' => 100, 'rd' => '65000' }))
    assert_equal('vrfs: A named twice', refused({ 'name' => 'A', 'table' => 100 }, { 'name' => 'A', 'table' => 200 }))
    assert_equal('vrfs: A and B share table 100', refused({ 'name' => 'A', 'table' => 100 }, { 'name' => 'B', 'table' => 100 }))
  end
end
