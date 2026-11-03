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
require 'bgp4r'
# The build gate is probed in exactly one place, CoverageMatrix.families,
# which has a guard of its own saying the gate's answer is SAFI keyed. A
# second copy of that probe here is the drift this repository keeps
# meeting, so this file reads that one. The cost is that a family wired
# into the gate fails a test in two files; that is the right number,
# since the report and the catalog each have to learn about it.
require './test/coverage_matrix'

# What this guards is that the catalog cannot go stale, which is the only
# way a catalog of representatives goes wrong: the entries themselves are
# measured by the suite on every run, and the two registries it is
# supposed to cover grow without asking it.
#
# So every test here is derived from something outside the catalog.
# `Attr.registrations` decides which attributes want an entry, the build
# gate decides which families do, and `Fault::CATALOG` decides which of
# the valid-reports-nothing assertions actually bite.
class SpecimenTest < Test::Unit::TestCase

  include BGP

  # ---- the catalog covers both registries ----------------------------

  # Register attribute 42 and this fails until it has a specimen or a
  # stated reason not to. That is the whole point of the file.
  def test_every_registered_attribute_has_a_specimen_or_a_reason
    covered = Specimen.attributes.collect { |_, type| type }
    missing = Attr.registrations.collect(&:type) - covered -
              Specimen::ENVELOPES.keys
    assert_equal([], missing.sort,
                 'a registered path attribute with no Specimen::CATALOG ' \
                 'entry: add one, or add it to Specimen::ENVELOPES with ' \
                 'the reason it needs none')
  end

  def test_no_specimen_names_an_unregistered_attribute
    extra = Specimen.attributes.collect { |_, type| type } -
            Attr.registrations.collect(&:type)
    assert_equal([], extra.sort,
                 'a specimen for an attribute type nothing registers')
  end

  # The two halves have to partition the registry, not merely cover it.
  # An attribute in both would be measured twice and read as covered
  # twice over; the count is what catches that.
  def test_the_entries_and_the_envelopes_partition_the_registry
    both = Specimen.attributes.collect { |_, t| t } & Specimen::ENVELOPES.keys
    assert_equal([], both, 'an attribute that is both a specimen and an envelope')
    assert_equal(Attr.registrations.size,
                 Specimen.attributes.size + Specimen::ENVELOPES.size)
  end

  def test_every_envelope_says_why_it_needs_no_specimen
    bare = Specimen::ENVELOPES.select { |_, why| why.to_s.strip.empty? }.keys
    assert_equal([], bare, 'an envelope with no reason beside it')
  end

  # Wire a SAFI into MpReachCommon#set and this fails until it has a
  # specimen. The gate is the authority on which families exist, not a
  # list anybody typed.
  def test_every_family_the_gate_knows_has_a_specimen
    known = CoverageMatrix.families.collect { |_, safi| safi }.uniq
    missing = known - Specimen.families.collect { |_, _, safi| safi }
    assert_equal([], missing.sort,
                 'the build gate accepts a SAFI with no Specimen::CATALOG ' \
                 'entry, so nothing can send that family by name')
  end

  def test_no_specimen_names_a_family_the_gate_refuses
    known = CoverageMatrix.families.collect { |_, safi| safi }.uniq
    extra = Specimen.families.collect { |_, _, safi| safi } - known
    assert_equal([], extra.sort,
                 'a specimen for a SAFI the build gate would refuse to build')
  end

  # A specimen uses the family's real AFI, 25 for EVPN and 16388 for
  # BGP-LS, where CoverageMatrix probes AFI 1 because the gate branches
  # on the SAFI. So the pair has to be one the gate really accepts, which
  # is a stronger statement than the SAFI being known.
  def test_every_family_specimen_uses_a_pair_the_gate_accepts
    bad = Specimen.families.reject { |_, afi, safi|
      CoverageMatrix.gate_knows?(afi, safi)
    }
    assert_equal([], bad, 'a specimen whose own AFI and SAFI the gate refuses')
  end

  # ---- the entries are what they claim -------------------------------

  def test_every_name_is_unique
    assert_equal(Specimen.names.size, Specimen.names.uniq.size)
    assert_equal([], Specimen.names.reject { |n| n.is_a?(Symbol) })
  end

  def test_every_entry_has_a_description
    bare = Specimen.catalog.select { |e| e[:description].to_s.strip.empty? }
    assert_equal([], bare.collect { |e| e[:name] })
  end

  def test_every_attribute_specimen_builds_the_type_it_claims
    Specimen.attributes.each do |name, type|
      assert_equal(type, Specimen.build(name).type, name.to_s)
    end
  end

  def test_every_family_specimen_builds_the_pair_it_claims
    Specimen.families.each do |name, afi, safi|
      a = Specimen.build(name)
      assert_equal(ATTR::MP_REACH, a.type, name.to_s)
      assert_equal([afi, safi], [a.afi, a.safi], name.to_s)
    end
  end

  # Not a tautology: a specimen is only useful if its octets survive the
  # trip, and three of the first drafts of these entries built an object
  # that encoded and came back as something else.
  def test_every_specimen_replays_byte_for_byte
    Specimen.names.each do |name|
      a = Specimen.build(name)
      h = a.to_shex
      assert_equal(h, a.class.new([h].pack('H*').is_packed).to_shex, name.to_s)
    end
  end

  def test_build_refuses_a_name_it_does_not_have
    e = assert_raise(ArgumentError) { Specimen.build(:no_such_specimen) }
    assert_match(/Specimen::CATALOG/, e.message)
  end

  # Not that wire equals encode, which would be a tautology, but that the
  # as4byte argument reaches the attributes whose octets depend on it.
  # Five of them do, and the first draft of `wire` passed it to none, so
  # the 4-octet form it promised was the 2-octet form and a reader with
  # as4byte on saw a finding. Both halves are asserted: the five differ
  # between the two forms, and the rest are identical in both.
  def test_the_as4byte_argument_reaches_the_attributes_that_take_one
    differ, same = Specimen.names.partition { |n|
      Specimen.wire(n, true).unpack1('H*') != Specimen.wire(n, false).unpack1('H*')
    }
    # Two, and not the four that take the parameter. AS4_PATH and
    # AS4_AGGREGATOR accept it and ignore it, which is right: those two
    # exist to carry a 4-octet AS across a 2-octet session, so their
    # octets are 4-octet whatever the session negotiated. Measured, after
    # this assertion was written expecting four.
    assert_equal(%i[as_path aggregator], differ,
                 'the set of attributes whose octets depend on the session ' \
                 'AS width has changed, or wire stopped passing it down')
    assert_operator(same.size, :>, 20)
  end

  # A specimen in the 4-octet form parses clean under a 4-octet reader,
  # and that is the pairing the test above exists to protect.
  def test_each_form_parses_clean_under_a_reader_of_its_own_width
    Specimen.names.each do |name|
      [true, false].each do |as4|
        pa = Path_attribute.new(Specimen.wire(name, as4).is_packed, :as4byte => as4)
        assert_equal([], pa.errors.collect(&:reason), "#{name} as4byte=#{as4}")
      end
    end
  end

  # catalog is what a control plane reads, so it has to say which kind
  # each entry is without the caller knowing the subject is polymorphic.
  def test_the_catalog_hashes_tell_the_two_kinds_apart
    fam = Specimen.catalog.select { |e| e[:afi] }
    att = Specimen.catalog.reject { |e| e[:afi] }
    assert_equal(Specimen.families.size, fam.size)
    assert_equal(Specimen.attributes.size, att.size)
    fam.each { |e| assert_equal(ATTR::MP_REACH, e[:type], e[:name].to_s) }
    att.each { |e| assert_nil(e[:safi], e[:name].to_s) }
    assert_equal(Specimen::CATALOG.size, Specimen.catalog.size)
  end

  # ---- validation reports nothing, and where that bites --------------

  # Cheap and uniform, and weak on its own: validation.rb has no rule for
  # most of these, so for them this passes whatever the entry builds. The
  # test below is the one with teeth.
  def test_no_specimen_reports_a_finding
    Specimen.names.each do |name|
      pa = Path_attribute.new(Specimen.wire(name).is_packed, :as4byte => true)
      assert_equal([], pa.errors.collect(&:reason), name.to_s)
      assert_equal([], pa.undecoded.collect(&:to_s), name.to_s)
    end
  end

  # The non-vacuous half, and the two catalogs checking each other.
  # Fault::CATALOG is the derived list of attributes validation.rb has a
  # rule for, so for each of those the pair is a real discrimination: the
  # valid specimen reports nothing and the faulty form reports something.
  # A specimen that quietly stopped being valid would pass the test above
  # and fail here.
  #
  # **Every fault case, not one per attribute type.** The first draft
  # took one case per type, and a sabotage that made `origin_value`
  # report nothing **passed**: ORIGIN's first case in the catalog is
  # `origin_length`, so the other two were never looked at. Checking all
  # of them is strictly stronger and costs nothing, and the one-per-type
  # version was weak rather than wrong.
  def test_the_specimen_and_the_fault_disagree_wherever_a_rule_exists
    checked = []
    fault_types.each do |type, fault_name|
      entry = Specimen.attributes.find { |_, t| t == type }
      next unless entry
      good = Path_attribute.new(Specimen.wire(entry[0]).is_packed, :as4byte => true)
      bad  = Path_attribute.new(Fault.wire(fault_name).is_packed, :as4byte => true)
      assert_equal([], good.errors.collect(&:reason),
                   "#{entry[0]}: the valid specimen reports a finding")
      assert_not_equal([], bad.errors.collect(&:reason),
                       "#{fault_name}: the faulty form reports none, so the " \
                       "rule this pair rests on is gone")
      checked << fault_name
    end
    assert_operator(checked.uniq.size, :>=, 14,
                    "only #{checked.uniq.size} fault cases pair with a " \
                    'specimen: did Fault::CATALOG shrink?')
  end

  private

  # [attribute type, fault name] for every Fault::CATALOG case, keyed by
  # the attribute the case actually builds rather than by a list. A case
  # that builds a whole Path_attribute contributes each type in it. Not
  # uniq'd: see the test above for what that cost.
  def fault_types
    Fault.names.flat_map { |name|
      built = Fault.build(name)
      attrs = built.is_a?(Path_attribute) ? built.attributes : [built]
      attrs.collect { |a| [a.type, name] }
    }
  end

end
