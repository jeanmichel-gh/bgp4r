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

require 'bgp/version'
require 'bgp/capture/pcap'
require 'bgp/capture/dissect'
require 'bgp/capture/stream'

module BGP
  module Capture

    # The `bgp4r` umbrella command. `docs/daemon.md` names four commands,
    # `bgp4rd`, `bgp4r-cli`, `bgp4r` and `bgp4r-sim`; this is the third,
    # with the two subcommands that exist. The rest are listed in the usage
    # as not yet implemented rather than stubbed, because an executable
    # that answers nothing is worse in a released gem than one that is not
    # there.
    #
    #   BGP::Capture::CLI.new.start(ARGV)   # => an exit status
    #
    # Output goes to an injected IO so a test reads it as a String rather
    # than capturing a process's stdout.
    class CLI

      SUBCOMMANDS = %w{capture version}

      # `docs/routescope-labs.md` section 4: routescope's capture argv is
      # hard coded to `IMAGE capture -i IFACE`, so it passes **no
      # filter** and only displays the string the image says it used.
      # That makes this default part of the contract rather than a
      # convenience, which is why it is a named constant and asserted.
      DEFAULT_FILTER = 'tcp port 179'
      DEFAULT_INTERFACE = 'eth0'

      USAGE = <<-TEXT
Usage: bgp4r SUBCOMMAND [options]

  capture   dissect BGP messages off an interface or a pcap file
  version   print the bgp4r version

Not yet implemented: sim, routegen, lab new. See docs/daemon.md.
      TEXT

      def initialize(out = $stdout, err = $stderr)
        @out = out
        @err = err
      end

      def start(argv)
        case argv.first
        when 'capture' then capture(argv[1..-1])
        when 'version' then version
        when nil, '-h', '--help'
          @out.print USAGE
          0
        else
          @err.print USAGE
          1
        end
      end

      def version
        @out.puts BGP::VERSION
        0
      end

      # Reads BGP off an interface, a pcap file or standard input, and
      # prints one JSON line per BGP message:
      #
      #   {"capture": {"interface":, "file":, "link":, "filter":, "unit":}}
      #   {"packet": {"seq":, "time":, "flow":, "length":, "hex":,
      #               "summary":, "fields":, "errors":}}
      #   {"error": "..."}   and the exit status is 1
      #
      # The envelope is ospfv2's, which `docs/routescope-labs.md` section 4
      # gives as the contract: a console's decoder pane is generic over
      # that shape, so matching it costs routescope no code.
      #
      # **One key of it means something different here and the header says
      # so**: `unit` is `message`, where ospfv2's unit is a frame. A BGP
      # message can arrive in two frames and two can share one, so a
      # `packet` line is one BGP message, `hex` is that message's own
      # octets, `length` is their count and every offset in `fields` is
      # from the message's first octet. The transport is `flow`, a
      # direction as `src:port > dst:port`, rather than byte offset fields,
      # because the frame headers are not octets of the message.
      def capture(argv)
        require 'json'
        require 'time'
        require 'optparse'
        opts = { :interface => DEFAULT_INTERFACE, :filter => DEFAULT_FILTER,
                 :count => nil, :file => nil }
        OptionParser.new do |o|
          o.on('-i', '--interface IFACE') { |v| opts[:interface] = v }
          o.on('-r', '--read FILE', 'a pcap file, - for stdin') { |v| opts[:file] = v }
          o.on('-f', '--filter EXPR') { |v| opts[:filter] = v }
          o.on('-c', '--count N', Integer) { |v| opts[:count] = v }
        end.parse!(argv)
        @out.sync = true if @out.respond_to?(:sync=)
        io, pid = source(opts)
        reader = Pcap::Reader.new(io)
        link = Dissect::LINKS[reader.link]
        raise ArgumentError, "link type #{reader.link} is not supported" unless link
        @out.puts JSON.generate(:capture => {
                                  :interface => opts[:file] ? nil : opts[:interface],
                                  :file => opts[:file], :link => link.to_s,
                                  :filter => opts[:file] ? nil : opts[:filter],
                                  :unit => 'message' })
        stream = Stream.new
        seq = 0
        reader.each do |rec|
          seg = Dissect.segment(rec.data, :link => link)
          stream.push(seg).each do |msg|
            seq += 1
            d = Dissect.message(msg.octets).to_h
            d[:errors] = msg.errors + d[:errors]
            @out.puts JSON.generate({ :packet =>
              { :seq => seq, :time => rec.time.utc.iso8601(6), :flow => msg.flow,
                :length => msg.octets.bytesize,
                :hex => msg.octets.unpack('H*')[0] }.merge(d) })
          end
          break if opts[:count] and seq >= opts[:count]
        end
        0
      rescue Pcap::Error, ArgumentError, SystemCallError => e
        @out.puts JSON.generate(:error => e.message)
        1
      ensure
        if pid
          begin ; Process.kill('TERM', pid) ; rescue StandardError ; end
          begin ; Process.wait(pid) ; rescue StandardError ; end
        end
      end

      private

      # tcpdump into a pipe, as ospfv2 does, because a pure Ruby packet
      # socket would be a native dependency and the library has one gem
      # and means to keep it. `-U` is what makes a live capture live: it
      # flushes each record rather than filling a buffer first.
      #
      # **The filter is applied here and reported, never taken from the
      # caller of the contract.** `docs/routescope-labs.md` section 4:
      # routescope passes no filter and only displays the string the image
      # says it used, so the default has to be right on its own.
      # **The nine lines from `::IO.pipe` down, and the two that kill the
      # child in `capture`'s ensure, are the only lines in bgp/capture/
      # that no test runs**, which is said here rather than left for a
      # coverage report to raise as a question. They are the live path:
      # tcpdump is not installed in the sandbox this was written in, and
      # spawning it in a unit test would want a privileged interface. The
      # file path beside them is exercised in full, and the one branch a
      # test can reach without tcpdump, a pcap file that is not there, is
      # asserted because of the bug below.
      #
      # **The rescue is around the spawn and nothing else, deliberately.**
      # A method level `rescue Errno::ENOENT` also catches `File.open` of
      # a pcap file that is not there and reports it as tcpdump being
      # missing, which is a confident wrong answer about the one thing
      # the caller got wrong. ospfv2's `capture_source` has that shape and
      # the same fault; found here by a test for a path that does not
      # exist.
      def source(opts)
        return [$stdin.binmode, nil] if opts[:file] == '-'
        return [File.open(opts[:file], 'rb'), nil] if opts[:file]
        r, w = ::IO.pipe
        begin
          pid = Process.spawn('tcpdump', '-U', '-n', '-s', '0', '-w', '-',
                              '-i', opts[:interface], *opts[:filter].split,
                              :out => w, :err => File::NULL)
        rescue Errno::ENOENT
          w.close
          r.close
          raise ArgumentError, 'tcpdump is not installed here'
        end
        w.close
        [r, pid]
      end

    end

  end
end
