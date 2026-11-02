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

# The framing is the work in a BGP capture, so this is the file that
# matters. Every expectation here is this reader's own arithmetic from
# RFC 4271 section 4.1, since the RFC carries no worked example; see the
# header of capture_fixtures.rb.

require 'test/unit'
require 'bgp4r'
require 'bgp/capture/stream'
require 'bgp/capture/dissect'
require 'test/unit/capture/capture_fixtures'

class Capture_Stream_Test < Test::Unit::TestCase

  include CaptureFixtures

  # One direction of one session. The sequence number matters to exactly
  # one rule, the retransmission one, so every other test leaves it at 1
  # and sends one segment.
  def seg(payload, seq = 1, src = '10.0.0.1', dst = '10.0.0.2', sport = 179, dport = 5000)
    BGP::Capture::Dissect::Segment.new(src, dst, sport, dport, seq, payload.b, [])
  end

  def hex(s)
    s.unpack('H*')[0]
  end

  def setup
    @s = BGP::Capture::Stream.new
    @k = keepalive              # 19 octets
    @o = open_msg               # 29 octets
  end

  def test_one_message_in_one_segment
    out = @s.push(seg(@k))
    assert_equal(1, out.size)
    assert_equal(hex(@k), hex(out.first.octets))
    assert_equal([], out.first.errors)
    assert_equal('10.0.0.1:179 > 10.0.0.2:5000', out.first.flow)
  end

  def test_the_octets_of_a_framed_message_are_binary
    # The buffer a message is cut out of is where the encoding has to be
    # right, because `hex` on the output line comes from it and an
    # octet appended to a US-ASCII buffer with String#<< above 0x7f
    # becomes two. Asserted rather than trusted, which is the only form
    # of the test that fails on the Ruby it runs on.
    out = @s.push(seg(@k))
    assert_equal(Encoding::BINARY, out.first.octets.encoding)
    # And after two appends, which is the case a one segment test misses.
    s = BGP::Capture::Stream.new
    s.push(seg(@o[0, 10]))
    assert_equal(Encoding::BINARY, s.push(seg(@o[10..-1], 11)).first.octets.encoding)
  end

  def test_a_message_split_across_two_segments
    # Nothing is framed off the first segment, because 10 octets are not
    # even a header, and the whole message comes off the second.
    assert_equal([], @s.push(seg(@o[0, 10])))
    out = @s.push(seg(@o[10..-1], 11))
    assert_equal(1, out.size)
    assert_equal(hex(@o), hex(out.first.octets))
  end

  def test_a_message_split_three_ways_with_the_break_inside_the_length_field
    # The break at 17 falls between the two octets of the Length field,
    # which is the split a reader that read the length before checking it
    # had 19 octets would get wrong.
    assert_equal([], @s.push(seg(@o[0, 17])))
    assert_equal([], @s.push(seg(@o[17, 1], 18)))
    out = @s.push(seg(@o[18..-1], 19))
    assert_equal(1, out.size)
    assert_equal(hex(@o), hex(out.first.octets))
  end

  def test_two_messages_in_one_segment
    out = @s.push(seg(@k + @o))
    assert_equal(2, out.size)
    assert_equal([hex(@k), hex(@o)], out.collect { |m| hex(m.octets) })
  end

  def test_three_messages_in_one_segment_come_back_in_order
    out = @s.push(seg(@k + @o + @k))
    assert_equal([19, 29, 19], out.collect { |m| m.octets.bytesize })
  end

  def test_a_message_and_a_part_of_the_next_in_one_segment
    out = @s.push(seg(@k + @o[0, 5]))
    assert_equal(1, out.size)
    assert_equal(hex(@k), hex(out.first.octets))
    # The part message is held, not emitted: the next segment may
    # complete it. This is the rule a reader is most likely to get wrong
    # by emitting what it has.
    assert_equal({ '10.0.0.1:179 > 10.0.0.2:5000' => @o[0, 5] }, @s.pending)
    out = @s.push(seg(@o[5..-1], 25))
    assert_equal([hex(@o)], out.collect { |m| hex(m.octets) })
    assert_equal({}, @s.pending)
  end

  def test_a_trailing_part_message_is_never_emitted
    assert_equal([], @s.push(seg(@o[0, 28])))
    assert_equal(28, @s.pending.values.first.bytesize)
  end

  def test_an_empty_payload_frames_nothing
    assert_equal([], @s.push(seg('')))
    assert_equal({}, @s.pending)
  end

  def test_a_nil_segment_frames_nothing
    assert_equal([], @s.push(nil))
  end

  def test_a_segment_with_no_payload_frames_nothing
    assert_equal([], @s.push(BGP::Capture::Dissect::Segment.new(nil, nil, nil, nil, nil, nil, [])))
  end

  # ---- a Length field that lies

  def test_a_length_above_the_message_maximum_is_framed_and_reported
    # RFC 4271 section 4.1 caps a message at 4096, which this breaks. The
    # octets still say where the message ends, so it is framed on them
    # and the breach is reported by the dissector rather than refused
    # here.
    big = msg(BGP::Message::KEEPALIVE, 'x' * 4100)
    out = @s.push(seg(big))
    assert_equal(1, out.size)
    assert_equal(4119, out.first.octets.bytesize)
    assert_equal([], out.first.errors)
    assert_match(/above the 4096 octet maximum/,
                 BGP::Capture::Dissect.message(out.first.octets).errors.join(' '))
  end

  def test_a_length_longer_than_the_message_eats_the_one_behind_it
    # A Length of 40 on a 19 octet KEEPALIVE claims 21 octets of the 29
    # octet OPEN behind it. The stream says the message is 40 octets
    # long, so 40 are framed and the 8 that are left become the start of
    # the next message, which is what a receiving speaker reads too.
    #
    # **This expectation was written as "nothing is framed" first and the
    # library was right**, which is the hand written arithmetic trap
    # capture_fixtures.rb opens with: 40 is under the 48 octets pushed,
    # so the message completes.
    out = @s.push(seg(msg(BGP::Message::KEEPALIVE, '', 40) + @o))
    assert_equal(1, out.size)
    assert_equal(40, out.first.octets.bytesize)
    assert_equal(8, @s.pending.values.first.bytesize)
  end

  def test_a_length_longer_than_everything_buffered_frames_nothing
    assert_equal([], @s.push(seg(msg(BGP::Message::KEEPALIVE, '', 60) + @o)))
    assert_equal(48, @s.pending.values.first.bytesize)
  end

  def test_a_length_shorter_than_the_message_frames_short_and_desynchronises
    # A Length of 19 on a message that carried a body frames 19 octets
    # and leaves the body as the start of the next message, which is what
    # a receiving speaker would do too.
    out = @s.push(seg(msg(BGP::Message::OPEN, 'abcdefghij', 19)))
    assert_equal(1, out.size)
    assert_equal(19, out.first.octets.bytesize)
    assert_equal({ '10.0.0.1:179 > 10.0.0.2:5000' => 'abcdefghij' }, @s.pending)
  end

  def test_a_length_below_the_minimum_resynchronises_to_the_next_marker
    # The one case framing cannot continue from: advancing by a Length of
    # 3 would not move. So the octets up to the next all ones Marker are
    # handed over as unframeable, and the message after them is framed.
    out = @s.push(seg(msg(BGP::Message::KEEPALIVE, '', 3) + @k))
    assert_equal(2, out.size)
    assert_equal(19, out.first.octets.bytesize)
    assert_match(/below the 19 octet minimum/, out.first.errors.join(' '))
    assert_match(/19 octets skipped to the next Marker/, out.first.errors.join(' '))
    assert_equal(hex(@k), hex(out.last.octets))
    assert_equal([], out.last.errors)
  end

  def test_a_length_of_zero_resynchronises_rather_than_spinning
    # Zero is the value that would loop forever if the rule were
    # "advance by the Length", and that is measured rather than argued:
    # with the resynchronisation removed this file does not fail, it
    # **hangs**, and `timeout` kills it. So read a sabotage of that rule
    # as landing when the run never finishes.
    out = @s.push(seg(msg(BGP::Message::KEEPALIVE, '', 0) + @o))
    assert_equal(2, out.size)
    assert_equal(hex(@o), hex(out.last.octets))
  end

  def test_a_length_below_the_minimum_with_no_marker_after_it_keeps_a_partial_marker
    # Nothing to resynchronise to yet, so the longest run that could
    # still be an incomplete Marker is kept, 15 octets, and the rest is
    # handed over. Keeping them is what lets a Marker that straddles the
    # next segment boundary be found.
    out = @s.push(seg(msg(BGP::Message::KEEPALIVE, '', 0) + "\x01\x02"))
    assert_equal(1, out.size)
    assert_match(/no Marker after them/, out.first.errors.join(' '))
    assert_equal(6, out.first.octets.bytesize)
    assert_equal(15, @s.pending.values.first.bytesize)
  end

  def test_no_octet_is_lost_when_a_length_lies_below_the_minimum
    # The keep-what-you-cannot-read rule at the one place in this file
    # where octets could be dropped: what was pushed is what came back,
    # plus what is still held.
    sent = msg(BGP::Message::KEEPALIVE, '', 3) + @k
    out = @s.push(seg(sent))
    got = out.collect { |m| m.octets }.join + @s.pending.values.join
    assert_equal(hex(sent), hex(got))
  end

  def test_a_marker_that_is_not_all_ones_is_still_framed
    # RFC 4271 section 4.1 makes an all ones Marker a MUST, and the
    # Length field is readable whatever the Marker holds, so the message
    # is framed and the breach is the dissector's to report.
    bad = ("\x00".b * 16) + [19, 4].pack('nC')
    out = @s.push(seg(bad))
    assert_equal(1, out.size)
    assert_equal(hex(bad), hex(out.first.octets))
    assert_match(/Marker is not all ones/,
                 BGP::Capture::Dissect.message(out.first.octets).errors.join(' '))
  end

  # ---- the two directions, and the one TCP artifact handled

  def test_the_two_directions_of_a_session_do_not_share_a_buffer
    # Half a message one way and a whole one the other. A single buffer
    # would frame garbage out of the two interleaved.
    assert_equal([], @s.push(seg(@k[0, 10], 1, '10.0.0.1', '10.0.0.2', 179, 5000)))
    out = @s.push(seg(@k, 1, '10.0.0.2', '10.0.0.1', 5000, 179))
    assert_equal(1, out.size)
    assert_equal('10.0.0.2:5000 > 10.0.0.1:179', out.first.flow)
    out = @s.push(seg(@k[10..-1], 11, '10.0.0.1', '10.0.0.2', 179, 5000))
    assert_equal('10.0.0.1:179 > 10.0.0.2:5000', out.first.flow)
  end

  def test_two_sessions_on_different_ports_do_not_share_a_buffer
    assert_equal([], @s.push(seg(@k[0, 10], 1, '10.0.0.1', '10.0.0.2', 179, 5000)))
    assert_equal([], @s.push(seg(@k[0, 10], 1, '10.0.0.1', '10.0.0.2', 179, 5001)))
    assert_equal(2, @s.pending.size)
  end

  def test_a_retransmitted_segment_is_not_counted_twice
    assert_equal(1, @s.push(seg(@k, 1)).size)
    assert_equal([], @s.push(seg(@k, 1)))
  end

  def test_a_retransmission_that_overlaps_is_trimmed_rather_than_appended
    # 10 octets arrive, then a segment that repeats 5 of them and carries
    # the rest. Appending it whole would push 5 octets twice and frame
    # nothing that is a message.
    assert_equal([], @s.push(seg(@o[0, 10], 1)))
    out = @s.push(seg(@o[5..-1], 6))
    assert_equal(1, out.size)
    assert_equal(hex(@o), hex(out.first.octets))
  end

  def test_a_sequence_number_that_wrapped_reads_as_a_step_and_not_a_jump
    # The comparison is a signed distance in 32 bit space. Taken as
    # unsigned the second segment is four billion octets behind the first
    # and would be dropped as a retransmission.
    assert_equal([], @s.push(seg(@o[0, 10], 0xffff_fffb)))
    out = @s.push(seg(@o[10..-1], 5))
    assert_equal(1, out.size)
    assert_equal(hex(@o), hex(out.first.octets))
  end

  def test_a_forward_gap_in_the_sequence_number_goes_on_from_there
    # A capture that dropped a frame. The octets that did arrive are
    # appended rather than the rest of the session lost, which is the
    # recorded choice; nothing here fills the gap.
    assert_equal([], @s.push(seg(@o[0, 10], 1)))
    out = @s.push(seg(@k, 900))
    assert_equal([], out)
    assert_equal(29, @s.pending.values.first.bytesize)
  end

  def test_a_segment_with_no_sequence_number_is_still_appended
    # A link layer this dissector reads without one is not a case today,
    # and the framing must not depend on it.
    s = BGP::Capture::Stream.new
    half = BGP::Capture::Dissect::Segment.new('a', 'b', 1, 2, nil, @k[0, 10], [])
    rest = BGP::Capture::Dissect::Segment.new('a', 'b', 1, 2, nil, @k[10..-1], [])
    assert_equal([], s.push(half))
    assert_equal(1, s.push(rest).size)
  end

end
