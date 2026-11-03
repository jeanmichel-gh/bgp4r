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

# Runs every test about one BGP feature, across the unit, functional and
# lab tiers. `test/features.rb` says which test is about what, and why
# that is a second axis rather than a replacement for the tree's own.
#
#   ruby test/run_feature.rb                 # the features, by area
#   ruby test/run_feature.rb evpn            # everything about EVPN
#   ruby test/run_feature.rb evpn --unit     # one tier of it
#   ruby test/run_feature.rb --area families # every feature of one area
#   ruby test/run_feature.rb evpn --list     # the files, without running
#   ruby test/run_feature.rb --doc           # the document, on stdout
#
# Tiers run cheapest first: unit, then functional, then lab. A lab test
# omits itself when the binary it wants is missing, so asking for a
# feature on a machine with neither gobgpd nor FRR runs what it can and
# says what it skipped. `--unit` is the form that needs nothing anywhere.
#
# Turn logging on with BGP4R_LOG, which run_unit.rb honours too:
#
#   BGP4R_LOG=debug ruby test/run_feature.rb evpn --unit

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
Dir.chdir(root)

require './test/features'
require './test/log_switch'
LogSwitch.install

TIERS = %i[unit functional lab].freeze

def usage
  out = +"Usage: ruby test/run_feature.rb [FEATURE] [--unit|--functional|--lab] [--list]\n"
  Features.areas.each do |area|
    out << "\n#{area}: #{Features::AREAS[area]}\n"
    Features.in_area(area).each do |name|
      f = Features.feature(name)
      n = TIERS.sum { |t| Features.files(name, t).size }
      out << format("  %-17s %-3d %s\n", name, n, f[:about])
    end
  end
  out << "\n--area NAME runs every feature of one area. --doc prints the document.\n"
  out
end

tiers = []
list  = false
args  = []
# **Anything this does not recognise goes to test-unit, and ARGV has to
# be emptied of what does.** test-unit parses ARGV itself, at exit, so a
# `--unit` left in it makes the run print test-unit's own help and exit
# non-zero with every test having passed. Measured, and it is why
# `run_lab.rb` shifts its argument rather than reading it in place.
rest = []
passthrough = false

ARGV.each do |a|
  if passthrough
    rest << a
    next
  end
  case a
  when '--unit'       then tiers << :unit
  when '--functional' then tiers << :functional
  when '--lab'        then tiers << :lab
  when '--list'       then list = true
  when '--'           then passthrough = true
  when '--doc'
    require './test/features_doc'
    print FeaturesDoc.document
    exit 0
  when '--areas'
    puts Features.areas
    exit 0
  when '-h', '--help'
    print usage
    exit 0
  when /\A-/ then rest << a          # -n test_foo and the like
  else
    # A bare word after an unrecognised flag is that flag's value, not a
    # feature name: `-n test_x` must not be read as feature `test_x`.
    rest.last&.start_with?('-') ? rest << a : args << a
  end
end

ARGV.replace(rest)

tiers = TIERS if tiers.empty?

if args.empty?
  print usage
  exit 0
end

# --area NAME, so one word selects a whole area. ArgumentError on a name
# that is neither, rather than running nothing and exiting 0.
features =
  if args.first == '--area' || args.first == 'area'
    args.shift
    name = args.shift or raise ArgumentError, '--area needs an area name'
    Features.in_area(name)
  else
    args.collect { |a| Features.feature(a) ; a }
  end

paths = features.flat_map { |n| tiers.flat_map { |t| Features.files(n, t) } }.uniq

if list
  paths.each do |p|
    need = Features.needs(p)
    puts need && need != 'nothing' ? "#{p}  (needs #{need})" : p
  end
  exit 0
end

# Say what is about to run and what it wants, before it runs. A lab test
# that omits itself prints one line in the middle of a suite's output,
# which is easy to miss; this is the line that explains it in advance.
wants = paths.filter_map { |p| Features.needs(p) }.uniq - ['nothing']
warn "run_feature: #{features.join(', ')}: #{paths.size} file(s)" \
     "#{wants.empty? ? '' : ", needing #{wants.sort.join(' and ')}"}"

paths.each do |p|
  if Features.never?(p)
    warn "run_feature: refusing #{p}: #{Features.never_reason(p)}"
    next
  end
  require "./#{p}"
end
