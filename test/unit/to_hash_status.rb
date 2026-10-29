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

# What the #to_hash round trips look like right now.
#
#   rake to_hash:status      every class, grouped by verdict
#   rake to_hash:pending     only the ones still to fix
#
# Or without rake, which is not on PATH everywhere:
#
#   ruby -I. test/unit/to_hash_status.rb
#   ruby -I. test/unit/to_hash_status.rb pending
#
# This replaces docs/to-hash-round-trips.md, which held the same thing as
# prose and a table. The table was generated from the catalog and the
# prose was not, and it was the prose that drifted: it spent four pull
# requests ranking work that two of them had already finished, while the
# table beside it stayed true because to_hash_round_trip_test.rb compares
# it against the catalog row by row.
#
# So there is nothing to keep in step any more. Every line printed here
# is read out of to_hash_catalog.rb, which the test suite measures
# against the library on every run, and the verdict shown is the declared
# one that the suite proves. A number printed here cannot be stale
# without a test failing first.
module ToHashStatus

  HEADINGS = {
    :ok       => 'Round trip through their own new',
    :elsewhere => 'Rebuilt by another route, usually the owning attribute',
    :ok_alone => 'Own new works, the owning attribute does not',
    :lossy    => 'Lose information',
  }.freeze

  class << self

    # Every class, grouped by verdict, with what a gap loses.
    def status
      out = +"#{ToHashCatalog::ENTRIES.size} classes measured, from test/unit/to_hash_catalog.rb\n"
      out << "#{ToHashCatalog::NO_RECIPE.size} more answer to_hash and have no recipe, each with its reason there\n"
      HEADINGS.each do |verdict, heading|
        names = by_verdict(verdict)
        next if names.empty?
        out << "\n#{heading}: #{names.size}\n"
        names.each { |name| out << line(name) }
      end
      out << "\n#{pending_names.size} still to fix, #{kept.size} left as they are.\n"
      out << "rake to_hash:pending prints the first list on its own.\n"
      out
    end

    # Only what is still to fix, which is the tracking list.
    def pending
      names = pending_names
      return +"Nothing marked to fix in test/unit/to_hash_catalog.rb.\n" if names.empty?
      out = +"#{names.size} to fix, from test/unit/to_hash_catalog.rb:\n"
      names.each { |name| out << line(name) }
      out << "\nEach one is a declared verdict the suite measures, so this list\n"
      out << "shortens only when a fix lands and its entry is struck.\n"
      out
    end

    private

    def pending_names
      ToHashCatalog::ENTRIES.select { |_, e| e.decision == :fix }.keys
    end

    def kept
      ToHashCatalog::ENTRIES.select { |_, e| e.decision == :keep }.keys
    end

    def by_verdict(verdict)
      ToHashCatalog::ENTRIES.select { |_, e| e.verdict == verdict }.keys
    end

    def line(name)
      entry = ToHashCatalog::ENTRIES[name]
      short = name.sub('BGP::', '')
      return format("  %s\n", short) if entry.verdict == :ok && entry.decision.nil?
      format("  %s\n%s", short, wrap(entry.loses.to_s, '      '))
    end

    def wrap(text, indent)
      return +'' if text.empty?
      out, line = +'', indent.dup
      text.split(' ').each do |word|
        if line.size + word.size + 1 > 76 && line.strip != ''
          out << line << "\n"
          line = indent + word
        else
          line << (line.strip == '' ? '' : ' ') << word
        end
      end
      out << line << "\n"
    end

  end

end

if __FILE__ == $0
  require 'test/unit/to_hash_catalog'
  print ARGV.first == 'pending' ? ToHashStatus.pending : ToHashStatus.status
end
