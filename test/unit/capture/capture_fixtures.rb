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

# Fixtures the four capture test files share: BGP messages, frames and
# pcap streams, built with Array#pack rather than checked in as a binary.
# A binary fixture cannot be read in a review and cannot say which field
# a test is about, and a wrong one looks exactly like a right one.
#
# **Every expectation built here is this reader's own arithmetic from the
# RFC figures and nothing checks it but the RFC.** RFC 4271 carries no
# worked example and no hex, which is the situation CLAUDE.md records for
# RFC 4684, RFC 6368 and RFC 6514, where a hand written expectation was
# wrong a dozen times and the library right. So the field breakdown is
# spelled out beside each builder: without it a wrong fixture reads as
# plausibly as a right one.
#
# Not named *_test.rb, so test/run_unit.rb does not load it as a test;
# each test file requires it, as the to_hash tests require
# to_hash_catalog.rb.
module CaptureFixtures

  # RFC 4271 section 4.1: a 16 octet Marker "MUST be set to all ones", a 2
  # octet Length that is "the total length of the message, including the
  # header", and a 1 octet Type. 19 octets.
  MARKER = ("\xff".b * 16)

  module_function

  # A BGP message with a correct Length. Pass +len+ to make it lie.
  def msg(type, body = '', len = nil)
    body = body.b
    MARKER + [len || body.bytesize + 19, type].pack('nC') + body
  end

  def keepalive
    msg(BGP::Message::KEEPALIVE)
  end

  # RFC 4271 section 4.2: Version 1, My Autonomous System 2, Hold Time 2,
  # BGP Identifier 4, Opt Parm Len 1. So a parameterless OPEN is 19 + 10
  # = 29 octets.
  def open_msg(as = 65001, holdtime = 30, id = '10.0.0.1', parms = '')
    body = [4, as, holdtime].pack('Cnn') + id.split('.').collect { |o| o.to_i }.pack('C4') +
           [parms.bytesize].pack('C') + parms.b
    msg(BGP::Message::OPEN, body)
  end

  # RFC 4271 section 4.3: Withdrawn Routes Length 2, the withdrawn
  # routes, Total Path Attribute Length 2, the attributes, then the NLRI
  # to the end of the message.
  def update_msg(withdrawn = '', attrs = '', nlri = '')
    body = [withdrawn.bytesize].pack('n') + withdrawn.b +
           [attrs.bytesize].pack('n') + attrs.b + nlri.b
    msg(BGP::Message::UPDATE, body)
  end

  # RFC 4271 section 4.3: a prefix is a 1 octet Length in bits and "the
  # minimum number of octets necessary to contain the value".
  def prefix(cidr)
    addr, bits = cidr.split('/')
    bits = bits.to_i
    [bits].pack('C') + addr.split('.').collect { |o| o.to_i }.pack('C4')[0, (bits + 7) / 8].to_s
  end

  # RFC 4271 section 4.3: Attr. Flags 1, Attr. Type Code 1, then a length
  # of 1 octet, or 2 "if the Extended Length attribute flag is set", which
  # is flag 0x10.
  def attr(flags, type, value)
    value = value.b
    if (flags & 0x10).zero?
      [flags, type, value.bytesize].pack('CCC') + value
    else
      [flags, type, value.bytesize].pack('CCn') + value
    end
  end

  # Ethernet, then IPv4 (RFC 791), then TCP (RFC 9293 section 3.1), then
  # the payload. The IPv4 header checksum and the TCP checksum are left
  # zero: nothing in bgp4r verifies either, which bgp/capture/dissect.rb
  # says and says why, so a fixture that computed them would be asserting
  # something no code reads.
  #
  #   Ethernet  destination 6, source 6, ethertype 2                   14
  #   IPv4      version and IHL 1, DSCP 1, total length 2, id 2,
  #             flags and fragment 2, TTL 1, protocol 1, checksum 2,
  #             source 4, destination 4                               20
  #   TCP       source port 2, destination port 2, sequence 4,
  #             acknowledgement 4, data offset and reserved 1,
  #             flags 1, window 2, checksum 2, urgent 2               20
  def frame(payload, seq: 1, sport: 179, dport: 51234,
            src: '10.0.0.1', dst: '10.0.0.2', vlan: nil, link: :ethernet)
    payload = payload.b
    # Data Offset is the high nibble in 32 bit words, so 5 words is 0x50.
    tcp = [sport, dport, seq, 0, 0x50, 0x18, 8192, 0, 0].pack('nnNNCCnnn')
    ip = [0x45, 0, 20 + tcp.bytesize + payload.bytesize, 0, 0, 64, 6, 0].pack('CCnnnCCn') +
         src.split('.').collect { |o| o.to_i }.pack('C4') +
         dst.split('.').collect { |o| o.to_i }.pack('C4')
    head = case link
           when :ethernet
             tag = vlan ? [0x8100, vlan].pack('nn') : ''.b
             ([2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') +
              tag + [0x0800].pack('n'))
           when :ip  then ''.b
           # Linux cooked: packet type 2, ARPHRD type 2, address length 2,
           # address 8, protocol 2. 16 octets.
           when :sll then [0, 1, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0x0800].pack('nnnC8n')
           else raise ArgumentError, "no fixture for link #{link}"
           end
    head + ip + tcp + payload
  end

  # The classic pcap format, which `tcpdump -w -` writes.
  #
  #   file header    magic 4, major 2, minor 2, thiszone 4, sigfigs 4,
  #                  snaplen 4, network 4                             24
  #   record header  ts_sec 4, ts_usec 4, incl_len 4, orig_len 4      16
  #
  # 0xa1b2c3d4 in the host's own order means microsecond timestamps.
  def pcap(frames, network = 1, order = 'V')
    head = [0xa1b2c3d4, 2, 4, 0, 0, 262_144, network]
    s = head.pack(order == 'V' ? 'VvvVVVV' : 'NnnNNNN')
    frames.each_with_index do |f, i|
      s += [1_700_000_000 + i, 500_000, f.bytesize, f.bytesize].pack(order * 4) + f.b
    end
    s
  end

end
