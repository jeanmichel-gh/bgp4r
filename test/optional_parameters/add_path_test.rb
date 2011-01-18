require "test/unit"
require 'bgp4r'
require "bgp/optional_parameters/add_path"

class TestBgpOptionalParametersAddPath < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    ap = Add_path.new
    ap.add( :send, 1, 1)
    assert_equal '0206450400010101', ap.to_shex
    ap.add( :recv, 2, 128)
    assert_equal '020a45080001010100028002', ap.to_shex
    ap.add :send_and_receive, :ipv6, :unicast
    assert_equal '020e450c000101010002010300028002', ap.to_shex
  end
  def test_2
    ap = Add_path.new
    ap.add( :send, 1, 1)
    ap.add( :send, 2, 128)
    ap.add( :send_and_recv, 2, 128)
    assert ap.send? 1, 1
    assert ! ap.send?( 1, 2)
    assert ap.send?( 2, 128)
    assert ap.recv?( 2, 128)
  end
  def test_3
    ap1 = Add_path.new_array [[1, 1 ,2 ], [2, 10, 10]]
    ap2 = Add_path.new_array [[:send, :ipv4 ,:multicast], [:recv, 10, 10]]
    assert_equal ap1.to_shex, ap2.to_shex
  end
end
