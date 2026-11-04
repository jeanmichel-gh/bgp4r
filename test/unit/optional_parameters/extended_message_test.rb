#--
# Copyright 2026 Jean-Michel Esnault.
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

require 'test/unit'
require 'bgp4r'

class Extended_message_cap_Test < Test::Unit::TestCase

  # RFC 8654 section 3: "a new BGP capability [RFC5492] defined with
  # Capability Code 6 and Capability Length 0". So the capability is
  # 06 00 behind the RFC 5492 section 4 optional parameter header.
  WIRE = '02020600'

  def test_the_capability_code_is_6_and_the_length_is_zero
    assert_equal 6, BGP::OPT_PARM::CAP_EXTENDED_MESSAGE
    cap = BGP::OPT_PARM::CAP::Extended_message.new
    assert_equal WIRE, cap.to_shex
    assert_equal 4, cap.encode.size
    assert_equal({:code=>6}, cap.to_hash)
  end

  def test_the_three_build_paths
    from_fields = BGP::OPT_PARM::CAP::Extended_message.new
    from_wire   = BGP::OPT_PARM::CAP::Extended_message.new([WIRE].pack('H*'))
    from_hash   = BGP::OPT_PARM::CAP::Extended_message.new(from_fields.to_hash)
    [from_fields, from_wire, from_hash].each do |cap|
      assert_equal WIRE, cap.to_shex
      assert_equal({:code=>6}, cap.to_hash)
    end
  end

  # It read as Capability::Unknown before, which is what FRR's OPEN
  # showed in the lab.
  def test_the_factory_reads_it_by_name
    cap = BGP::OPT_PARM::Capability.factory([WIRE].pack('H*'))
    assert_instance_of BGP::OPT_PARM::CAP::Extended_message, cap
    assert_equal WIRE, cap.to_shex
    assert_equal BGP::OPT_PARM::CAP::Extended_message,
                 BGP::OPT_PARM::Capability.from_hash(:code=>6).class
  end

  # draft-ietf-idr-dynamic-cap-19 section 3: a one octet code and a two
  # octet length, so the DYN_CAP class writes 06 0000.
  def test_the_dynamic_factory_reads_it
    cap = BGP::OPT_PARM::Capability.dynamic_factory(['060000'].pack('H*'))
    assert_instance_of BGP::OPT_PARM::DYN_CAP::Extended_message, cap
    assert_equal '060000', cap.to_shex
  end

  def test_to_s
    assert_equal "Option Capabilities Advertisement (2): [#{WIRE}]\n" +
                 '    BGP Extended Message (6), length: 2',
                 BGP::OPT_PARM::CAP::Extended_message.new.to_s
    assert_equal 'Extended message (6)',
                 BGP::OPT_PARM::CAP::Extended_message.new.to_s_brief
  end

  # RFC 8654 gives a value no meaning. One that arrives is kept and
  # written back, and builds again from the hash.
  def test_a_value_the_rfc_does_not_give_is_kept
    with_value = BGP::OPT_PARM::CAP::Extended_message.new(['02040602aabb'].pack('H*'))
    assert_equal '02040602aabb', with_value.to_shex
    assert_equal({:code=>6, :value=>'aabb'}, with_value.to_hash)
    assert_equal '02040602aabb',
                 BGP::OPT_PARM::CAP::Extended_message.new(with_value.to_hash).to_shex
    assert_match(/length: 4/, with_value.to_s)
    assert_equal Encoding::BINARY, BGP::OPT_PARM::CAP::Extended_message.new.value.encoding
  end

  def test_a_neighbor_names_it
    n = BGP::Neighbor.new(4, 100, 180, '10.0.0.1', '127.0.0.1', '127.0.0.2')
    n.capability :extended_message
    assert_equal WIRE, n.instance_eval { @opt_parms }.last.to_shex
  end

  def test_in_an_open_message
    open = BGP::Open.new(4, 100, 200, '10.0.0.1', BGP::OPT_PARM::CAP::Extended_message.new)
    back = BGP::Message.factory(open.encode)
    assert_equal open.to_shex, back.to_shex
    assert back.find(BGP::OPT_PARM::CAP::Extended_message),
           'the extended message capability reads back out of an OPEN'
  end
end
