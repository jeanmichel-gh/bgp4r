
#TODO: obselete ...
__END__

require "test/unit"

require "bgp/nlris/nlri"
require "bgp/nlris/inet"
require "bgp/nlris/vpn"
require "bgp/nlris/labeled"
require "bgp/nlris/rd"

class TestExtNlri < Test::Unit::TestCase
  include BGP
  def test_ext_nlri
    ext_nlri = Ext_Nlri.new(100, Nlri.new('10.0.0.0/8'))
    assert_equal '00000064080a', ext_nlri.to_shex
    assert_equal '00000064080a', Ext_Nlri.new_ntop(ext_nlri.encode).to_shex
    assert_equal '00000001200a0a0a0a', Ext_Nlri.new_ntop(['00000001200a0a0a0a'].pack('H*')).to_shex
  end
  def _test_ext_nlris
    ext_nlri = Ext_Nlri.new(100, Nlri.new('10.0.0.0/8','20.0.0.0/8'))
    assert_equal '00000064080a', ext_nlri.to_shex
    assert_equal '00000064080a', Ext_Nlri.new_ntop(ext_nlri.encode).to_shex
  end
  def test_ext_inet
    assert_equal '0000006410c0a8', Ext_Nlri.new(100, Inet_multicast.new('192.168.0.0/16')).to_shex
    assert_equal '00000064402011131100000000', Ext_Nlri.new(100, Inet_multicast.new('2011:1311::/64')).to_shex
  end
  def test_ext_labeled
    assert_equal '00000064600000100000200000310a0000', Ext_Nlri.new(100, Labeled.new(Prefix.new('10.0.0.1/24'),1,2,3)).to_shex
    assert_equal '00000064800006500006610000006400000064c0a8', Ext_Nlri.new(100, Labeled.new(Vpn.new('192.168.0.0/16', Rd.new(100,100)),101,102)).to_shex
    assert_equal '00000064b80006500006600006710000006400000064200900040005', Ext_Nlri.new(100, Labeled.new(Vpn.new('2009:4:5::1/48', Rd.new(100,100)),101,102,103)).to_shex
    assert_match(/ID=100, Label Stack=101/, Ext_Nlri.new(100, Labeled.new(Vpn.new('2009:4:5::1/48', Rd.new(100,100)),101,102,103)).to_s)
  end
end