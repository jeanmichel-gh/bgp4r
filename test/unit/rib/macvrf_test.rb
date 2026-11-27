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

# A MAC-VRF's configuration: docs/design/evpn.md, decision 2, pull
# request 2.
class TestBgpRibMacvrf < Test::Unit::TestCase

  def list(config)
    BGP::Rib::Macvrf.list(config, address: '10.255.0.12', as: 65000)
  end

  # RFC 7432 section 7.9's type 1 RD, the PE's address and the VNI; the
  # Route Targets AS:VNI both ways, as FRR's leaves sent in lab 3.
  def test_the_defaults
    m = list([{ 'vni' => 100 }]).first
    assert_equal([100, '10.255.0.12:100', ['65000:100'], ['65000:100'], 'vxlan', nil], m.to_a)
  end

  def test_given_values
    m = list([{ 'vni' => 100, 'rd' => '10.255.0.12:7', 'import' => ['65000:100', '65000:1'], 'export' => '65000:9' }]).first
    assert_equal([100, '10.255.0.12:7', ['65000:100', '65000:1'], ['65000:9'], 'vxlan', nil], m.to_a)
  end

  def test_none
    assert_equal([], list(nil))
  end

  def test_what_is_refused
    { 'macvrfs: is a list' => { 'vni' => 100 },
      'entry 1: vni is required' => [{}],
      'entry 1: vni is required, 1 to 16777215' => [{ 'vni' => 1 << 24 }],
      'entry 2 is not a mapping' => [{ 'vni' => 1 }, 'x'],
      'macvrf 100: unknown key(s) table' => [{ 'vni' => 100, 'table' => 1 }],
      'macvrf 100: rd: "x" is not ADMIN:NUMBER' => [{ 'vni' => 100, 'rd' => 'x' }],
      'macvrf 100: import is empty' => [{ 'vni' => 100, 'import' => [] }],
      'macvrf 100: export: "1.2:3" is not ADMIN:NUMBER' => [{ 'vni' => 100, 'export' => ['1.2:3'] }],
      'macvrfs: VNI 100 given twice' => [{ 'vni' => 100 }, { 'vni' => 100 }],
      'macvrfs: VNIs 100 and 200 share RD 1.1.1.1:1' => [{ 'vni' => 100, 'rd' => '1.1.1.1:1' },
                                                          { 'vni' => 200, 'rd' => '1.1.1.1:1' }] }.each do |msg, config|
      e = assert_raise(ArgumentError, msg) { list(config) }
      assert_match(msg, e.message)
    end
  end

  # RFC 7432 section 7.10: one Route Target in common imports.
  def test_imports
    m = list([{ 'vni' => 100, 'import' => ['65000:100', '65000:1'] }]).first
    assert_true(m.imports?(['65000:2', '65000:1']))
    assert_false(m.imports?(['65000:2']))
    assert_false(m.imports?([]))
  end

  # EVPN over MPLS (docs/design/evpn-mpls.md).

  def test_the_encapsulation
    assert_equal(%w[vxlan mpls], list([{ 'vni' => 1 }, { 'vni' => 2, 'encapsulation' => 'mpls' }]).collect(&:encapsulation))
    e = assert_raise(ArgumentError) { list([{ 'vni' => 1, 'encapsulation' => 'gre' }]) }
    assert_equal('macvrf 1: encapsulation is vxlan or mpls, not "gre"', e.message)
  end

  # Two labels each, unicast then BUM, in the order of the list; a VXLAN
  # MAC-VRF takes none.
  def test_the_labels_from_the_block
    l = list([{ 'vni' => 1, 'encapsulation' => 'mpls' }, { 'vni' => 2 }, { 'vni' => 3, 'encapsulation' => 'mpls' }])
    BGP::Rib::Macvrf.assign_labels(l, { 'start' => 25_000, 'size' => 4 })
    assert_equal([{ 'unicast' => 25_000, 'bum' => 25_001 }, nil, { 'unicast' => 25_002, 'bum' => 25_003 }], l.collect(&:labels))
  end

  # Removed, the others move down the block: the labels are fixed for a
  # run, since macvrfs: needs a restart (bgp/daemon/candidate.rb).
  def test_a_macvrf_removed
    l = list([{ 'vni' => 3, 'encapsulation' => 'mpls' }])
    BGP::Rib::Macvrf.assign_labels(l, { 'start' => 25_000, 'size' => 4 })
    assert_equal({ 'unicast' => 25_000, 'bum' => 25_001 }, l.first.labels)
  end

  def test_the_block_is_checked
    one = -> { list([{ 'vni' => 1, 'encapsulation' => 'mpls' }]) }
    {
      nil => 'evpn: labels: { start:, size: } is required: macvrf 1 is mpls',
      { 'start' => 10, 'size' => 4 } => 'evpn: labels: 10 to 13 is not 16 to 1048575 (RFC 3032)',
      { 'start' => 0xffffe, 'size' => 4 } => 'evpn: labels: 1048574 to 1048577 is not 16 to 1048575 (RFC 3032)',
      { 'start' => 25_000, 'size' => 1 } => 'evpn: labels: 1 label(s) for 1 mpls MAC-VRFs, which take two each'
    }.each do |block, message|
      e = assert_raise(ArgumentError, block.inspect) { BGP::Rib::Macvrf.assign_labels(one.call, block) }
      assert_equal(message, e.message)
    end
    assert_equal([], BGP::Rib::Macvrf.assign_labels(list([{ 'vni' => 1 }]), nil).collect(&:labels).compact,
                 'no block needed with no mpls MAC-VRF')
  end

  def test_the_block_may_not_overlap_l3vpns
    e = assert_raise(ArgumentError) do
      BGP::Rib::Macvrf.assign_labels(list([{ 'vni' => 1, 'encapsulation' => 'mpls' }]), { 'start' => 24_999, 'size' => 10 },
                                     { 'start' => 24_000, 'size' => 1000 })
    end
    assert_equal('evpn: labels: 24999 to 25008 overlaps l3vpn: labels: 24000 to 24999', e.message)
    BGP::Rib::Macvrf.assign_labels(list([{ 'vni' => 1, 'encapsulation' => 'mpls' }]), { 'start' => 25_000, 'size' => 10 },
                                   { 'start' => 24_000, 'size' => 1000 })
  end
end
