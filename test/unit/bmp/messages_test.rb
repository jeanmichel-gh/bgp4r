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
require 'bgp/bmp'

# Each message of RFC 7854 section 4 against its diagram, octet by
# octet, built the four ways, and FRR 10.5.1's bgpd_bmp read and written
# back byte for byte. docs/design/bgp-operations.md 8a.
class TestBmpMessages < Test::Unit::TestCase
  include BGP::Bmp

  def hex(s) ; [s.delete(" \n")].pack('H*') ; end

  # Section 4.2: a Global Instance Peer, 192.0.2.2, AS 65002, its BGP ID,
  # 1700000000 s and 5 us.
  PEER = '00 00 0000000000000000 000000000000000000000000c0000202 0000fdea c0000202 6553f100 00000005'
  def peer ; Per_peer.new('192.0.2.2', 65_002, '192.0.2.2', 0, 0, '0' * 16, 1_700_000_000, 5) ; end

  def open(as, id) ; BGP::Open.new(4, as, 180, id) ; end
  OPEN1 = 'ffffffffffffffffffffffffffffffff 001d 01 04 fde9 00b4 c0000201 00'
  OPEN2 = 'ffffffffffffffffffffffffffffffff 001d 01 04 fdea 00b4 c0000202 00'
  MARKER = 'ffffffffffffffffffffffffffffffff'

  # Each message, its octets written by hand from its diagram: version
  # 3, the Message Length, the Message Type, then the body.
  def cases
    {
      # 4.3 and 4.4: sysDescr "r", sysName "n".
      'Initiation' => [Initiation.new({ :type => 1, :string => 'r' }, { :type => 2, :string => 'n' }),
                       '03 00000010 04  0001 0001 72  0002 0001 6e'],
      # 4.5: Reason 0, and a String.
      'Termination' => [Termination.new({ :type => 1, :code => 0 }, { :type => 0, :string => 'x' }),
                        '03 00000011 05  0001 0002 0000  0000 0001 78'],
      # 4.6 and 5: an End-of-RIB, the empty UPDATE of RFC 4724 section 2.
      'Route_monitoring' => [Route_monitoring.new(peer, BGP::Update.new),
                             "03 00000047 00 #{PEER} #{MARKER} 0017 02 0000 0000"],
      # 4.8: a counter, a gauge and a per-AFI/SAFI gauge.
      'Stats_report' => [Stats_report.new(peer, [1, 7], [7, 9], [9, 5, 1, 1]),
                         "03 00000057 01 #{PEER} 00000003  0001 0004 00000007  0007 0008 0000000000000009 " \
                         '0009 000b 0001 01 0000000000000005'],
      # 4.9, reason 4: no data.
      'Peer_down' => [Peer_down.new(peer, 4), "03 00000031 02 #{PEER} 04"],
      # 4.10: the local address and ports, both OPENs, a String.
      'Peer_up' => [Peer_up.new(peer, '192.0.2.1', 179, 50_000, open(65_001, '192.0.2.1'), open(65_002, '192.0.2.2'),
                                { :type => 0, :string => 'hi' }),
                    "03 00000084 03 #{PEER} 000000000000000000000000c0000201 00b3 c350 #{OPEN1} #{OPEN2} 0000 0002 6869"],
      # 4.7: Information code 1, Messages Lost, then a KEEPALIVE last.
      'Route_mirroring' => [Route_mirroring.new(peer, { :type => 1, :code => 1 }, BGP::Keepalive.new),
                            "03 0000004d 06 #{PEER} 0001 0002 0001  0000 0013 #{MARKER} 0013 04"],
      # 4.1: a type it does not know, kept whole.
      'Unknown' => [Unknown.new(99, "\xab\xcd".b), '03 00000008 63 abcd'],
    }
  end

  def test_each_message_against_its_diagram
    cases.each do |name, (msg, octets)|
      assert_equal(hex(octets).unpack1('H*'), msg.to_shex, name)
      wire = Message.factory(hex(octets))
      assert_equal(name, wire.class.name.split('::').last)
      assert_equal(hex(octets), wire.encode, "#{name} from the wire")
      assert_equal(hex(octets), wire.class.new(wire).encode, "#{name} from another")
      assert_equal(hex(octets), wire.class.new(wire.to_hash).encode, "#{name} from its hash")
      assert_equal(3, wire.version)
    end
  end

  def test_what_each_reads
    m = cases
    i = Message.factory(m['Initiation'].first.encode)
    assert_equal(['r', 'n', nil], [i.sys_descr, i.sys_name, i.string(0)])
    assert_equal(0, Message.factory(m['Termination'].first.encode).reason)
    rm = Message.factory(m['Route_monitoring'].first.encode)
    assert_equal([true, false, false], [rm.end_of_rib?, rm.peer.post_policy?, rm.peer.ipv6?])
    assert_equal({ :peer_type => 0, :flags => 0, :distinguisher => '0' * 16, :address => '192.0.2.2', :asn => 65_002,
                   :bgp_id => '192.0.2.2', :seconds => 1_700_000_000, :microseconds => 5 }, rm.peer.to_hash)
    sr = Message.factory(m['Stats_report'].first.encode)
    assert_equal([{ :type => 1, :value => 7 }, { :type => 7, :value => 9 }, { :type => 9, :value => 5, :afi => 1, :safi => 1 }],
                 sr.stats.collect(&:to_hash))
    up = Message.factory(m['Peer_up'].first.encode)
    assert_equal(['192.0.2.1', 179, 50_000, 65_001, 65_002], [up.local_address, up.local_port, up.remote_port,
                                                              up.sent_open.local_as, up.received_open.local_as])
    assert_equal(BGP::Keepalive, Message.factory(m['Route_mirroring'].first.encode).message.class)
    assert_equal([99, "\xab\xcd".b], [Message.factory(m['Unknown'].first.encode).type, Message.factory(m['Unknown'].first.encode).body])
  end

  # Section 4.9: each reason's data, and RFC 9069 section 5.3's TLVs.
  def test_peer_down_reasons
    { 1 => [BGP::Notification.new(6, 2), "01 #{MARKER} 0015 03 06 02"],
      2 => [3, '02 0003'],
      3 => [BGP::Notification.new(4, 0), "03 #{MARKER} 0015 03 04 00"],
      5 => [nil, '05'],
      6 => [[{ :type => 3, :string => 'global' }], '06 0003 0006 676c6f62616c'] }.each do |reason, (data, tail)|
      msg = Peer_down.new(peer, reason, data)
      octets = hex(PEER + tail)
      assert_equal(octets.unpack1('H*'), msg.encode.byteslice(HEADER..).unpack1('H*'), "reason #{reason}")
      back = Message.factory(msg.encode)
      assert_equal(msg.encode, back.class.new(back.to_hash).encode, "reason #{reason} from its hash")
    end
    pd = Message.factory(Peer_down.new(peer, 1, BGP::Notification.new(6, 2)).encode)
    assert_equal([6, 2], pd.notification.to_hash.values_at(:code, :subcode))
    assert_equal(3, Message.factory(Peer_down.new(peer, 2, 3).encode).fsm_event)
  end

  # Section 4.2's V and A flags, and RFC 9069's Loc-RIB peer with F.
  def test_the_per_peer_header
    v6 = Per_peer.new('2001:db8::2', 65_002, '192.0.2.2')
    assert_equal([FLAG_V, true], [v6.flags, v6.ipv6?])
    assert_equal('2001:db8::2', Per_peer.new(v6.encode).address)
    assert_equal('20010db8000000000000000000000002', v6.encode.byteslice(10, 16).unpack1('H*'))
    loc = Per_peer.new('0.0.0.0', 65_002, '10.0.0.2', LOC_RIB, FLAG_F)
    assert_equal([true, true, false, false], [loc.loc_rib?, loc.filtered?, loc.post_policy?, loc.ipv6?])
    assert_equal([false, true], [Per_peer.new('0.0.0.0', 1, '1.1.1.1', LOC_RIB, 0).filtered?, Per_peer.new(loc.encode).filtered?])
    post = Per_peer.new('192.0.2.2', 65_002, '192.0.2.2', 1, FLAG_L | FLAG_A, '0000fdea00000001')
    assert_equal([true, true, '0000fdea00000001'], [post.post_policy?, post.as2?, Per_peer.new(post.encode).distinguisher])
    assert_match(/RD Instance Peer 192.0.2.2 AS 65002 ID 192.0.2.2, post-policy, 2-octet AS/, post.to_s)
    assert_match(/Loc-RIB Instance Peer .*filtered/, loc.to_s)
  end

  # The flags of one peer type mean nothing for another: L and A are
  # types 0 to 2's, F type 3's (RFC 9069 section 4.2).
  def test_flags_by_peer_type
    loc = Per_peer.new('0.0.0.0', 65_002, '10.0.0.2', LOC_RIB, FLAG_L | FLAG_A)
    assert_equal([false, false, false], [loc.post_policy?, loc.as2?, loc.ipv6?], 'FRR sends L on a Loc-RIB peer')
    assert_equal(false, Per_peer.new('2001:db8::2', 1, '1.1.1.1').filtered?, 'V is not F')
  end

  # What a few readers answer that the diagrams do not show.
  def test_edges
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(1), BGP::Next_hop.new('192.0.2.2'))
    assert_equal(false, Route_monitoring.new(peer, BGP::Update.new(pa, BGP::Nlri.new('10.0.0.0/8'))).end_of_rib?)
    t = Message.factory(Termination.new({ :type => 1, :hex => '00' }).encode)
    assert_equal([[{ :type => 1, :hex => '00' }], nil], [t.to_hash[:termination][:information], t.reason],
                 'a Reason of one octet is not a code')
    junk = Route_mirroring.new(peer, { :type => 0, :hex => 'ffff' })
    assert_nil(Message.factory(junk.encode).message, 'an errored message reads as nil')
    o = BGP::Open.new(4, 65_002, 180, '10.0.0.2')
    loc = Peer_up.new(Per_peer.new('0.0.0.0', 65_002, '10.0.0.2', LOC_RIB), '0.0.0.0', 0, 0, o)
    assert_equal(o.encode, loc.received_open.encode, 'RFC 9069 section 5.2: the received OPEN repeats the sent one')
    v6 = Peer_up.new(Per_peer.new('2001:db8::2', 65_002, '192.0.2.2'), '2001:db8::1', 179, 1, o, o)
    assert_equal('2001:db8::1', Message.factory(v6.encode).local_address)
    sr = Stats_report.new(peer, [1, 7]).encode
    sr = sr.byteslice(0, 51) + "\x02".b + sr.byteslice(52..)
    assert_equal(1, Message.factory(sr).stats.size, 'a Stats Count above the stats there')
    # A Route Monitoring of a peer whose session has 2-octet ASes, read
    # with that session and no A flag.
    two = BGP::Update.new(pa, BGP::Nlri.new('10.0.0.0/8'))
    octets = Route_monitoring.new(Per_peer.new('192.0.2.2', 65_002, '192.0.2.2', 0, FLAG_A), two).encode
    octets.setbyte(HEADER + 1, 0)
    assert_equal([1], Message.factory(octets, BGP::Update::Info.new(false)).update.path_attribute[BGP::As_path].segments.first.as)
  end

  # Section 4.2's A flag: the UPDATE's AS_PATH in two octets.
  def test_the_a_flag_reads_two_octet_ases
    pa = BGP::Path_attribute.new(BGP::Origin.new(0), BGP::As_path.new(65_002, 65_010), BGP::Next_hop.new('192.0.2.2'))
    update = BGP::Update.new(pa, BGP::Nlri.new('10.0.0.0/8'))
    two = Per_peer.new('192.0.2.2', 65_002, '192.0.2.2', 0, FLAG_A)
    msg = Route_monitoring.new(two, update)
    assert(msg.encode.include?(hex('4002 06 02 02 fdea fdf2')), 'the AS_PATH in two octets each')
    back = Message.factory(msg.encode)
    assert_equal([65_002, 65_010], back.update.path_attribute[BGP::As_path].segments.first.as)
    four = Route_monitoring.new(peer, update)
    assert(four.encode.include?(hex('4002 0a 02 02 0000fdea 0000fdf2')), 'four octets each without it')
  end

  # Section 4.8: "MUST ignore unrecognized stat types ... and likewise
  # MUST ignore unexpected data": both are kept as hex.
  def test_stats_kept_when_not_understood
    sr = Stats_report.new(peer, { :type => 65_531, :hex => '00000000' }, { :type => 7, :hex => 'ff' })
    back = Message.factory(sr.encode)
    assert_equal([{ :type => 65_531, :hex => '00000000' }, { :type => 7, :hex => 'ff' }], back.stats.collect(&:to_hash))
    assert_equal(sr.encode, back.class.new(back.to_hash).encode)
  end

  def test_messages_off_a_stream
    a = cases['Initiation'].first.encode
    b = cases['Peer_down'].first.encode
    list, rest = BGP::Bmp.messages(a + b + b.byteslice(0, 10))
    assert_equal([[Initiation, Peer_down], b.byteslice(0, 10)], [list.collect(&:class), rest])
    assert_equal([[a], b.byteslice(0, 3)], BGP::Bmp.slices(a + b.byteslice(0, 3)))
    short = hex('03 00000002 00 ff')
    assert_equal([[short], ''], BGP::Bmp.slices(short), 'a Length below the header cannot be stepped over')
  end

  # FRR 10.5.1's bgpd_bmp toward a station, recorded on 2026-11-27 (docs/bmp.md):
  # each message parsed with the session its Peer Up gives, and written
  # back to the same octets.
  CAPTURE = File.expand_path('../../fixtures/bmp/frr-10.5.1.bin', __dir__)

  def test_a_capture_from_frr_reads_and_writes_back
    list, rest = BGP::Bmp.slices(File.binread(CAPTURE))
    assert_equal([42, 0], [list.size, rest.size])
    sessions = {}
    kinds = Hash.new(0)
    list.each_with_index do |octets, i|
      key = octets.byteslice(HEADER, PER_PEER)
      msg = Message.factory(octets, sessions[key])
      sessions[key] = msg.session_info if msg.is_a?(Peer_up)
      kinds[msg.class.name.split('::').last] += 1
      assert_equal(octets.unpack1('H*'), msg.to_shex, "message #{i}, #{msg.class}")
    end
    assert_equal({ 'Initiation' => 1, 'Peer_up' => 2, 'Peer_down' => 2, 'Route_monitoring' => 11,
                   'Route_mirroring' => 4, 'Stats_report' => 22 }, kinds)
    init = Message.factory(list.first)
    assert_equal(['FRRouting 10.5.1', 'bgp4r-lab-frr'], [init.sys_descr, init.sys_name])
  end
end
