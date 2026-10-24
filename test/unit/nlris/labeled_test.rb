require "test/unit"

require "bgp/nlris/labeled"
require 'bgp/nlris/prefix'
require 'bgp/nlris/vpn'
require 'bgp/nlris/rd'

class TestBgpNlrisLabeled < Test::Unit::TestCase
  include BGP
  def test_new
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_s)
    assert_equal('Label Stack=100,101 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_s)
    assert_equal('Label Stack=100,101,102 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_s)
    assert_equal('200006410a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_shex)
    assert_equal('380006400006510a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_shex)
    assert_equal('500006400006500006610a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_shex)
    assert_equal({:prefix=>"10.0.0.0/8", :labels=>[100, 101, 102]}, Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_hash)
    labeled = Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102)
    assert_equal(labeled.to_shex, Labeled.new(labeled.to_hash).to_shex)
    assert_equal({:prefix=>"10.0.0.0/8", :labels=>[100, 101, 102]}, Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_hash)
    #FIXME: add labeled  and labeled vpn tests
  end
  def test_new_ntop
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/8', Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1).to_s)
    assert_equal('Label Stack=100,101 (bottom) 10.0.0.0/8', Labeled.new_ntop(['380006400006510a'].pack('H*'), 1, 1).to_s)
    assert_equal('Label Stack=100,101,102 (bottom) 10.0.0.0/8', Labeled.new_ntop(['500006400006500006610a'].pack('H*'), 1, 1).to_s)
    assert_equal('200006410a', Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1).to_shex)
    assert_equal('380006400006510a', Labeled.new_ntop(['380006400006510a'].pack('H*'), 1, 1).to_shex)
    assert_equal('500006400006500006610a', Labeled.new_ntop(['500006400006500006610a'].pack('H*'), 1, 1).to_shex)
    #FIXME: add labeled  and labeled vpn tests
  end
  def test_new_afi_1_safi_128_rd_0_0
    lb = Labeled.new_ntop(['580064b10000006405591311'].pack('H*'), 1, 128)
    assert_equal('580064b10000006405591311', lb.to_shex)
    assert_equal('Label Stack=1611 (bottom) RD=100:89723665, IPv4=0.0.0.0/0', lb.to_s)
    assert_equal({:rd=>[100, 89723665], :label=>1611}, lb.to_hash)
  end
  def test_new_ntop_path_id
    # RFC 7911 section 3: the 4 byte path id comes before the
    # RFC 8277 section 2 labeled NLRI (length, label, prefix).
    lb = Labeled.new_ntop(['200006410a'].pack('H*'), 1, 1, 7)
    assert_equal(7, lb.path_id)
    assert_equal('00000007200006410a', lb.to_shex)
  end
  def test_path_id_rd_only_vpn
    # Labeled VPN with RD 0:0 and no prefix: no path id, still encodes.
    lb = Labeled.new(Vpn.new(Rd.new), 100)
    assert_nil(lb.path_id)
    # 24 label bits + 64 RD bits = 88 (0x58), RFC 8277 section 2.
    assert_equal('58000641' + '00' * 8, lb.to_shex)
  end
  def test_path_id_does_not_hide_errors
    broken = Object.new
    def broken.path_id ; raise ArgumentError, 'broken' ; end
    lb = Labeled.new(Prefix.new('10.0.0.0/8'), 100)
    lb.instance_variable_set(:@prefix, broken)
    assert_raise(ArgumentError) { lb.path_id }
  end

end
