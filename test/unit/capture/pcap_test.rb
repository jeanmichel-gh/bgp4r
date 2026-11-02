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
require 'stringio'
require 'bgp4r'
require 'bgp/capture/pcap'
require 'test/unit/capture/capture_fixtures'

class Capture_Pcap_Test < Test::Unit::TestCase

  include CaptureFixtures

  def reader(s)
    BGP::Capture::Pcap::Reader.new(StringIO.new(s))
  end

  def test_the_file_header_gives_the_link_type_and_the_snaplen
    r = reader(pcap([]))
    assert_equal(1, r.link)
    assert_equal(262_144, r.snaplen)
  end

  def test_a_record_carries_its_octets_and_its_time
    f = frame(keepalive)
    r = reader(pcap([f]))
    rec = r.next
    assert_equal(f.unpack('H*')[0], rec.data.unpack('H*')[0])
    assert_equal(f.bytesize, rec.length)
    assert_equal(1_700_000_000, rec.time.to_i)
    # 500_000 microseconds, which is where the magic number's resolution
    # shows: read as nanoseconds it would be half a millisecond.
    assert_equal(500_000_000, rec.time.nsec)
  end

  def test_the_octets_come_back_binary
    # A record read as anything but BINARY breaks every unpack after it,
    # and the encoding is asserted rather than trusted because that is
    # the only form of the test that fails on the Ruby it runs on.
    rec = reader(pcap([frame(keepalive)])).next
    assert_equal(Encoding::BINARY, rec.data.encoding)
  end

  def test_each_walks_every_record_and_stops
    r = reader(pcap([frame(keepalive), frame(keepalive), frame(keepalive)]))
    assert_equal(3, r.each.to_a.size)
    assert_nil(r.next)
  end

  def test_the_other_byte_order_is_read
    # The magic number says which way round the file was written, so a
    # capture from a big endian machine reads on a little endian one.
    r = reader(pcap([frame(keepalive)], 1, 'N'))
    assert_equal(1, r.link)
    assert_equal(1_700_000_000, r.next.time.to_i)
  end

  def test_the_link_type_is_whatever_the_header_says
    assert_equal(113, reader(pcap([], 113)).link)
  end

  def test_an_empty_stream_says_so_rather_than_raising_somewhere_else
    e = assert_raise(BGP::Capture::Pcap::Error) { reader('') }
    assert_match(/produced nothing/, e.message)
  end

  def test_something_that_is_not_a_pcap_stream_says_so
    e = assert_raise(BGP::Capture::Pcap::Error) { reader('x' * 24) }
    assert_match(/not a pcap stream/, e.message)
  end

  def test_a_damaged_record_length_is_refused_rather_than_allocated
    s = pcap([]) + [1, 0, 1_000_000, 1_000_000].pack('V4')
    e = assert_raise(BGP::Capture::Pcap::Error) { reader(s).next }
    assert_match(/the stream is damaged/, e.message)
  end

  def test_a_stream_that_ends_inside_a_record_ends_the_read
    # A live pipe killed mid record is the ordinary way this tool stops,
    # so it is nil and not an error.
    f = frame(keepalive)
    s = pcap([f])
    assert_nil(reader(s[0, s.bytesize - 4]).next)
  end

  def test_a_stream_that_ends_inside_a_record_header_ends_the_read
    assert_nil(reader(pcap([]) + 'abc').next)
  end

end
