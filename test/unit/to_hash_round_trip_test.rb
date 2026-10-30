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

# The inventory of #to_hash round trips, asserted.
#
#   ruby -I. test/unit/to_hash_round_trip_test.rb
#
# Conventions says every class builds three ways, and that `to_hash`
# answers a hash that round trips through `new`. Not every class keeps
# that promise, and until now nothing said which. The ones that do keep
# it are the valuable part: `to_hash` exists so a test can be written and
# read as values rather than as hex, so a round trip that works today is
# something other people's test code is already built on.
#
# **The rule this file enforces is one way.** A gap may stay a gap. A
# round trip that works must not stop working. That is
# test_the_round_trips_that_work_still_work, and it is why this is a test
# and not a list in a document.
#
# Every verdict is **declared** in to_hash_catalog.rb and compared
# against a measurement, the way fault_matrix_scenario.rb declares what a
# router does and then asks the router. A verdict computed from the
# library would assert nothing: it would agree with whatever the library
# happened to do, which is how a conformance column in this repo once
# carried two wrong rows for months.
#
# This is one test file for many source files, which departs from the
# one-file-per-source-file rule in Conventions. Its subject is the
# convention itself rather than any one class, the same way
# optional_parameter_test.rb carries the guard for the three Unknown
# classes and neighbor_test.rb carries the suite wide name leak guard.
#
# BGP:: names are written out in full, see Conventions in CLAUDE.md.

require 'test/unit'
require 'bgp4r'
require 'bgp/orfs/orf'
require 'test/unit/to_hash_catalog'
require 'test/unit/to_hash_status'

class ToHashRoundTripTest < Test::Unit::TestCase

  # Resolved from this file rather than from the working directory, so
  # the file can be run from anywhere and not only from the repo root.

  # What the class's own `new` makes of its own hash.
  def own_route(name, entry)
    k = Object.const_get(name)
    obj = entry.build.call
    before = obj.encode
    flunk("the recipe for #{name} encodes to nil") if before.nil?
    k.new(obj.to_hash).encode == before
  rescue StandardError, NotImplementedError
    false
  end

  # What the other route makes of it: the attribute or message that owns
  # the class and reads these hashes, or, for a class nothing reads, the
  # same fields taken back out of the hash by hand. The second kind
  # proves the hash is complete even though no reader exists.
  def other_route(name, entry)
    obj = entry.build.call
    entry.via.call(obj.to_hash) == obj.encode
  rescue StandardError, NotImplementedError
    false
  end

  # The rule. A round trip that works is something other test code is
  # built on, so breaking one is a regression whatever the reason.
  def test_the_round_trips_that_work_still_work
    works = ToHashCatalog::ENTRIES.select { |_, e| [:ok, :ok_alone].include?(e.verdict) }
    assert(works.size > 20, 'the catalog should hold most of the library')
    works.each do |name, entry|
      assert(own_route(name, entry),
             "#{name} used to rebuild from its own to_hash and no longer does")
    end
  end

  # The same rule for the other route, which is the one most of these
  # hashes are actually read by. A hash that reads back through its
  # attribute today has to keep doing so.
  def test_the_other_routes_that_work_still_work
    ToHashCatalog::ENTRIES.select { |_, e| e.verdict == :elsewhere }.each do |name, entry|
      assert(other_route(name, entry),
             "#{name} used to rebuild by the route in its catalog entry " \
             'and no longer does')
    end
  end

  # The other direction. A gap that closes is good news, and it has to be
  # recorded rather than left asserting the old answer: a stale gap reads
  # as verified and sends the next reader after work already done.
  def test_the_known_gaps_are_still_gaps
    ToHashCatalog::ENTRIES.each do |name, entry|
      case entry.verdict
      when :elsewhere
        assert(!own_route(name, entry),
               "#{name} now rebuilds from its own to_hash; make it :ok in " \
               "to_hash_catalog.rb")
      when :ok_alone
        assert(!other_route(name, entry),
               "#{name} now rebuilds through its attribute too; make it :ok")
      when :lossy
        assert(!own_route(name, entry),
               "#{name} now rebuilds from its own to_hash; it is no longer lossy")
        next if entry.via.nil?
        assert(!other_route(name, entry),
               "#{name} now rebuilds by the route in its entry; it is no " \
               'longer lossy')
      end
    end
  end

  # A :lossy entry claims information is gone rather than that a door is
  # missing, and those are different things. Nothing mechanical can prove
  # a negative, so what is checked is that the claim was written down
  # deliberately, with its mechanism and a reproduction, because that
  # text is now what a reader is shown.
  def test_every_gap_says_what_it_loses_and_what_was_decided
    ToHashCatalog::ENTRIES.reject { |_, e| e.verdict == :ok }.each do |name, entry|
      assert(entry.loses.to_s.size > 8, "#{name} does not say what its hash loses")
      assert(ToHashCatalog::DECISIONS.key?(entry.decision),
             "#{name} has no decision; one of #{ToHashCatalog::DECISIONS.keys.inspect}")
    end
  end

  # An :elsewhere entry has to name the route, or it is an excuse rather
  # than a measurement.
  def test_every_entry_that_claims_another_route_gives_one
    ToHashCatalog::ENTRIES.each do |name, entry|
      next unless [:elsewhere, :ok_alone].include?(entry.verdict)
      assert_not_nil(entry.via, "#{name} is #{entry.verdict} with no route given")
    end
  end

  # The anti-staleness guard, and the reason the catalog is worth having.
  # A new class answering to_hash has to be measured and decided rather
  # than quietly joining the library, and a class that loses its to_hash
  # has to leave the catalog.
  def test_every_class_that_answers_to_hash_is_in_the_catalog
    listed = ToHashCatalog::ENTRIES.keys + ToHashCatalog::NO_RECIPE.keys
    answering = ToHashCatalog.classes_answering_to_hash
    assert_equal([], (answering - listed).sort,
                 'these answer to_hash and are in neither ENTRIES nor ' \
                 'NO_RECIPE in to_hash_catalog.rb')
    assert_equal([], (listed - answering).sort,
                 'these are in the catalog but no longer answer to_hash')
  end

  # Conventions: if an object can be rebuilt from its own to_hash, a test
  # must prove it. The catalog is one half of that and this file asserts
  # it. The other half is an assertion in the class's own test file,
  # which is where a reader looks, and this is what keeps that half
  # honest rather than aspirational.
  #
  # The match is deliberately loose: a line naming to_hash and a
  # constructor, in a file that names the class. It is answering "does
  # anything assert this at all", not policing which file does it, so a
  # class covered from a neighbouring file still passes. A tighter rule
  # would fail legitimate tests, and this one has a job only while the
  # answer is otherwise nothing.
  def test_every_working_round_trip_is_asserted_in_a_class_test_file
    files = Dir['test/unit/**/*_test.rb'] - [__FILE__.sub("#{Dir.pwd}/", '')]
    bodies = files.reject { |f| File.expand_path(f) == __FILE__ }
                  .collect { |f| [f, File.read(f)] }
    working = ToHashCatalog::ENTRIES.select { |_, e| [:ok, :ok_alone].include?(e.verdict) }
    assert(working.size > 20)
    missing = working.keys.reject do |name|
      leaf = name.sub('BGP::', '').split('::').last
      bodies.any? do |_, body|
        next false unless body =~ /\b#{Regexp.escape(leaf)}\b/
        body.lines.any? { |l| l.include?('to_hash') && l =~ /\.new(_hash|_ntop\w*)?\(/ }
      end
    end
    assert_equal([], missing.sort,
                 'these round trips work and no class test file asserts one; ' \
                 'Conventions requires a test where the round trip works')
  end

  def test_every_class_without_a_recipe_says_why
    assert(!ToHashCatalog::NO_RECIPE.empty?)
    ToHashCatalog::NO_RECIPE.each do |name, reason|
      assert(reason.to_s.size > 12, "#{name} is excluded without a reason")
    end
  end

  # The DYN_CAP classes are generated in capabilities.rb as a bare
  # subclass of each CAP class, overriding nothing, so each one's hash
  # behaviour is its parent's by construction. That is why they are not
  # in the catalog, and this keeps it true: a DYN_CAP class that grew a
  # to_hash of its own would need measuring.
  def test_every_dyn_cap_class_is_a_bare_subclass_of_its_cap_namesake
    dyn = BGP::OPT_PARM::DYN_CAP.constants(false)
    assert(dyn.size >= 8, 'DYN_CAP should mirror CAP')
    dyn.each do |c|
      k = BGP::OPT_PARM::DYN_CAP.const_get(c)
      assert_equal(BGP::OPT_PARM::CAP.const_get(c), k.superclass,
                   "DYN_CAP::#{c} should be a bare subclass of CAP::#{c}")
      assert_equal([], k.instance_methods(false) & [:to_hash],
                   "DYN_CAP::#{c} defines its own to_hash and needs a catalog entry")
    end
  end

  # There used to be two tests here comparing this catalog against
  # docs/to-hash-round-trips.md, because that document was the half a
  # person read and this is the half that is true. The document is gone.
  # Its tables were generated from this catalog and its prose was not,
  # and it was the prose that drifted, spending four pull requests
  # ranking work that two of them had already finished. What a person
  # reads now is printed from here, by rake to_hash:status and
  # rake to_hash:pending, so there is no second copy to keep in step.
  #
  # This is what is left of those two. The printing has to name every
  # class, so a new entry cannot be measured by the suite and then left
  # out of the view a person actually looks at.
  def test_the_status_view_names_every_class_measured
    status = ToHashStatus.status
    ToHashCatalog::ENTRIES.each_key do |name|
      assert(status.include?(name.sub('BGP::', '')),
             "rake to_hash:status leaves out #{name}")
    end
    assert_match(/#{ToHashCatalog::ENTRIES.size} classes measured/, status)
    pending = ToHashCatalog::ENTRIES.select { |_, e| e.decision == :fix }
    assert_match(/#{pending.size} to fix/, ToHashStatus.pending)
    pending.each_key do |name|
      assert(ToHashStatus.pending.include?(name.sub('BGP::', '')),
             "rake to_hash:pending leaves out #{name}")
    end
  end

  # CLAUDE.md tells a reader to run two rake tasks, and nothing else in
  # the tree runs them: CI calls test/run_unit.rb directly, and `rake` is
  # a development gem that is not on PATH everywhere. So a rename on
  # either side would leave the documented command broken with nothing
  # saying so, which is the failure this file exists to stop. The
  # Rakefile is read as text rather than loaded, to keep rake out of the
  # suite's requires.
  def test_the_documented_rake_tasks_exist
    rakefile = File.read(File.expand_path('../../Rakefile', __dir__))
    %w[status pending].each do |name|
      assert_match(/^\s*task :#{name}\b/, rakefile,
                   "the Rakefile no longer defines to_hash:#{name}")
      assert(ToHashStatus.respond_to?(name),
             "ToHashStatus.#{name} is gone, so to_hash:#{name} cannot work")
    end
    assert_match(/namespace :to_hash do/, rakefile)
  end

end
