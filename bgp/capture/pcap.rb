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

module BGP
  module Capture

    # Reads the classic pcap format, as `tcpdump -w` writes it, from an IO,
    # one record at a time, so it works on a live pipe.
    #
    #   r = BGP::Capture::Pcap::Reader.new($stdin)
    #   r.link                          # => 1 (Ethernet)
    #   r.each { |rec| rec.time ; rec.data ; rec.length }
    #
    # Pure Ruby and no gem, which the library's one runtime dependency rule
    # requires. The shape is ospfv2's lib/ospfv2/pcap.rb, deliberately: the
    # two tools read the same files and write the same JSON, so a console's
    # decoder pane needs one shape and not two.
    #
    # The pcapng format is **not** read. `tcpdump -w -` writes classic pcap,
    # which is what `bgp4r capture` spawns, so nothing here needs it; a
    # pcapng file given to -r is reported as not a pcap stream rather than
    # misread, because its magic is different.
    module Pcap

      class Error < StandardError ; end

      Record = Struct.new(:time, :data, :length)

      class Reader

        # The file header's magic number, which says both the byte order and
        # the resolution of the timestamps: 0xa1b2c3d4 is microseconds and
        # 0xa1b23c4d is nanoseconds. Read in the native order first; a
        # value that is neither means the file was written the other way
        # round, so the header is unpacked big endian instead.
        MAGIC = { 0xa1b2c3d4 => 1_000_000, 0xa1b23c4d => 1_000_000_000 }

        # A sanity bound on a record's captured length. A damaged stream
        # otherwise asks for an arbitrary allocation.
        MAX_RECORD = 262_144

        attr_reader :link, :snaplen

        def initialize(io)
          @io = io
          head = read(24)
          raise Error, 'no pcap header: the capture produced nothing' unless head
          magic = head.unpack('V')[0]
          @order = MAGIC.has_key?(magic) ? 'V' : 'N'
          magic = head.unpack(@order)[0]
          @frac = MAGIC[magic]
          raise Error, "not a pcap stream (magic 0x%08x)" % magic unless @frac
          fmt = @order == 'V' ? 'vvVVVV' : 'nnNNNN'
          _maj, _min, _zone, _sig, @snaplen, @link = head[4..-1].unpack(fmt)
        end

        def each
          return enum_for(:each) unless block_given?
          while (rec = self.next)
            yield rec
          end
        end

        # The next record, or nil at the end of the stream. nil is also the
        # answer to a record header or body that the stream ends inside of:
        # a live pipe killed mid-record is the ordinary way this tool stops.
        def next
          h = read(16)
          return nil unless h
          sec, frac, incl, orig = h.unpack(@order * 4)
          raise Error, "record of #{incl} bytes: the stream is damaged" if incl > MAX_RECORD
          data = read(incl)
          return nil unless data
          Record.new(Time.at(sec, frac * (1_000_000_000 / @frac), :nsec), data, orig)
        end

        private

        def read(n)
          return String.new if n.zero?
          buf = @io.read(n)
          buf && buf.bytesize == n ? buf.b : nil
        end

      end

    end
  end
end
