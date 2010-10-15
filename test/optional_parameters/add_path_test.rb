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
    assert_equal '020e450c000101010002800200020103', ap.to_shex
  end
end
