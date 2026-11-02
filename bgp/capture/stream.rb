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

require 'bgp/capture/dissect'

module BGP
  module Capture

    # Frames BGP messages out of a TCP byte stream.
    #
    #   s = Stream.new
    #   s.push(segment).each { |m| m.octets ; m.flow ; m.errors }
    #
    # **This is the whole of what makes a BGP capture harder than an OSPF
    # one.** OSPF is one packet per datagram, so a dissector reads a frame
    # and is done. BGP runs over TCP, so a message can arrive in two
    # segments and two messages can share one, and nothing in a frame says
    # where a message begins or ends. So one buffer per direction, appended
    # to in arrival order, and messages framed off the front of it by RFC
    # 4271 section 4.1: 16 octets of Marker, a 2 octet Length that counts
    # "the total length of the message, including the header", and a 1
    # octet Type.
    #
    # The framing rules, each with what it refuses to guess:
    #
    # * Fewer than 19 octets buffered is not a header, so nothing is
    #   framed and the octets wait. A trailing part message is **held**,
    #   never emitted, because the next segment may complete it.
    # * A Length at or above 19 is honoured even when it is wrong. Above
    #   4096 breaks a MUST of section 4.1 and is reported, and still
    #   framed, because that is what the octets say and a receiving
    #   speaker reads them the same way.
    # * A Marker that is not all ones breaks a MUST of section 4.1 and is
    #   reported, and still framed, because the Length field is readable
    #   whatever the Marker holds.
    # * A Length **below** 19 is the one case framing cannot continue
    #   from: advancing by it would not move, or would move backwards. So
    #   the stream is resynchronised by looking for the next all ones
    #   Marker, and the octets skipped on the way are emitted as an
    #   unframeable record rather than dropped. That is the
    #   keep-what-you-cannot-read rule of CLAUDE.md at the one place in
    #   this file where octets could be lost.
    #
    # **What it does not do, said plainly rather than left to be found
    # out.** It is not a TCP stack and must not become one. It reads each
    # direction in **arrival order**. A capture whose segments arrived out
    # of order frames garbage from the point they crossed, and nothing
    # here detects it: reordering by sequence number means holding
    # segments, timers and a reassembly queue, which is a TCP
    # implementation and not a dissector. The one artifact it does handle
    # is a retransmission, because that one is common, cheap and lossless
    # to spot: octets whose sequence numbers are behind what this
    # direction has already taken are trimmed off the front of the
    # segment, so a duplicated segment adds nothing twice. A forward jump
    # in the sequence number is a gap the capture did not record; the
    # octets that did arrive are appended and the stream goes on from
    # there, because the alternative is losing the rest of a session to
    # one dropped frame.
    class Stream

      # **A buffer here is bounded by the Length field and needs no guard
      # of its own**, which is worth writing down because the obvious
      # defensive cap turned out to be unreachable. Octets wait only while
      # the front of the buffer holds a header whose Length they have not
      # reached, so what waits is always fewer than that Length, and a 2
      # octet field cannot say more than 65535. The other two reasons to
      # wait, a part header and a resynchronisation, leave 18 octets and
      # 15. So nothing can grow without bound and no cap is written here.
      # RFC 4271 section 4.1 caps a message at 4096, and that is not used
      # as the bound on purpose: a Length of 60000 is a message this tool
      # has to be able to show somebody.

      # A framed message, or octets that could not be framed into one.
      # +octets+ is exactly what the stream held for it, so a decoder
      # lights up the message's own bytes.
      Msg = Struct.new(:flow, :octets, :errors)

      def initialize
        @buffers = {}
        @expect  = {}
      end

      # Takes a Dissect::Segment and returns the messages its octets
      # completed, in order. A segment that carries no payload, or none
      # this direction has not already seen, returns an empty list.
      def push(seg)
        return [] if seg.nil? or seg.payload.nil?
        key = seg.flow
        payload = trim(key, seg)
        return [] if payload.empty?
        buf = (@buffers[key] ||= String.new)
        buf << payload
        frame(key, buf)
      end

      # The octets still waiting, per direction. A part message at the end
      # of a capture lives here and is deliberately not emitted.
      def pending
        @buffers.reject { |_, b| b.empty? }
      end

      private

      # Drops the octets of this segment that this direction has already
      # taken, which is what a retransmission is. The comparison is a
      # signed distance in 32 bit space, so a sequence number that wrapped
      # reads as a small step forward and not as a jump of four billion.
      def trim(key, seg)
        want = @expect[key]
        payload = seg.payload
        if want and seg.seq
          d = (seg.seq - want) & 0xffff_ffff
          d -= 0x1_0000_0000 if d > 0x7fff_ffff
          if d < 0
            already = -d
            return String.new if already >= payload.bytesize
            payload = payload[already..-1]
            @expect[key] = want + payload.bytesize
            return payload
          end
        end
        @expect[key] = ((seg.seq || 0) + payload.bytesize) & 0xffff_ffff if seg.seq
        payload
      end

      # Frames whatever whole messages the front of the buffer holds, and
      # consumes exactly their octets. It mutates buf, which is the
      # buffer this direction keeps, so what is left is what waits.
      def frame(key, buf)
        out = []
        loop do
          break if buf.bytesize < Dissect::HEADER_SIZE
          len = buf[Dissect::MARKER_SIZE, 2].unpack('n')[0]
          if len < Dissect::MIN_LENGTH
            out << resynchronise(key, buf, len)
            next
          end
          break if buf.bytesize < len
          out << Msg.new(key, buf.slice!(0, len), [])
        end
        out
      end

      # The Length field is below the 19 octet minimum, so no message
      # starts here. Look for the next all ones Marker and give back
      # everything before it, which is the honest answer: these octets
      # arrived, they are not a message, and a reader has to be able to
      # see them.
      # The Length that failed is passed in rather than read back off the
      # octets handed over: the skipped run can be shorter than 18 octets,
      # so its own offset 16 is not always there to read.
      def resynchronise(key, buf, len)
        marker = "\xff".b * Dissect::MARKER_SIZE
        at = buf.index(marker, 1)
        why = "the Length field says #{len}, below the 19 octet minimum " \
              '(RFC 4271 section 4.1)'
        if at
          bad = buf.slice!(0, at)
          Msg.new(key, bad, ["#{why}: #{bad.bytesize} octets skipped to the next Marker"])
        else
          # No Marker in what is buffered. Keep the last 15 octets, which
          # is the longest a Marker can be while still incomplete, so one
          # that straddles the next segment boundary is not lost.
          keep = [Dissect::MARKER_SIZE - 1, buf.bytesize - 1].min
          bad = buf.slice!(0, buf.bytesize - keep)
          Msg.new(key, bad, ["#{why}: #{bad.bytesize} octets with no Marker after them"])
        end
      end

    end

  end
end
