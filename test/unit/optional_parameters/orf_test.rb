#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

class Orf_cap_Test < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    ent1 =  Orf::Entry.new(1,1,[1,1],[2,1],[3,1])
    assert_equal('0001000103010102010301', ent1.to_shex)
    ent2 =  Orf::Entry.new(1,2,[1,1],[2,1],[3,1])
    assert_equal('0001000203010102010301', ent2.to_shex)
    ent3 = Orf::Entry.new(ent1.encode)
    assert_equal(ent1.encode, ent3.encode)
    orf = Orf.new
    orf.add(ent1)
    orf.add(ent2)
    assert_equal('0218031600010001030101020103010001000203010102010301', orf.to_shex)
    orf2 = Orf.new(orf.encode)
    assert_equal(orf.encode, orf2.encode)
  end

  # The capability inherited Capability's bare {:code=>3}, so every Entry
  # was lost, and a Hash fell through to the bare super and built a
  # capability with no entries at all: 26 octets became 4, in silence.
  # Capability.from_hash routes code 3 straight back here, so that route
  # answered an empty capability too.
  def test_the_capability_round_trips_with_its_entries
    orf = BGP::OPT_PARM::CAP::Orf.new
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 1, [1, 1], [2, 1], [3, 1]))
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 2, [1, 1], [2, 1], [3, 1]))
    assert_equal({ :code => 3,
                   :capability => { :entries => [
                     { :afi => 1, :safi => 1, :types => [[1, 1], [2, 1], [3, 1]] },
                     { :afi => 1, :safi => 2, :types => [[1, 1], [2, 1], [3, 1]] }] } },
                 orf.to_hash)
    assert_equal(orf.encode, BGP::OPT_PARM::CAP::Orf.new(orf.to_hash).encode)
    assert_equal(orf.encode,
                 BGP::OPT_PARM::Capability.from_hash(orf.to_hash).encode)
  end

  # One entry on its own. Its Hash branch was empty, so every field
  # stayed nil and encode raised, and it had no to_hash for anything to
  # read.
  def test_an_entry_round_trips
    e = BGP::OPT_PARM::CAP::Orf::Entry.new(1, 1, [64, 3])
    assert_equal({ :afi => 1, :safi => 1, :types => [[64, 3]] }, e.to_hash)
    assert_equal(e.encode, BGP::OPT_PARM::CAP::Orf::Entry.new(e.to_hash).encode)
  end

  # RFC 5291 section 5 Figure 3 gives the capability a Reserved octet and
  # never says what to do with it, so bgp4r keeps what arrived. It was
  # unpacked into a throwaway and written as 0, so a capability carrying
  # a non-zero one could not be sent again. **Section 4's "Reserved is a
  # 5-bit field. It is set to 0 on transmit and ignored on receipt" is a
  # different field**, in the ORF entry of a ROUTE-REFRESH, and is not a
  # rule about this octet.
  def test_the_reserved_octet_is_kept_and_only_then_hashed
    entry = '0001' + 'ff' + '01' + '01' + '4001'
    cap = '03' + format('%02x', entry.size / 2) + entry
    hex = '02' + format('%02x', cap.size / 2) + cap
    o = BGP::OPT_PARM::CAP::Orf.new([hex].pack('H*'))
    assert_equal(hex, o.to_shex, 'encode gives back the Reserved octet that arrived')
    assert_equal({ :afi => 1, :safi => 1, :types => [[64, 1]], :reserved => 0xff },
                 o.to_hash[:capability][:entries].first)
    assert_equal(o.encode, BGP::OPT_PARM::CAP::Orf.new(o.to_hash).encode)
    # An ordinary entry gains no key, so no caller sees a new shape.
    assert_equal({ :afi => 1, :safi => 1, :types => [[64, 3]] },
                 BGP::OPT_PARM::CAP::Orf::Entry.new(1, 1, [64, 3]).to_hash)
  end
end
