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
require 'json'
require 'stringio'
require 'bgp/bmp/station'

# docs/bmp.md section 5 against the station: bgp4r-bmp's JSON lines
# are a contract routescope reads, so every example there is a line the
# station writes for FRR's capture, and every key a line has is in its
# table. docs/design/bgp-operations.md 8b.
class TestBmpLinesDoc < Test::Unit::TestCase

  DOC = File.expand_path('../../../docs/bmp.md', __dir__)
  FIXTURE = File.expand_path('../../fixtures/bmp/frr-10.5.1.bin', __dir__)

  def setup
    @io = StringIO.new
    @station = BGP::Bmp::Station.new(:lines => @io, :clock => -> { Time.utc(2026, 11, 27, 10, 0, 0) })
    router = @station.open('192.0.2.1:40000')
    @station.feed(router, File.binread(FIXTURE))
    @routes = JSON.parse(JSON.generate(@station.routes('view' => 'loc_rib')))
    @station.close(router, 'end of stream')
    @lines = @io.string.lines.collect { |l| JSON.parse(l) }
  end

  def section
    text = File.read(DOC)
    text[/^## 5\. .*?(?=^## 6\. )/m] or flunk('docs/bmp.md has no section 5')
  end

  def blocks ; section.scan(/^```json\n(.*?)^```$/m).collect { |b,| JSON.parse(b) } ; end

  def test_each_example_is_a_line_the_station_writes
    lines = blocks.select { |b| b.key?('seq') }
    assert_equal(6, lines.size)
    lines.each { |b| assert_equal(@lines[b['seq'] - 1], b, "line #{b['seq']}") }
  end

  def test_the_routes_example
    assert_equal([@routes], blocks.select { |b| b.key?('routes') })
  end

  def test_every_key_is_in_the_table
    table = section[/^\| Key \| What \|\n.*?(?=\n\n)/m] or flunk('no key table')
    keys = table.scan(/^\| `(\w+)` \|/).flatten
    used = @lines.flat_map(&:keys).uniq
    assert_equal([], used - keys, 'a key a line has and the table does not')
    assert_equal(%w[seq time router sys_name type message findings hex reason], keys)
  end

  def test_every_type_is_named
    named = section[/^\| `type` \| (.*) \|$/, 1].scan(/`(\w+)`/).flatten
    codec = BGP::Bmp::Message::TYPES.values.collect { |k| k.new.hash_key.to_s } + %w[unknown]
    assert_equal([], codec + %w[undecoded connected closed] - named)
  end
end
