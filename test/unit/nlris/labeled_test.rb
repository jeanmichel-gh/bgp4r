require "test/unit"

require "bgp/nlris/labeled"
require 'bgp/nlris/prefix'

class TestBgpNlrisLabeled < Test::Unit::TestCase
  include BGP
  def test_new
    assert_equal('Label Stack=100 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_s)
    assert_equal('Label Stack=100,101 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_s)
    assert_equal('Label Stack=100,101,102 (bottom) 10.0.0.0/8',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_s)
    assert_equal('200006410a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100).to_shex)
    assert_equal('380006400006510a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101).to_shex)
    assert_equal('500006400006500006610a',  Labeled.new(Prefix.new('10.0.0.1/8'), 100,101,102).to_shex)
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
  def test_new_ntop_path_id
    #FIXME: add labeled  and labeled vpn tests
  end

end
