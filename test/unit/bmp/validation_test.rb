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

# What Bmp::Validation finds, one case per finding, each a rule of RFC
# 7854 or RFC 9069. docs/design/bgp-operations.md 8a.
class TestBmpValidation < Test::Unit::TestCase
  include BGP::Bmp

  def peer(type = 0, flags = 0, address = '192.0.2.2') ; Per_peer.new(address, 65_002, '192.0.2.2', type, flags) ; end
  def open ; BGP::Open.new(4, 65_001, 180, '192.0.2.1') ; end
  def names(octets) ; Validation.check(octets).collect(&:name) ; end

  # A message's octets with its Length in step, after a change.
  def relength(octets) ; octets.byteslice(0, 1) + [octets.bytesize].pack('N') + octets.byteslice(5..) ; end

  def good
    [Initiation.new({ :type => 1, :string => 'r' }, { :type => 2, :string => 'n' }),
     Termination.new({ :type => 1, :code => 4 }),
     Route_monitoring.new(peer, BGP::Update.new),
     Stats_report.new(peer, [7, 1]),
     Peer_down.new(peer, 1, BGP::Notification.new(6, 2)), Peer_down.new(peer, 2, 1), Peer_down.new(peer, 4),
     Peer_down.new(peer(3, 0, '0.0.0.0'), 6, [{ :type => 3, :string => 'global' }]),
     Peer_up.new(peer, '192.0.2.1', 179, 1, open, open, { :type => 0, :string => 'x' }),
     Route_mirroring.new(peer, { :type => 1, :code => 0 }, BGP::Keepalive.new)]
  end

  def test_well_formed_messages_have_none
    good.each { |m| assert_equal([], Validation.check(m.encode), m.class.name) }
  end

  # Section 4.1.
  def test_the_common_header
    i = good.first.encode
    assert_equal([:short], names(i.byteslice(0, 5)))
    assert_equal([:version], names(i.dup.tap { |o| o.setbyte(0, 0) }))
    assert_equal([:length], names(i + "\0".b))
    rm = Route_monitoring.new(peer, BGP::Update.new).encode
    assert_equal([:length], names(rm.dup.tap { |o| o.setbyte(4, o.getbyte(4) + 1) }), 'the Length alone wrong')
    f = Validation.check(Unknown.new(99, ''.b).encode)
    assert_equal([[:unknown_type], true], [f.collect(&:name), f.first.ignore?])
    assert_equal('unknown_type: Message Type 99', f.first.to_s)
  end

  # Section 4.2, and RFC 9069 sections 4.2 and 5.1.
  def test_the_per_peer_header
    rm = Route_monitoring.new(peer, BGP::Update.new).encode
    assert_equal([:short], names(relength(rm.byteslice(0, 20))))
    assert_equal([:peer_type], names(rm.dup.tap { |o| o.setbyte(6, 9) }))
    assert_equal([:reserved_flags], names(Route_monitoring.new(peer(0, 0x01), BGP::Update.new).encode))
    assert_equal([], names(Route_monitoring.new(peer(0, FLAG_L | FLAG_A), BGP::Update.new).encode))
    assert_equal([:reserved_flags], names(Route_monitoring.new(peer(3, FLAG_L, '0.0.0.0'), BGP::Update.new).encode),
                 'L on a Loc-RIB peer, as FRR 10.5.1 sends it')
    assert_equal([], names(Route_monitoring.new(peer(3, FLAG_F, '0.0.0.0'), BGP::Update.new).encode))
    assert_equal([:loc_rib_address], names(Route_monitoring.new(peer(3, 0), BGP::Update.new).encode))
  end

  # The BGP message inside: its marker, Length and type.
  def test_the_bgp_message_inside
    rm = Route_monitoring.new(peer, BGP::Update.new).encode
    assert_equal([:bgp], names(rm.dup.tap { |o| o.setbyte(48, 0) }), 'the marker')
    assert_equal([:bgp], names(rm.dup.tap { |o| o.setbyte(48 + 18, 4) }), 'a KEEPALIVE where an UPDATE goes')
    assert_equal([:bgp], names(relength(rm + "\0".b)), 'octets past the UPDATE')
    assert_equal([:bgp], names(relength(rm.byteslice(0, 60))))
  end

  # Section 4.8.
  def test_stats
    sr = Stats_report.new(peer, [7, 1]).encode
    assert_equal([:no_stats, :count], names(relength(sr.byteslice(0, 48) + [0].pack('N') + sr.byteslice(52..))))
    assert_equal([:no_stats], names(Stats_report.new(peer).encode))
    assert_equal([:count], names(sr.dup.tap { |o| o.setbyte(51, 2) }))
    assert_equal([:short], names(relength(sr.byteslice(0, 50))))
    assert_equal([:length], names(relength(sr[0...-2])))
    assert_equal([:length], names(relength(sr + "\0".b)))
    f = Validation.check(Stats_report.new(peer, { :type => 65_531, :hex => '00' }, { :type => 7, :hex => '01' }).encode)
    assert_equal([[:unknown_stat, :unknown_stat], [true, true]], [f.collect(&:name), f.collect(&:ignore?)])
  end

  # Section 4.9 and RFC 9069 section 5.3.
  def test_peer_down
    pd = Peer_down.new(peer, 4).encode
    assert_equal([:short], names(relength(pd[0...-1])))
    assert_equal([:reason], names(pd.dup.tap { |o| o.setbyte(-1, 0) }))
    assert_equal([:reason], names(pd.dup.tap { |o| o.setbyte(-1, 7) }))
    assert_equal([:length], names(relength(pd + "\0".b)))
    assert_equal([:length], names(relength(Peer_down.new(peer, 5).encode + "\0".b)))
    assert_equal([:length], names(relength(Peer_down.new(peer, 2, 1).encode + "\0".b)))
    assert_equal([:bgp], names(relength(Peer_down.new(peer, 3, BGP::Notification.new(6, 2)).encode[0...-2])))
    assert_equal([:length], names(relength(Peer_down.new(peer, 6, [{ :type => 3, :string => 'global' }]).encode[0...-1])))
  end

  # Section 4.10.
  def test_peer_up
    up = Peer_up.new(peer, '192.0.2.1', 179, 1, open, open).encode
    assert_equal([:short], names(relength(up.byteslice(0, 60))))
    assert_equal([:bgp], names(up.dup.tap { |o| o.setbyte(48 + 20 + 18, 2) }), 'the Sent OPEN is not an OPEN')
    assert_equal([:bgp], names(up.dup.tap { |o| o.setbyte(48 + 20 + 29 + 18, 2) }), 'nor the Received OPEN')
    assert_equal([:length], names(relength(up + "\0\0\0".b)), 'a TLV that is not all there')
  end

  # Sections 4.3 and 4.5.
  def test_initiation_and_termination
    assert_equal([:missing], names(Initiation.new({ :type => 1, :string => 'r' }).encode))
    assert_equal([:missing, :missing], names(Initiation.new({ :type => 0, :string => 's' }).encode))
    assert_equal([:missing], names(Termination.new({ :type => 0, :string => 'x' }).encode))
    assert_equal([:length], names(Termination.new({ :type => 1, :hex => '00' }).encode))
    assert_equal([:length, :missing], names(relength(good.first.encode.byteslice(0, 12))), 'sysDescr whole, sysName cut')
  end

  # Section 4.7: the BGP Message TLV last.
  def test_route_mirroring
    assert_equal([:order], names(Route_mirroring.new(peer, BGP::Keepalive.new, { :type => 1, :code => 1 }).encode))
    assert_equal([], names(Route_mirroring.new(peer, { :type => 1, :code => 1 }).encode))
  end
end
