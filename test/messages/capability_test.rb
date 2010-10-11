#--
# Copyright 2010 Jean-Michel Esnault.
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


require "test/unit"
require "bgp/messages/capability"
require 'bgp4r'

class TestOptParmCapabilityEncode < Test::Unit::TestCase
  include BGP::OPT_PARM
  def test_encode_dynamic
    assert_equal '0206010400010001', CAP::Mbgp.new(1,1).to_shex
    assert_equal '01000400010001', DYN_CAP::Mbgp.new(1,1).to_shex
  end
end

class TestBgpMessagesCapabilityRevision < Test::Unit::TestCase
  include BGP::OPT_PARM
  def test_capability_revision
    assert_equal '01000400010001',  DYN_CAP::Mbgp.new(1,1).to_shex
    assert_equal '0206010400010001',  CAP::Mbgp.new(1,1).to_shex
    revision = BGP::Capability::Revision.new :unset, :set, :advertise, 10, DYN_CAP::Mbgp.new(1,1)
    assert_equal '400000000a01000400010001', revision.to_shex
    assert_equal '0x00000010  Advertise  Req (0x40)  MBGP IPv4, Unicast',revision.to_s
    rev = BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1))
    assert_equal '000000000a01000400010001', rev.to_shex
    rev = BGP::Capability::Revision.advertise_ack_request( 10, DYN_CAP::Mbgp.new(1,1))
    assert_equal '400000000a01000400010001', rev.to_shex
  end
  def test_capability_revision_o1
    r = BGP::Capability::Revision.new :unset, :unset, :advertise, 0, 'a cap'
    assert_equal 0, r.instance_eval { @o1 }
    r = BGP::Capability::Revision.new :set, :unset, :advertise, 0, 'a cap'
    assert_equal 0x80, r.instance_eval { @o1 }
    r = BGP::Capability::Revision.new :set, :set, :advertise, 0, 'a cap'
    assert_equal 0xc0, r.instance_eval { @o1 }
    r = BGP::Capability::Revision.new :unset, :set, :advertise, 0, 'a cap'
    assert_equal 0x40, r.instance_eval { @o1 }
  end
  def test_capability_revision_factory
    s = '400000000a01000400010001'
    sbin = [s].pack('H*')
    r = BGP::Capability::Revision.new(sbin)
    assert_equal s, r.to_shex
    assert_equal '', sbin
  end
end

class TestBgpMessagesCapability < Test::Unit::TestCase
  include BGP
  include BGP::OPT_PARM
  def test_capability_1
    cap_msg = BGP::Capability.new
    assert_equal 'ffffffffffffffffffffffffffffffff001306', cap_msg.to_shex
    cap_msg <<  BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1))
    assert_match /^(ff){16}001f06000000000a01000400010001/, cap_msg.to_shex
    cap_msg <<  BGP::Capability::Revision.advertise( 20, DYN_CAP::Mbgp.new(1,2))
    assert_match /^(ff){16}002b06\s*000000000a01000400010001\s*000000001401000400010002/, cap_msg.to_shex
  end
  def test_capability_2
    cap_msg = BGP::Capability.new(
      BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1)),
      BGP::Capability::Revision.advertise( 20, DYN_CAP::Mbgp.new(1,2))
    )
    assert_match /^(ff){16}002b06\s*000000000a01000400010001\s*000000001401000400010002/, cap_msg.to_shex
  end
  def test_capability_3

    s = 'Capability (6), length: 91
  Seqn        Action     Ack bits    Capability
  0x00000010  Advertise      (0x00)  MBGP IPv4, Unicast
  0x00000020  Advertise  Req (0x40)  MBGP IPv4, Unicast
  0x00000020  Advertise  Rsp (0x80)  MBGP IPv4, Unicast
  0x00000010  Withdraw       (0x01)  MBGP IPv4, Unicast
  0x00000020  Withdraw   Req (0x41)  MBGP IPv4, Unicast
  0x00000020  Withdraw   Rsp (0x81)  MBGP IPv4, Unicast'

    cap_msg = BGP::Capability.new(
    BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1)),
    BGP::Capability::Revision.advertise_ack_request( 20, DYN_CAP::Mbgp.new(1,1)),
    BGP::Capability::Revision.advertise_ack_response( 20, DYN_CAP::Mbgp.new(1,1)),
    BGP::Capability::Revision.remove( 10, DYN_CAP::Mbgp.new(1,1)),
    BGP::Capability::Revision.remove_ack_request( 20, DYN_CAP::Mbgp.new(1,1)),
    BGP::Capability::Revision.remove_ack_response( 20, DYN_CAP::Mbgp.new(1,1))
    )
    assert_equal s, cap_msg.to_s
  end
  def test_factory
    s = 'ffffffffffffffffffffffffffffffff002b06000000000a01000400010001000000001401000400010002'
    msg =  BGP::Message.factory([s].pack('H*'))
    assert_equal(BGP::Capability, msg.class)
    assert_equal s, msg.to_shex
  end
end
