#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

require 'bgp4r'
require 'bgp/orfs/prefix_orf'
require 'test/unit'
require 'stringio'
class Prefix_orf_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('000000000a0000080a', Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add(0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add_and_permit(10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', Prefix_entry.add_and_permit(10,'10.0.0.0/8').to_s)
    assert_equal('400000000a0000080a', Prefix_entry.new(1,0,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 permit', Prefix_entry.new(1,0,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('600000000a0000080a', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('600000000a0000080a', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_shex)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.new(1,1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove(1,10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove_and_deny(10,0,0,'10.0.0.0/8').to_s)
    assert_equal('seq  10 remove 10.0.0.0/8 deny', Prefix_entry.remove_and_deny(10,'10.0.0.0/8').to_s)
    assert_equal('000000000a0000080a', Prefix_entry.new( Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').encode).to_shex)
    assert_equal(Prefix_entry, Prefix_entry.new( Prefix_entry.new(0,0,10,0,0,'10.0.0.0/8').encode).class)    
  end
  
  def test_2

    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
        
    assert_equal(5,orf.entries.size)
    assert_equal('40002d000000000a0000080a000000001400000814000000001e0000081e000000002800000828000000003200000832', orf.to_shex)
    assert_equal(orf.encode, Prefix_orf.new(orf.encode).encode)
    assert_equal(orf.encode, Prefix_orf.new(orf).encode)
    
    orf1 = Prefix_orf.new
    orf1 << Prefix_entry.add_and_permit(10,'10.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(20,'20.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(30,'30.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(40,'40.0.0.0/8')
    orf1 << Prefix_entry.add_and_permit(50,'50.0.0.0/8')
    
    assert_equal(orf1.encode, orf.encode)

    orf2 = Prefix_orf.new([
      Prefix_entry.add_and_deny(1, '35.0.0.0/8'),
      Prefix_entry.add_and_permit(2,'2.2.2.2/32')])   
    assert_equal('400015200000000100000823000000000200002002020202', orf2.to_shex)
    orf2.cisco_prefix_entry_type
    assert_equal('820015200000000100000823000000000200002002020202', orf2.to_shex)

    assert_equal(orf2.encode, Prefix_orf.new(orf2.encode).encode)

  end
  
  def test_3
    orf = Prefix_orf.new([
      Prefix_entry.add_and_permit(10,'10.0.0.0/8'),
      Prefix_entry.add_and_permit(20,'20.0.0.0/8'),
      Prefix_entry.add_and_permit(30,'30.0.0.0/8'),
      Prefix_entry.add_and_permit(40,'40.0.0.0/8'),
      Prefix_entry.add_and_permit(50,'50.0.0.0/8'),
    ])
    assert_match(/BGP::Prefix_orf, 5 entries/, orf.to_s)
    assert_match(/\n  seq  10    add 10.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  20    add 20.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  30    add 30.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  40    add 40.0.0.0\/8 permit/, orf.to_s)
    assert_match(/\n  seq  50    add 50.0.0.0\/8 permit/, orf.to_s)
  end

  # RFC 5292 section 2: an Address Prefix ORF entry is
  # <Sequence, Match, Length, Prefix, Minlen, Maxlen>. The hash form names
  # those fields, and must build the same octets as the positional form.
  def test_prefix_entry_from_a_hash
    assert_equal('00000000000000080a', Prefix_entry.new(:prefix=>'10.0.0.0/8').to_shex)
    assert_equal('seq   0    add 10.0.0.0/8 permit', Prefix_entry.new(:prefix=>'10.0.0.0/8').to_s)
    h = {:action=>1, :match=>1, :seqn=>5, :min=>16, :max=>24, :prefix=>'172.16.0.0/12'}
    assert_equal('600000000510180cac10', Prefix_entry.new(h).to_shex)
    assert_equal(Prefix_entry.new(1,1,5,16,24,'172.16.0.0/12').encode, Prefix_entry.new(h).encode)
    assert_equal('seq   5 remove 172.16.0.0/12 ge 16 le 24 deny', Prefix_entry.new(h).to_s)
    # the symbols the setters accept name the same values
    sym = {:action=>:remove, :match=>:deny, :seqn=>5, :min=>16, :max=>24, :prefix=>'172.16.0.0/12'}
    assert_equal(Prefix_entry.new(h).encode, Prefix_entry.new(sym).encode)
    assert_equal('a0000000010000080a', Prefix_entry.new(:action=>:remove_all, :match=>:deny, :seqn=>1, :prefix=>'10.0.0.0/8').to_shex)
    # built from a hash, encoded, parsed back
    e = Prefix_entry.new(h)
    assert_equal(e.encode, Prefix_entry.new(e.encode.is_packed).encode)
  end

  # RFC 5292 section 2: Match is PERMIT (0) or DENY (1); the common part of
  # RFC 5291 section 4 carries Action in the top two bits.
  def test_prefix_entry_action_and_match_accessors
    e = Prefix_entry.new(:prefix=>'10.0.0.0/8')
    assert_equal(0, e.action_to_i)
    assert_equal(0, e.match_to_i)
    e.action, e.match = :remove, :deny
    assert_equal([1, 'remove', 1, 'deny'], [e.action_to_i, e.action_to_s, e.match_to_i, e.match_to_s])
    assert_equal('60000000000000080a', e.to_shex)
    e.action = 2
    assert_equal([2, 'remove all'], [e.action_to_i, e.action_to_s])
    e.match = 0
    assert_equal([0, 'permit'], [e.match_to_i, e.match_to_s])
    assert_equal('80000000000000080a', e.to_shex)
    e.action = 0
    assert_equal('00000000000000080a', e.to_shex)
  end

  # Match is one bit, so 2 cannot be represented and is refused rather than
  # silently truncated. The exception class is RuntimeError, not ArgumentError.
  def test_prefix_entry_match_refuses_a_value_it_cannot_represent
    assert_raise(RuntimeError) { Prefix_entry.new(:match=>2, :prefix=>'10.0.0.0/8') }
    assert_raise(RuntimeError) { Prefix_entry.new(:prefix=>'10.0.0.0/8').match = 2 }
  end

  # Action is two bits, so 3 arrives on the wire. It has no RFC 5291 meaning,
  # and the octets are kept and written back unchanged.
  def test_prefix_entry_keeps_an_action_it_does_not_know
    wire = ['c00000000a0000080a'].pack('H*')
    e = Prefix_entry.new(wire.is_packed)
    assert_equal(3, e.action_to_i)
    assert_equal('unknown action', e.action_to_s)
    assert_equal(0, e.match_to_i)
    assert_equal('c00000000a0000080a', e.to_shex)
    assert_equal('seq  10 unknown action 10.0.0.0/8 permit', e.to_s)
  end

  # The prefix of an entry is read in the address family of the ORF, so
  # _parse_ takes the AFI. IANA AFI 2 is IPv6.
  def test_prefix_entry_ipv6_prefix
    e = Prefix_entry.new(0, 0, 10, 0, 0, '2011:1::/32')
    assert_equal('000000000a00002020110001', e.to_shex)
    back = Prefix_entry.new(e.encode.is_packed, 2)
    assert_equal('seq  10    add 2011:1::/32 permit', back.to_s)
    assert_equal(e.encode, back.encode)
  end

  # RFC 5291 section 4: "When the Action component of an ORF entry specifies
  # REMOVE-ALL, the entry consists of only the common part." So the entry is
  # one octet, and the Match field means nothing in it.
  def test_remove_all_entry
    e = Prefix_entry.remove_all
    assert_equal(Prefix_entry::REMOVE_ALL, e.action_to_i)
    assert_equal('remove all', e.action_to_s)
    assert_equal('80', e.to_shex)
    assert_equal('remove all', e.to_s)
    assert_equal({:action=>2, :match=>0}, e.to_hash)
    # all three build paths
    assert_equal(e.encode, Prefix_entry.new(e.to_hash).encode)
    assert_equal(e.encode, Prefix_entry.new(e.encode.is_packed).encode)
    # one octet consumed, so the entries after it stay in step
    orf = Prefix_orf.new([Prefix_entry.remove_all,
                          Prefix_entry.add_and_permit(10, '10.0.0.0/8')])
    assert_equal('40000a' + '80' + '000000000a0000080a', orf.to_shex)
    back = Prefix_orf.new(orf.encode)
    assert_equal(2, back.entries.size)
    assert_equal(orf.encode, back.encode)
    assert_equal('remove all', back.entries[0].to_s)
    assert_equal('seq  10    add 10.0.0.0/8 permit', back.entries[1].to_s)
  end

  # Action is two bits, so 0 to 3 all fit the field and all encode. 3 has no
  # RFC 5291 meaning, which is not a reason to refuse it.
  def test_prefix_entry_action_accepts_any_value_the_field_holds
    assert_equal('c0000000000000080a', Prefix_entry.new(:action=>3, :prefix=>'10.0.0.0/8').to_shex)
    e = Prefix_entry.new(:prefix=>'10.0.0.0/8')
    e.action = 3
    assert_equal(3, e.action_to_i)
    assert_equal('c0000000000000080a', e.to_shex)
    # the three the RFC names, as a number and as a symbol
    assert_equal([0, 1, 2], [:add, :remove, :remove_all].collect { |s| e.action = s ; e.action_to_i })
    assert_equal([0, 1, 2], (0..2).collect { |i| e.action = i ; e.action_to_i })
    e.action = 3
    # what it cannot hold is refused, with a message, rather than ignored
    err = assert_raise(RuntimeError) { e.action = 4 }
    assert_equal('invalid action: 4', err.message)
    assert_raise(RuntimeError) { e.action = -1 }
    assert_raise(RuntimeError) { e.action = :drop }
    assert_raise(RuntimeError) { Prefix_entry.new(:action=>:drop, :prefix=>'10.0.0.0/8') }
    assert_equal(3, e.action_to_i)
    # match= says what it refused too
    err = assert_raise(RuntimeError) { e.match = 2 }
    assert_equal('invalid match: 2', err.message)
  end

  # The hash a caller passes to new is the caller's.
  def test_prefix_entry_does_not_write_into_the_hash_it_is_given
    h = {:prefix=>'10.0.0.0/8'}
    Prefix_entry.new(h)
    assert_equal({:prefix=>'10.0.0.0/8'}, h)
    assert_equal('00000000000000080a', Prefix_entry.new({:prefix=>'10.0.0.0/8'}.freeze).to_shex)
  end

  # RFC 5292 section 2: the fields of an entry, named, and back again.
  def test_prefix_entry_to_hash
    e = Prefix_entry.new(1, 1, 5, 16, 24, '172.16.0.0/12')
    assert_equal({:action=>1, :match=>1, :seqn=>5, :min=>16, :max=>24, :prefix=>'172.16.0.0/12'},
                 e.to_hash)
    assert_equal(e.encode, Prefix_entry.new(e.to_hash).encode)
    v6 = Prefix_entry.new(0, 0, 10, 0, 0, '2011:1::/32')
    assert_equal('2011:1::/32', v6.to_hash[:prefix])
    assert_equal(v6.encode, Prefix_entry.new(v6.to_hash).encode)
  end

  def test_prefix_orf_to_hash
    orf = Prefix_orf.new([Prefix_entry.add_and_permit(10, '10.0.0.0/8'),
                          Prefix_entry.remove_and_deny(20, '20.0.0.0/8')])
    h = orf.to_hash
    assert_equal(BGP::ORF::PREFIX, h[:type])
    assert_equal(2, h[:entries].size)
    assert_equal(orf.encode, Prefix_orf.new(h).encode)
    # the Cisco type octet round trips as well
    orf.cisco_prefix_entry_type
    assert_equal(130, orf.to_hash[:type])
    assert_equal(orf.encode, Prefix_orf.new(orf.to_hash).encode)
    # entries already built are taken as they are
    assert_equal(orf.encode, Prefix_orf.new(:type=>130, :entries=>orf.entries).encode)
    assert_equal('400000', Prefix_orf.new({}).to_shex)
  end

  # RFC 5292 section 2: a prefix is read in the address family of the ORF, and
  # the ORF gets it from the ROUTE-REFRESH message that carries it.
  def test_prefix_orf_parses_in_the_afi_it_is_given
    orf = Prefix_orf.new([Prefix_entry.new(0, 0, 10, 0, 0, '2011:1::/32')])
    assert_equal('40000c000000000a00002020110001', orf.to_shex)
    back = Prefix_orf.new(orf.encode, 2)
    assert_equal('seq  10    add 2011:1::/32 permit', back.entries[0].to_s)
    assert_equal(orf.encode, back.encode)
    assert_equal(orf.encode, Prefix_orf.new(back, 2).encode)
    assert_equal('2011:1::/32', Prefix_orf.new(back, 2).entries[0].to_hash[:prefix])
  end

  def test_prefix_orf_add_refuses_anything_but_a_prefix_entry
    assert_raise(ArgumentError) { Prefix_orf.new << 'not an entry' }
    assert_raise(ArgumentError) { Prefix_orf.new.add(Prefix_orf.new) }
  end

  def test_invalid_argument_raises_quietly
    out, $stdout = $stdout, StringIO.new
    assert_raise(ArgumentError) { Prefix_entry.new(1, 2) }
    assert_equal('', $stdout.string)
  ensure
    $stdout = out
  end

end
