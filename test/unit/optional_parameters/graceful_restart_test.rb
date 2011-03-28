require "test/unit"
require "bgp/optional_parameters/graceful_restart"
require 'bgp/common'

class TestBgpOptionalParametersGracefulCapRestart < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1

    gr = Graceful_restart.new  0, 120
    gr.add( 1, 1, 0x80)
    assert_equal '02084006007800010180', gr.to_shex
    gr2 = Graceful_restart.new(gr.encode)
    assert_equal gr.to_shex, gr2.to_shex
    gr.add( 1, 2, 0x80)
    assert_equal '020c400a00780001018000010280', gr.to_shex
    
    gr2 = Graceful_restart.new 0, 120
    gr2.add(:ipv4, :unicast, 1)
    assert_equal '02084006007800010101', gr2.to_shex
    gr2.add( :ipv4, :multicast, 1)
    assert_equal '020c400a00780001018000010280', gr.to_shex
    
  end
end
