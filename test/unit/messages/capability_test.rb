#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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
  def test_adding_dyn_cap_to_message
    cap_msg = BGP::Capability.new
    assert_equal('ffffffffffffffffffffffffffffffff001306', cap_msg.to_shex)
    cap_msg <<  BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1))
    assert_match(/^(ff){16}001f06000000000a01000400010001/, cap_msg.to_shex)
    cap_msg <<  BGP::Capability::Revision.advertise( 20, DYN_CAP::Mbgp.new(1,2))
    assert_match(/^(ff){16}002b06\s*000000000a01000400010001\s*000000001401000400010002/, cap_msg.to_shex)
  end
  def test_new_cap_message_with_dyn_caps
    cap_msg = BGP::Capability.new(
      BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.new(1,1)),
      BGP::Capability::Revision.advertise( 20, DYN_CAP::Mbgp.new(1,2))
    )
    assert_match(/^(ff){16}002b06\s*000000000a01000400010001\s*000000001401000400010002/, cap_msg.to_shex)
  end
  def test_new_cap_message_with_dyn_caps_verbose
    cap_msg = BGP::Capability.new(
      BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.advertise( 20, DYN_CAP::Mbgp.ipv4_multicast)
    )
    assert_match(/^(ff){16}002b06\s*000000000a01000400010001\s*000000001401000400010002/, cap_msg.to_shex)
  end
  def test_capability_advertise_remove_dyn_caps

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
    
    cap_msg2 = BGP::Capability.new(
      BGP::Capability::Revision.advertise( 10, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.advertise_ack_request( 20, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.advertise_ack_response( 20, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.remove( 10, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.remove_ack_request( 20, DYN_CAP::Mbgp.ipv4_unicast),
      BGP::Capability::Revision.remove_ack_response( 20, DYN_CAP::Mbgp.ipv4_unicast)
    )
    assert_equal(cap_msg.to_shex, cap_msg2.to_shex)
  end
  def test_factory
    s = 'ffffffffffffffffffffffffffffffff002b06000000000a01000400010001000000001401000400010002'
    msg =  BGP::Message.factory([s].pack('H*'))
    assert_equal(BGP::Capability, msg.class)
    assert_equal s, msg.to_shex
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: a Dynamic Capability
  # message can carry a capability code bgp4r does not implement, and
  # the message still has to come back byte for byte. Reading one used
  # to raise TypeError, because the fallback capability read the two
  # octet optional parameter header where the message has a one octet
  # code and a two octet length.
  def test_message_keeps_an_unimplemented_capability
    s = 'ffffffffffffffffffffffffffffffff002006000000000a64000576616c7565'
    msg = BGP::Message.factory([s].pack('H*'))
    assert_equal(BGP::Capability, msg.class)
    assert_equal s, msg.to_shex
    assert_equal 'Capability (6), length: 32
  Seqn        Action     Ack bits    Capability
  0x00000010  Advertise      (0x00)  Unknown Capability 100 [76616c7565]', msg.to_s
    # The same message built from the capability object.
    built = BGP::Capability.new(
      BGP::Capability::Revision.advertise(10, DYN_CAP::Unknown.new(100, 'value')))
    assert_equal s, built.to_shex
  end
end

# A Dynamic Capability message carries one capability per revision
# (draft-ietf-idr-dynamic-cap-19, 16 February 2026, section 3), and
# Capability::Revision#to_s prints it with to_s_brief. That method was
# defined on CAP::Mbgp and CAP::Unknown and nowhere else, so printing a
# message that carried any other capability raised NoMethodError.
#
# The capability classes are found from the code rather than listed, so
# a capability added later is covered too: a class with no sample here
# fails these tests instead of going untested.
class TestBgpMessagesCapabilityBrief < Test::Unit::TestCase
  include BGP::OPT_PARM

  # Wire bytes of each sample, measured before to_s_brief was added.
  # This is a display fix, so none of them may move, and the set of
  # keys is the set of capability classes the library can carry.
  WIRE = {
    'BGP::OPT_PARM::CAP::Add_path'              => '0206450400010102',
    'BGP::OPT_PARM::CAP::As4'                   => '0206410400000064',
    'BGP::OPT_PARM::CAP::Dynamic'               => '02024300',
    # RFC 7313 section 3.1: capability code 70, with a zero length.
    'BGP::OPT_PARM::CAP::Enhanced_route_refresh' => '02024600',
    'BGP::OPT_PARM::CAP::Extended_nexthop'      => '02080506000100010002',
    'BGP::OPT_PARM::CAP::Graceful_restart'      => '020440020078',
    'BGP::OPT_PARM::CAP::Mbgp'                  => '0206010400010001',
    'BGP::OPT_PARM::CAP::Orf'                   => '0209030700010001014001',
    'BGP::OPT_PARM::CAP::Route_refresh'         => '02020200',
    'BGP::OPT_PARM::CAP::Unknown'               => '0207640576616c7565',
    'BGP::OPT_PARM::Capability::Unknown'        => '0207640576616c7565',
    'BGP::OPT_PARM::DYN_CAP::Add_path'          => '45000400010102',
    'BGP::OPT_PARM::DYN_CAP::As4'               => '41000400000064',
    'BGP::OPT_PARM::DYN_CAP::Dynamic'           => '430000',
    'BGP::OPT_PARM::DYN_CAP::Enhanced_route_refresh' => '460000',
    'BGP::OPT_PARM::DYN_CAP::Extended_nexthop'  => '050006000100010002',
    'BGP::OPT_PARM::DYN_CAP::Graceful_restart'  => '4000020078',
    'BGP::OPT_PARM::DYN_CAP::Mbgp'              => '01000400010001',
    'BGP::OPT_PARM::DYN_CAP::Orf'               => '03000700010001014001',
    'BGP::OPT_PARM::DYN_CAP::Route_refresh'     => '020000',
    'BGP::OPT_PARM::DYN_CAP::Unknown'           => '64000576616c7565',
  }

  # Every subclass of Capability, however deep. The DYN_CAP classes are
  # generated from the CAP ones in capabilities.rb, so they are here
  # without being named.
  def capability_classes
    found, queue = [], [BGP::OPT_PARM::Capability]
    until queue.empty?
      queue.shift.subclasses.each { |kl| found << kl ; queue << kl }
    end
    found
  end

  # One sample of each capability. The case is on the class name
  # without its namespace, so a CAP class and the DYN_CAP class
  # generated from it share an entry.
  def sample_of(kl)
    case kl.name.split('::').last
    when 'Mbgp'             then kl.new(1, 1)
    when 'As4'              then kl.new(100)
    when 'Route_refresh'    then kl.new
    when 'Dynamic'          then kl.new
    when 'Enhanced_route_refresh' then kl.new
    when 'Graceful_restart' then kl.new(0, 120)
    when 'Add_path'         then kl.new(:send, 1, 1)
    when 'Extended_nexthop' then kl.new(1, 1, 2)
    when 'Orf'              then kl.new.tap { |o| o.add(kl::Entry.new(1, 1, [64, 1])) }
    when 'Unknown'
      # Capability::Unknown reads the optional parameter header, so it
      # only builds from wire bytes. CAP::Unknown takes field values.
      if kl == BGP::OPT_PARM::Capability::Unknown
        kl.new(['0207640576616c7565'].pack('H*'))
      else
        kl.new(100, 'value')
      end
    else
      flunk "no sample of #{kl}: add one, so that its to_s_brief is tested"
    end
  end

  def test_the_capability_classes_are_found_from_the_code
    assert_equal WIRE.keys.sort, capability_classes.collect { |kl| kl.name }.sort,
                 'a capability class was added or removed: give it a sample and its wire bytes'
  end

  def test_every_capability_class_prints_in_a_capability_message
    capability_classes.each do |kl|
      cap, brief, out = sample_of(kl), nil, nil
      assert_nothing_raised("#{kl} has no brief form") { brief = cap.to_s_brief }
      assert_equal 1, brief.lines.size, "#{kl}: the brief form is one line"
      assert_not_equal '', brief.strip, "#{kl}: the brief form says nothing"
      msg = BGP::Capability.new(BGP::Capability::Revision.advertise(10, cap))
      assert_nothing_raised("#{kl} does not print") { out = msg.to_s }
      assert_match(/^  0x00000010  Advertise      \(0x00\)  #{Regexp.escape(brief)}$/,
                   out, "#{kl}: the message does not show the brief form")
    end
  end

  def test_printing_moves_no_wire_bytes
    capability_classes.each do |kl|
      cap = sample_of(kl)
      assert_equal WIRE[kl.name], cap.to_shex, "#{kl}: wire bytes"
      cap.to_s_brief
      cap.to_s
      BGP::Capability.new(BGP::Capability::Revision.advertise(10, cap)).to_s
      assert_equal WIRE[kl.name], cap.to_shex, "#{kl}: printing moved the wire bytes"
    end
  end
end
