#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

class Open_Test < Test::Unit::TestCase
  include BGP
  include BGP::OPT_PARM::CAP
  def test_1
    s = "ffffffffffffffffffffffffffffffff001d0104006400c80a00000100"
    sbin = [s].pack('H*')
    assert_equal(Open, Message.factory(sbin).class)
    open =  Message.factory(sbin)
    assert_equal(s, open.to_shex)
    assert_equal(s, Open.new(4,100, 200, '10.0.0.1').to_shex)
    # assert_equal(s, Open.new(4,100, 200, '10.0.0.1', []).to_shex)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100), OPT_PARM::CAP::Route_refresh.new).to_shex[32..-1])
    open1 = Open.new(4,100, 200, '10.0.0.1', OPT_PARM::CAP::As4.new(100), OPT_PARM::CAP::Route_refresh.new)
    open2 = Open.new(open1.encode)
    assert_equal('00290104006400c80a0000010c020641040000006402020200', open2.to_shex[32..-1])
    open = Open.new(4,100, 200, '10.0.0.1')
    open << OPT_PARM::CAP::As4.new(100)
    open << OPT_PARM::CAP::Route_refresh.new
    assert_equal('00290104006400c80a0000010c020641040000006402020200', open.to_shex[32..-1])
    s = 'ffffffffffffffffffffffffffffffff002d0104626200b4513411091002060104000100800202800002020200'
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(s, open.to_shex)
    
    s = "ffff ffff ffff ffff ffff
    ffff ffff ffff 0038 0104 0023 00b4 1919
    1901 1b02 0601 0400 0100 0102 0280 0002
    0202 0002 0982 0700 0100 0101 8002".split.join
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(s, open.to_shex)
    
    s = "ffffffffffffffffffffffffffffffff003d0104006400b402020202200206010400010001020601040001000202028000020202000206410400000064"
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(4, open.version)
    assert_equal(100, open.local_as)
    assert_equal('2.2.2.2', open.bgp_id)
    assert_equal(180, open.holdtime)
    assert_equal(5, open.opt_parms.size)
    assert_equal(Mbgp, open.opt_parms[1].class)
    assert_equal(Route_refresh, open.opt_parms[2].class)
    assert_equal(Route_refresh, open.opt_parms[3].class)
    assert_equal(As4, open.opt_parms[4].class)
    
  end
  def test_2
    s = "ffffffffffffffffffffffffffffffff003d0104006400b402020202200206010400010001020601040001000202028000020202000206410400000064"
    open =  BGP::Message.factory([s].pack('H*'))
    assert_equal(5, open.to_hash[:capabilities].size )
    assert_equal(1, open.to_hash[:capabilities][0][:code])
    assert_equal({:safi=>1, :afi=>1}, open.to_hash[:capabilities][0][:capability])
    assert_equal(1, open.to_hash[:capabilities][1][:code])
    assert_equal({:safi=>2, :afi=>1}, open.to_hash[:capabilities][1][:capability])
    assert_equal(128, open.to_hash[:capabilities][2][:code])
    assert_nil(open.to_hash[:capabilities][2][:capability])
    assert_equal(2, open.to_hash[:capabilities][3][:code])
    assert_nil(open.to_hash[:capabilities][3][:capability])
    assert_equal(65, open.to_hash[:capabilities][4][:code])
    assert_equal(100,open.to_hash[:capabilities][4 ][:capability][:as])
  end
  def test_3
    s = "
    ffff ffff ffff ffff ffff ffff ffff ffff
    003f 0104 00c8 005a c0a8 7f01 2202 0601
    0400 0100 0102 0280 0002 0202 0002 0840
    0600 7800 0101 8002 0641 0400 0000 c8
    ".split.join
    open = BGP::Message.factory([s].pack('H*'))
    assert_equal s, open.to_shex
  end
  def test_4
    open = Open.new(4,100, 200, '10.0.0.1')
    open << OPT_PARM::CAP::As4.new(100)
    open << OPT_PARM::CAP::Route_refresh.new
    open << OPT_PARM::CAP::Add_path.new(:recv, 1, 1)
    assert open.find(As4)
    assert open.find(Route_refresh)
    assert open.find(Add_path)
  end
  def test_5
    open = Open.new(4,0xffff, 200, '10.0.0.1')
    assert_match(/my AS 65535/, open.to_s)
    open = Open.new(4,0x1ffff, 200, '10.0.0.1')
    assert_match(/my AS 23456/, open.to_s)
  end

  # An OPEN whose Capabilities parameters hold the given capability TLVs.
  # packed: one parameter with all of them, which RFC 5492 section 4
  # allows and GoBGP does. Otherwise one parameter each, which bgp4r
  # sends.
  def open_with(tlvs, packed: true)
    parms = if packed
      caps = tlvs.join
      '02' + format('%02x', caps.size / 2) + caps
    else
      tlvs.collect { |t| '02' + format('%02x', t.size / 2) + t }.join
    end
    body = '04' + 'fde9' + '00b4' + '0a1e0002' + format('%02x', parms.size / 2) + parms
    Open.new(['ff' * 16 + format('%04x', 19 + body.size / 2) + '01' + body].pack('H*').is_packed)
  end

  ROUTE_REFRESH = '0200'
  AS4_65001     = '4104' + '0000fde9'
  MBGP_IPV4     = '0104' + '00010001'

  # RFC 5492 section 4: one Capabilities optional parameter may carry
  # more than one capability. Reading only the first dropped the rest in
  # silence. Missing 4-octet AS that way left the 2-octet default on, and
  # the AS_PATH that follows is unparseable to a peer expecting 4 octets.
  def test_several_capabilities_in_one_optional_parameter
    open = open_with([ROUTE_REFRESH, AS4_65001, MBGP_IPV4])
    assert_equal 3, open.opt_parms.size
    assert open.find(OPT_PARM::CAP::Route_refresh), 'route refresh'
    assert open.find(OPT_PARM::CAP::As4), 'the 4-octet AS capability must not be lost'
    assert open.find(OPT_PARM::CAP::Mbgp), 'mbgp'
    assert_match(/4-octet AS number: 65001/, open.find(OPT_PARM::CAP::As4).to_s)
  end

  # Order within the parameter must not matter.
  def test_capability_order_in_one_parameter_does_not_matter
    [[AS4_65001, ROUTE_REFRESH], [ROUTE_REFRESH, AS4_65001]].each do |tlvs|
      open = open_with(tlvs)
      assert_equal 2, open.opt_parms.size, tlvs.inspect
      assert open.find(OPT_PARM::CAP::As4), tlvs.inspect
    end
  end

  # One capability per parameter, the shape bgp4r sends, still works.
  def test_one_capability_per_optional_parameter
    open = open_with([ROUTE_REFRESH, AS4_65001, MBGP_IPV4], :packed => false)
    assert_equal 3, open.opt_parms.size
    assert open.find(OPT_PARM::CAP::As4)
  end

  # A single capability in a single parameter is the old path.
  def test_one_capability_in_one_parameter
    open = open_with([AS4_65001])
    assert_equal 1, open.opt_parms.size
    assert_match(/4-octet AS number: 65001/, open.find(OPT_PARM::CAP::As4).to_s)
  end

  # An OPEN in the extended form of RFC 9072 section 2, Figure 1: one
  # Capabilities parameter carrying MBGP ipv4 unicast, with the two
  # octet Parameter Length of Figure 2 there.
  #
  #   ff..ff 0029 01                 header
  #   04 0064 00b4 0a000001          version, AS, holdtime, id
  #   ff                             Non-Ext OP Len.
  #   ff                             Non-Ext OP Type
  #   0009                           Extended Opt. Parm. Length
  #   02 0006 01 04 00010001         the parameter
  #
  # bgp4r read the one octet length inside it, so it took the 00 of 0006
  # for the whole parameter and then the 06 for the next parameter's
  # type, and raised "Optional parameter type '6' not implemented" on a
  # message any RFC 9072 speaker may send.
  EXTENDED_OPEN = 'ff' * 16 + '002901' +
                  '04' + '0064' + '00b4' + '0a000001' +
                  'ff' + 'ff' + '0009' +
                  '02' + '0006' + '01' + '04' + '00010001'

  def test_rfc9072_an_extended_open_from_the_wire
    open = nil
    assert_nothing_raised { open = BGP::Message.factory([EXTENDED_OPEN].pack('H*')) }
    assert_equal 1, open.opt_parms.size
    assert open.find(OPT_PARM::CAP::Mbgp), 'the capability must not be lost'
    assert_equal 1, open.find(OPT_PARM::CAP::Mbgp).afi
    assert open.extended?
    assert_equal EXTENDED_OPEN, open.to_shex, 'byte for byte'
  end

  # Section 2: "an implementation MUST accept an OPEN message that uses
  # the encoding of this specification" even when the Optional
  # Parameters are 255 octets or fewer, so the form a message arrived in
  # is the form it is written back in. Nine octets of parameters would
  # otherwise be downgraded and no longer match what came in.
  def test_rfc9072_the_extended_form_survives_a_short_parameter_list
    open = BGP::Message.factory([EXTENDED_OPEN].pack('H*'))
    assert_equal EXTENDED_OPEN, Open.new(open.encode).to_shex
    # And it can be asked for, since building is never validated.
    built = Open.new(4, 100, 180, '10.0.0.1', OPT_PARM::CAP::Mbgp.new(1,1))
    assert !built.extended?
    built.extended = true
    assert_equal EXTENDED_OPEN, built.to_shex
  end

  # Section 2 on the Non-Ext OP Len. octet: it "MUST NOT be set to 0; it
  # MUST be ignored on receipt once the use of the extended format is
  # determined positively", and of the Non-Ext OP Type octet after it:
  # "On receipt, a value of 255 for this field is the indication that
  # the extended format is in use." So that second octet alone decides.
  # bgp4r used to require 255 in both and read this as RFC 4271.
  def test_rfc9072_only_the_non_ext_op_type_octet_decides
    open = BGP::Message.factory([EXTENDED_OPEN.sub('ffff0009', '0cff0009')].pack('H*'))
    assert open.extended?
    assert open.find(OPT_PARM::CAP::Mbgp)
    # It is written back with the 255 section 2 recommends on
    # transmission, which is the one difference from what arrived.
    assert_equal EXTENDED_OPEN, open.to_shex
  end

  # The boundary. 255 octets of parameters stay in the RFC 4271 form,
  # with an Optional Parameters Length of 0xff that must not be taken
  # for the sentinel, because the octet after it is the parameter type.
  # One octet more and only the extended form can carry it.
  def test_rfc9072_the_255_octet_boundary
    [[251, false], [252, true]].each do |value_size, extended|
      open = Open.new(4, 100, 180, '10.0.0.1',
                      OPT_PARM::CAP::Unknown.new(100, 'a' * value_size))
      assert_equal extended, Open.new(open.encode).extended?, value_size.to_s
      assert_equal open.to_shex, Open.new(open.encode).to_shex, value_size.to_s
    end
    short = Open.new(4, 100, 180, '10.0.0.1', OPT_PARM::CAP::Unknown.new(100, 'a' * 251))
    assert_match(/0a000001ff02fd64fb6161/, short.to_shex, '255 octets, one octet length')
  end

  # A length that runs past the parameter stops the walk rather than
  # raising, so a peer cannot crash the parse with a short capability.
  def test_a_truncated_capability_does_not_raise
    open = nil
    assert_nothing_raised { open = open_with([ROUTE_REFRESH, '41ff' + '0000']) }
    assert open.find(OPT_PARM::CAP::Route_refresh), 'what came before it is kept'
    assert_nil open.find(OPT_PARM::CAP::As4)
  end

  # The whole message, for the two shapes below: version 4, AS 100,
  # holdtime 180, ID 10.0.0.1, then the Optional Parameters Length and the
  # parameters. The length is the real one unless declared says otherwise.
  def open_msg(parms_hex, declared = nil)
    body = '04' + '0064' + '00b4' + '0a000001' +
           format('%02x', declared || parms_hex.size / 2) + parms_hex
    'ff' * 16 + format('%04x', 19 + body.size / 2) + '01' + body
  end

  # RFC 4271 section 4.2 gives an optional parameter a 1 octet Parameter
  # Type and a 1 octet Parameter Length, so fewer octets than that are not
  # a parameter. Optional_parameter.factory read a Length that was not
  # there and raised NoMethodError on len+hdr, which took the parse of the
  # whole OPEN with it: a peer could stop bgp4r reading an OPEN by sending
  # one odd octet. They are the message's now, kept and written back.
  def test_octets_too_few_for_a_parameter_are_kept_as_the_messages_tail
    # One octet is the only leftover too short for the two octet header of
    # RFC 4271 section 4.2: two octets are a whole header, a Parameter
    # Type and a Parameter Length, however little follows them. The
    # extended form of RFC 9072 section 2 has a three octet header, so one
    # or two are short there, which the extended test below covers.
    { '41' => 1 }.each do |leftover, size|
      hex = open_msg(leftover)
      open = Message.factory([hex].pack('H*'))
      assert_equal(Open, open.class, leftover)
      assert_equal(0, open.opt_parms.size, leftover)
      assert_equal(leftover, open.tail.unpack('H*')[0], leftover)
      assert_equal(hex, open.to_shex, leftover)
      assert_equal(leftover, open.to_hash[:tail], leftover)
      assert_match(/#{size} octets? that is not a parameter: \[#{leftover}\]/, open.to_s, leftover)
    end
  end

  # A whole capability parameter and then a leftover: both come back.
  def test_a_parameter_and_a_leftover_both_come_back
    hex = open_msg('02020200' + '41')
    open = Message.factory([hex].pack('H*'))
    assert_equal(1, open.opt_parms.size)
    assert_equal(OPT_PARM::CAP::Route_refresh, open.opt_parms[0].class)
    assert_equal('41', open.tail.unpack('H*')[0])
    assert_equal(hex, open.to_shex)
  end

  # RFC 4271 section 4.2: the Optional Parameters Length "indicates the
  # total length of the Optional Parameters field in octets". parse reads
  # the parameters to the end of the message body, since the message
  # header length already bounds them, and never looked at this field, so
  # a peer that sent the wrong length had it quietly corrected by encode.
  def test_an_optional_parameters_length_that_disagrees_is_kept
    [0, 0x63, 0xff].each do |declared|
      hex = open_msg('02020200', declared)
      open = Message.factory([hex].pack('H*'))
      assert_equal(1, open.opt_parms.size, declared.to_s)
      assert_equal(declared, open.declared_opt_parm_len, declared.to_s)
      assert_equal(hex, open.to_shex, declared.to_s)
      assert_equal(declared, open.to_hash[:opt_parm_len], declared.to_s)
      assert_match(/Optional Parameters Length says #{declared}/, open.to_s, declared.to_s)
    end
  end

  # An ordinary OPEN has neither, so nothing about it changes: no tail, no
  # kept length, and the two keys stay out of its hash.
  def test_an_ordinary_open_has_no_tail_and_no_kept_length
    hex = open_msg('02020200')
    open = Message.factory([hex].pack('H*'))
    assert_nil(open.tail)
    assert_nil(open.declared_opt_parm_len)
    assert_equal(false, open.to_hash.key?(:tail))
    assert_equal(false, open.to_hash.key?(:opt_parm_len))
    assert_equal(hex, open.to_shex)
    # And one built from values writes its own length.
    built = Open.new(4, 100, 180, '10.0.0.1', OPT_PARM::CAP::Route_refresh.new)
    assert_nil(built.tail)
    assert_nil(built.declared_opt_parm_len)
    assert_equal(hex, built.to_shex)
  end

  # The same hole two octets wider in the RFC 9072 section 2 extended
  # form, where the Parameter Length is two octets, so a parameter header
  # is three.
  def test_the_extended_form_keeps_a_leftover_too
    # Non-Ext OP Len. 255, Non-Ext OP Type 255, then the 2 octet extended
    # length, then the parameters.
    body = '04' + '0064' + '00b4' + '0a000001' + 'ff' + 'ff' + '0005' +
           '02' + '0002' + '0200' + '41'
    hex = 'ff' * 16 + format('%04x', 19 + body.size / 2) + '01' + body
    open = Message.factory([hex].pack('H*'))
    assert_equal(true, open.extended?)
    assert_equal(1, open.opt_parms.size)
    assert_equal('41', open.tail.unpack('H*')[0])
    assert_equal(hex, open.to_shex)
    # Two octets are still short of a three octet header there.
    body2 = '04' + '0064' + '00b4' + '0a000001' + 'ff' + 'ff' + '0002' + '4142'
    hex2 = 'ff' * 16 + format('%04x', 19 + body2.size / 2) + '01' + body2
    open2 = Message.factory([hex2].pack('H*'))
    assert_equal(0, open2.opt_parms.size)
    assert_equal('4142', open2.tail.unpack('H*')[0])
    assert_equal(hex2, open2.to_shex)
  end

  # OPEN was the one message in bgp4r that built two ways where
  # Conventions asks for three, and a poor one to leave out: it is the
  # message a session starts with. Open.new of its own to_hash fell into
  # the positional branch, took the Hash as the version, and raised
  # IPAddr::AddressFamilyError on a bgp_id of nil.
  def test_builds_from_its_own_hash
    o = BGP::Open.new(4, 100, 180, '10.0.0.1',
                      BGP::OPT_PARM::CAP::Route_refresh.new,
                      BGP::OPT_PARM::CAP::As4.new(100),
                      BGP::OPT_PARM::CAP::Mbgp.ipv4_unicast)
    r = BGP::Open.new(o.to_hash)
    assert_equal(o.to_shex, r.to_shex, 'byte for byte')
    assert_equal(o.to_hash, r.to_hash)
  end

  # :capabilities is not only capabilities since #154: an
  # Optional_parameter::Unknown hashes into it keyed on :type where a
  # capability is keyed on :code, and the rebuild tells them apart.
  def test_builds_from_a_hash_carrying_an_unreadable_parameter
    o = BGP::Open.new(4, 100, 180, '10.0.0.1',
                      BGP::OPT_PARM::Optional_parameter::Unknown.new(1, 'abcd'))
    assert_equal(1, o.to_hash[:capabilities][0][:type])
    assert_equal(o.to_shex, BGP::Open.new(o.to_hash).to_shex)
  end

  # A captured OPEN whose Optional Parameters Length lies: it says 10
  # where 4 octets follow. The declared length rides in the hash, so the
  # capture still encodes byte for byte after a round trip through it.
  def test_a_hash_carries_a_declared_length_that_disagrees
    hex = 'ff' * 16 + '0021' + '01' + '04' + '0064' + '00b4' + '0a000001' +
          '0a' + '02020200'
    o = BGP::Open.new([hex].pack('H*').is_packed)
    assert_equal(10, o.to_hash[:opt_parm_len])
    assert_equal(hex, o.to_shex)
    assert_equal(hex, BGP::Open.new(o.to_hash).to_shex)
  end

  # RFC 9072 section 2: a message read in the extended form is written
  # back in it whatever its size, because section 2 says "an
  # implementation MUST accept an OPEN message that uses the encoding of
  # this specification". encode picks the form from the size otherwise,
  # so the hash has to say so or a small extended message loses it.
  def test_a_hash_carries_the_extended_form
    o = BGP::Open.new(4, 100, 180, '10.0.0.1', BGP::OPT_PARM::CAP::As4.new(100))
    o.extended = true
    assert_equal(true, o.to_hash[:extended])
    r = BGP::Open.new(o.to_hash)
    assert(r.extended?)
    assert_equal(o.to_shex, r.to_shex)
    # And an ordinary OPEN has no such key, so its hash is what it was.
    plain = BGP::Open.new(4, 100, 180, '10.0.0.1')
    assert(!plain.to_hash.key?(:extended))
  end

  # Two capabilities cannot be rebuilt from a hash, because their own
  # to_hash drops what they hold: Add_path hashes as {:code=>69} whatever
  # its RFC 7911 section 4 tuples, Graceful_restart as {:code=>64}
  # whatever its restart time and families. Refused by name rather than
  # built into something else, which is the one refusal Conventions
  # allows: an input the class cannot represent. Widening those two
  # to_hash forms changes the shape every caller sees, so it is a
  # recorded known issue and not decided here.
  def test_the_two_lossy_capabilities_are_refused_by_name
    [[BGP::OPT_PARM::CAP::Add_path.new(3, 1, 1), 'Add_path'],
     [BGP::OPT_PARM::CAP::Graceful_restart.new(60, [1, 1, 128]), 'Graceful_restart']].each do |cap, name|
      o = BGP::Open.new(4, 100, 180, '10.0.0.1', cap)
      e = assert_raise(ArgumentError) { BGP::Open.new(o.to_hash) }
      assert_match(/#{name}/, e.message)
      assert_match(/Known issues/, e.message)
    end
  end
end
