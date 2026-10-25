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

require 'bgp/path_attributes/communities'
require 'bgp/path_attributes/path_attribute'

require 'test/unit'  
class Community_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal(0xFFFFFF01,Communities::Community.no_export.to_i)
    assert_equal(0xFFFFFF02,Communities::Community.no_advertise.to_i)
    assert_equal(0xFFFFFF03,Communities::Community.no_export_sub_confed.to_i)
    assert_equal(0xFFFFFF04,Communities::Community.no_peer.to_i)
    assert_equal(0xdeadbeef,Communities::Community.new(0xdeadbeef).to_i)
    assert_equal '5:1234', Communities::Community.new(Communities::Community.new('5:1234')).to_s
  end
end
class Well_known_community_Test < Test::Unit::TestCase
  include BGP
  # IANA "BGP Well-known Communities" registry.
  WKC = {
    :graceful_shutdown    => 'ffff0000', # RFC 8326 section 5
    :accept_own           => 'ffff0001', # RFC 7611 section 2
    :llgr_stale           => 'ffff0006', # RFC 9494 section 3.2
    :no_llgr              => 'ffff0007', # RFC 9494 section 3.3
    :blackhole            => 'ffff029a', # RFC 7999 section 5
    :no_export            => 'ffffff01', # RFC 1997
    :no_advertise         => 'ffffff02', # RFC 1997
    :no_export_sub_confed => 'ffffff03', # RFC 1997
    :no_peer              => 'ffffff04', # RFC 3765
  }
  def test_constants
    WKC.each do |name, hex|
      assert_equal hex.to_i(16), Communities::Community.const_get(name.to_s.upcase), name.to_s
    end
  end
  def test_symbol_and_class_method
    WKC.each do |name, hex|
      assert_equal hex, Communities::Community.new(name).encode.unpack1('H*'), name.to_s
      assert_equal hex, Communities::Community.send(name).encode.unpack1('H*'), name.to_s
      assert Communities::Community.respond_to?(name), name.to_s
    end
  end
  def test_string_name
    WKC.each do |name, hex|
      assert_equal hex, Communities::Community.new(name.to_s).encode.unpack1('H*'), name.to_s
      assert_equal hex, Communities::Community.new(name.to_s.upcase).encode.unpack1('H*'), name.to_s
    end
    assert_equal 0xFFFFFF03, Communities::Community.new('no-export-sub-confed').to_i
    assert_equal 0xFFFFFF03, Communities::Community.new('NO_EXPORT_SUBCONFED').to_i
    assert_equal 0xFFFFFF04, Communities::Community.new('NOPEER').to_i
  end
  def test_name
    WKC.each do |name, hex|
      assert_equal name, Communities::Community.new(hex.to_i(16)).name
    end
    assert_nil Communities::Community.new('100:1').name
  end
  def test_string_list
    names = WKC.keys.collect { |n| n.to_s }
    hex = 'c00824' + WKC.values.join
    assert_equal hex, Communities.new(*names).to_shex
    assert_equal hex, Communities.new(names).to_shex
    assert_equal hex, Communities.new(names.join(' ')).to_shex
    assert_equal hex, Communities.new(names.join(', ')).to_shex
    assert_equal hex, Communities.new_hash(:communities=>names).to_shex
    assert_equal hex, Path_attribute.new(:communities=>names).encode.unpack1('H*')
    assert_equal WKC.keys, Communities.new(names).names
  end
  def test_b14
    assert_equal "[OTcr]  (8) Communities: [c0080800640001ffffff0...] '100:1 65535:65281'",
                 Communities.new("100:1 no_export").to_s
    assert_equal 'c00808' + '00640001' + 'ffffff01',
                 Path_attribute.new(:communities=>["100:1","no_export"]).encode.unpack1('H*')
    assert Communities.new("100:1 no_export").has_no_export?
    assert_equal '100:1 100:2', Communities.new(" 100:1,100:2, ").communities
    assert_equal '100:1', Communities.new("100:1,").communities
  end
  def test_has_new_names
    c = Communities.new('graceful_shutdown blackhole')
    assert c.has_graceful_shutdown?
    assert c.has_blackhole?
    assert c.does_not_have_accept_own?
    assert ! c.has_no_llgr?
  end
  def test_garbage_raises
    ['garbage', 'no_exportx', '', 'abc:def', '1:2:3', '70000:1', '1:65536', '-1', '1.5', 'no export x'].each do |s|
      assert_raise(ArgumentError, s.inspect) { Communities::Community.new(s) }
    end
    assert_raise(ArgumentError) { Communities::Community.new(:garbage) }
    assert_raise(ArgumentError) { Communities.new("100:1 garbage") }
    assert_raise(ArgumentError) { Communities.new_hash(:communities=>["100:1", "garbage"]) }
    assert_raise(ArgumentError) { Communities::Community.new(0x1_0000_0000) }
    assert_raise(ArgumentError) { Communities::Community.new(nil) }
  end
  def test_any_32_bit_value
    # Reserved or unassigned values must stay possible.
    [0, 1, 0xFFFF, 0xFFFF0002, 0xFFFF00FF, 0xFFFFFF05, 0xFFFFFFFF, 0xdeadbeef].each do |v|
      assert_equal [v].pack('N'), Communities::Community.new(v).encode
      assert_equal v, Communities::Community.new(v.to_s).to_i
      assert_equal v, Communities::Community.new(format('0x%x', v)).to_i
      assert_equal v, Communities::Community.new(Communities::Community.new(v).to_s).to_i
    end
    assert_equal 0, Communities::Community.new('0:0').to_i
    assert_equal 0xFFFFFFFF, Communities::Community.new('65535:65535').to_i
  end
  def test_round_trip
    h = { :communities=> ['100:1', 'no_export', :blackhole, 'graceful_shutdown', 0xFFFF0002] }
    c = Communities.new_hash(h)
    assert_equal 'c00814' + '00640001ffffff01ffff029affff0000ffff0002', c.to_shex
    assert_equal({ :communities=> ['100:1', '65535:65281', '65535:666', '65535:0', '65535:2'] }, c.to_hash)
    assert_equal c.to_shex, Communities.new_hash(c.to_hash).to_shex
    assert_equal c.to_shex, Communities.new(c.encode).to_shex
    pa = Path_attribute.new(h)
    assert_equal pa.encode, Path_attribute.new(pa.to_hash).encode
    assert_equal pa.encode, Path_attribute.new(pa.encode).encode
  end
end
class Communities_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10", "113:20", "113:30", "113:40").communities)
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10 113:20 113:30 113:40").communities)
    assert_equal('113:10 113:20 113:30 113:40', Communities.new("113:10, 113:20, 113:30, 113:40").communities)
    assert_equal('113:20', Communities.new("113:20").communities)
    com = Communities.new
    com << '113:10'
    assert_equal('113:10', com.communities)
    com << '113:20'
    assert_equal('113:10 113:20', com.communities)
    com << '113:30'
    assert_equal('113:10 113:20 113:30', com.communities)
    assert_equal('c0080c0071000a007100140071001e', com.to_shex)
    com1 = Communities.new("145:30", "145:40", "145:50", "145:60")
    com2 = Communities.new("145:30,145:40,145:50,145:60")
    assert_equal(com1.to_shex, com2.to_shex)
    assert_equal('c008100091001e00910028009100320091003c',com1.to_shex)
    com3 = Communities.new(0x91001E, 0x910028, 0x910032, 0x91003c)
    assert_equal('c008100091001e00910028009100320091003c',com3.to_shex)
    assert_equal('145:30 145:40 145:50 145:60', com3.communities)
    assert_equal("[OTcr]  (8) Communities: [c008100091001e0091002...] '145:30 145:40 145:50 145:60'", com3.to_s)        
    assert_equal(com3.to_shex, Communities.new(com3.encode).to_shex)
    assert_equal({:communities=>["145:30", "145:40", "145:50", "145:60"]}, com1.to_hash)
    com4 = Communities.new_hash :communities=> ["145:30", "145:40", "145:50", "145:60", :no_export, :no_advertise]
    assert_equal('c008180091001e00910028009100320091003cffffff01ffffff02', com4.to_shex)
    com5 = Communities.new_hash(com4.to_hash)
    assert_equal(com4.to_shex, com5.to_shex)
  end
  def test_2
    com1 = Communities.new("145:60", "145:10", "145:30", "145:20")
    com2 = Communities.new("145:30,145:20,145:10,145:60")
    assert(com1 ==  com2)
    com1.sort
    assert_equal('145:60 145:10 145:30 145:20', com1.communities)
    com1.sort!
    assert_equal('145:10 145:20 145:30 145:60', com1.communities)
    com3 = Communities.new(com1)
    assert_equal(com1.encode, com3.encode)
  end
  def test_3
    assert   Communities.new("145:60 145:10 145:30 145:20").has_no? '1:1'
    assert ! Communities.new("145:60 145:10 145:30 145:20").has?(0xff)
    assert   Communities.new("145:60 145:10 145:30 145:20").has?(Communities::Community.new('145:60'))
    assert ! Communities.new("145:60 145:10 145:30 145:20").has?(Communities::Community.new(0xff))
    assert ! Communities.new("145:60 145:10 145:30 145:20").has_no?('145:60')
    assert   Communities.new("145:60 145:10 145:30 145:20").has?('145:60')
  end
  def test_4
    assert ! Communities.new("145:60 145:10").has_no_export?, "Not expexted to contain [no_export] community"
    assert   Communities.new("145:60 145:10").does_not_have_no_export?, "Not expexted to contain [no_export] community"
    assert ! Communities.new("145:60 145:10").has_no_advertise? , 'Not expected to contain [no_advertise] community'
    assert ! Communities.new("145:60 145:10").has_no_export_sub_confed?, 'Not expected to contain [no_export_sub_confed] community'
    assert   Communities.new("145:60 145:10").add(:no_export_sub_confed).has_no_export_sub_confed?, 'expected to contain [no_export_sub_confed]'
    assert   Communities.new("145:60 145:10").add(:no_export).has_no_export?, 'expected to contain [no_export]'
    assert   Communities.new("145:60 145:10").add(:no_advertise).has_no_advertise?, 'expected to contain [no_advertise]'
  end
end

#MiniTest::Unit.autorun