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
require './test/coverage_matrix'

# What this guards is the **declared** half of test/coverage_matrix.rb.
# The derived half cannot go stale, which is the whole reason it is
# derived; `VOUCHES`, `SLUGS`, `LAB_FAMILIES` and `NOT_A_FAMILY` can, and
# each of them going stale makes the report quietly wrong rather than
# loudly broken. A family wired in with no slug would print a blank row.
# A new lab test with an unknown stem would be absent from the family
# table with nothing saying so. A verdict citing a document that moved
# would read as sourced.
#
# So every test here asks the same question from a different side: does
# the declaration still match what is on disk and in the library?
class CoverageMatrixTest < Test::Unit::TestCase

  CM = CoverageMatrix

  # ---- the families -------------------------------------------------

  def test_every_safi_the_gate_knows_has_a_name
    assert_equal([], CM.unnamed_safis,
                 'a SAFI was wired into the build gate with no entry in ' \
                 "CoverageMatrix::SLUGS, so it would print as a blank row")
  end

  def test_every_family_the_gate_knows_has_a_vouches_entry
    missing = CM.family_slugs.reject { |s| CM::VOUCHES.key?(s) }
    assert_equal([], missing,
                 'add an entry to CoverageMatrix::VOUCHES, even :none for ' \
                 'both routers, or the row prints ? for an interop verdict')
  end

  def test_vouches_names_no_family_the_gate_does_not_know
    extra = CM::VOUCHES.keys - CM.family_slugs
    assert_equal([], extra,
                 'VOUCHES names a family the build gate does not accept')
  end

  def test_every_verdict_is_one_of_the_four
    bad = []
    CM::VOUCHES.each do |slug, v|
      %i[gobgp frr].each do |r|
        bad << [slug, r, v[r]] unless CM::VERDICTS.include?(v[r])
      end
    end
    assert_equal([], bad, "a verdict outside #{CM::VERDICTS.inspect}")
  end

  # The one that catches the mistake this file shipped twice: a verdict
  # beside a count of zero, which is two columns disagreeing and a reader
  # cannot tell which is wrong. `:via` exists because of it.
  def test_a_verdict_other_than_none_has_at_least_one_lab_file
    bare = []
    CM::VOUCHES.each do |slug, v|
      %i[gobgp frr].each do |r|
        next if v[r] == :none
        bare << [slug, r] if CM.router_tests_for(slug, r).empty?
      end
    end
    assert_equal([], bare,
                 'a verdict with no lab file behind it: either the file ' \
                 'moved, or the entry wants a :via, or the verdict is :none')
  end

  def test_none_means_no_lab_file
    wrong = []
    CM::VOUCHES.each do |slug, v|
      %i[gobgp frr].each do |r|
        next unless v[r] == :none
        wrong << [slug, r, CM.router_tests_for(slug, r)] if
          CM.router_tests_for(slug, r).any?
      end
    end
    assert_equal([], wrong,
                 'a lab file carries a family declared :none for that ' \
                 'router: read the file and give it a real verdict')
  end

  def test_every_cited_document_exists
    missing = CM::VOUCHES.filter_map { |slug, v|
      d = v[:doc] or next
      [slug, d] unless File.exist?(d)
    }
    assert_equal([], missing,
                 'a verdict cites a document that is not there, so it ' \
                 'reads as sourced and is not')
  end

  # A verdict that is not :none without a document to read is the shape
  # this report exists to prevent: a one word answer to a question whose
  # answer is a section.
  def test_every_measured_family_cites_a_document
    bare = CM::VOUCHES.filter_map { |slug, v|
      next if v[:doc]
      slug if [v[:gobgp], v[:frr]].any? { |x| x != :none }
    }
    assert_equal([], bare, 'a measured family with no :doc to read')
  end

  # ---- the lab tests ------------------------------------------------

  def test_every_router_lab_test_is_placed
    assert_equal([], CM.unplaced_router_tests,
                 'a *_gobgp_test.rb or *_frr_test.rb on disk is neither in ' \
                 'LAB_FAMILIES nor declared in NOT_A_FAMILY, so it is ' \
                 'absent from the family table with nothing saying so')
  end

  def test_lab_families_names_no_file_that_is_not_there
    stems = CM.router_tests.collect { |stem, _, _| stem }.uniq
    assert_equal([], CM::LAB_FAMILIES.keys - stems,
                 'LAB_FAMILIES names a lab test stem with no file')
  end

  def test_not_a_family_names_no_file_that_is_not_there
    stems = CM.router_tests.collect { |stem, _, _| stem }.uniq
    assert_equal([], CM::NOT_A_FAMILY.keys - stems,
                 'NOT_A_FAMILY names a lab test stem with no file')
  end

  def test_no_stem_is_both_a_family_and_not_one
    both = CM::LAB_FAMILIES.keys & CM::NOT_A_FAMILY.keys
    assert_equal([], both)
  end

  def test_lab_families_names_only_families_the_gate_knows
    bad = CM::LAB_FAMILIES.flat_map { |_, v| v }.uniq - CM.family_slugs
    assert_equal([], bad)
  end

  def test_every_not_a_family_entry_says_why
    bare = CM::NOT_A_FAMILY.select { |_, why| why.to_s.strip.empty? }.keys
    assert_equal([], bare, 'a declaration with no reason beside it')
  end

  def test_the_router_tests_are_found_at_all
    # The glob is the derived half, so a path typo would empty the whole
    # family table and every count with it. Six families have one.
    assert_operator(CM.router_tests.size, :>=, 10,
                    "only #{CM.router_tests.size} router lab tests found: " \
                    "is CoverageMatrix::LAB still the right path?")
  end

  # ---- the attributes -----------------------------------------------

  def test_every_fault_case_is_placed_under_an_attribute
    unplaced = CM.faults_by_type[nil]
    assert_nil(unplaced,
               'a BGP::Fault::CATALOG case could not be keyed to an ' \
               'attribute, so its coverage reads as missing')
  end

  def test_every_fault_case_appears_exactly_once
    placed = CM.faults_by_type.values.flatten.sort
    assert_equal(BGP::Fault.names.collect(&:to_s).sort, placed.collect(&:to_s).sort)
  end

  def test_the_attribute_list_is_the_registry
    assert_equal(BGP::Attr.registrations.size, CM.attributes.size)
  end

  def test_direct_names_a_registered_attribute
    names = BGP::Attr.registrations.collect { |r| r.klass.to_s.sub('BGP::', '') }
    assert_equal([], CM::DIRECT.keys - names,
                 'CoverageMatrix::DIRECT names a class that is not a ' \
                 'registered path attribute')
  end

  # DIRECT is the attributes a lab test names that have no fault case.
  # An entry for one that has a case would be redundant and would hide
  # the fact that the matrix already covers it.
  def test_direct_only_names_attributes_with_no_fault_case
    f = CM.faults_by_type
    redundant = CM::DIRECT.keys.select { |n|
      r = BGP::Attr.registrations.find { |x| x.klass.to_s.sub('BGP::', '') == n }
      r && (f[r.type] || []).any?
    }
    assert_equal([], redundant,
                 'DIRECT names an attribute the fault matrix already sends')
  end

  # ---- the report ---------------------------------------------------

  def test_the_report_prints
    r = CM.report
    assert_match(/\APath attributes\n/, r)
    assert_match(/^Address families, as the build gate knows them$/, r)
    assert_match(/^Summary$/, r)
  end

  # The two halves of the report have to agree, since a reader compares
  # them. The never-sent list is built from routers_for and the fault
  # count from the catalog, and they differ by exactly the DIRECT
  # entries: that is the bug this file shipped, ATTR_SET listed as never
  # sent one line below its own row saying GoBGP had it.
  def test_the_never_sent_count_agrees_with_the_attribute_table
    f = CM.faults_by_type
    without = CM.attributes.count { |r| (f[r.type] || []).empty? }
    never = CM.attributes.count { |r| CM.routers_for(r, f[r.type] || []).empty? }
    assert_equal(without - CM::DIRECT.size, never,
                 'the summary and the attribute table disagree about which ' \
                 'attributes have been sent to a router')
  end

  def test_every_family_row_carries_a_verdict_for_both_routers
    CM.family_slugs.each do |s|
      v = CM.vouches(s)
      assert_not_nil(v, s)
      assert_not_nil(v[:gobgp], s)
      assert_not_nil(v[:frr], s)
    end
  end

  def test_the_family_table_names_every_family_the_gate_knows
    t = CM.family_table
    CM.family_slugs.each { |s| assert_match(/^#{Regexp.escape(s)}\s/, t, s) }
  end

  def test_the_attribute_table_names_every_registered_attribute
    t = CM.attribute_table
    CM.attributes.each do |r|
      assert_match(/\s#{Regexp.escape(r.klass.to_s.sub('BGP::', ''))}\s/, t)
    end
  end

  def test_the_report_is_ascii
    assert_equal(Encoding::US_ASCII,
                 CM.report.dup.force_encoding('US-ASCII').encoding)
    assert(CM.report.ascii_only?,
           'the report has to paste into a terminal and into a document')
  end

end
