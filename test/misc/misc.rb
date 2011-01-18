require "test/unit"

require "bgp4r"

class TestBgp4r < Test::Unit::TestCase
  def test_1
    s = "ffffffffffffffffffffffffffffffff0084020000006d400101024002008004040000000040050400000064c00804282b4e87c010080002282b00007530800a080000000100000004800904513411d2800e310001800c0000000000000000513411d2007401c4f100000c8f00126cdcac14b0907801c53100000c8f00126cdcac14b092"
    msg = BGP::Message.factory([s].pack('H*'))
    assert_equal BGP::Update, msg.class
  end
  def test_2
  end
end