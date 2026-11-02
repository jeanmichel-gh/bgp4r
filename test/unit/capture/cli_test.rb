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

# The whole command, end to end, over a pcap file. This is the only test
# here that proves the four parts agree with each other: the pcap reader,
# the frame dissector, the reassembly and the message dissector are each
# pure, so every test of one of them reads octets the test itself wrote.
# It is the shape test/functional/flow_spec_test.rb has for the wiring
# sites of a family, and it is here rather than under test/functional
# because it needs no socket and no router.
#
# The live path, tcpdump on an interface, is not exercised: tcpdump is
# not installed in this sandbox and spawning it in a unit test would need
# a privileged interface. What is asserted instead is that its absence is
# reported rather than raised.

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'json'
require 'bgp4r'
require 'bgp/capture/cli'
require 'test/unit/capture/capture_fixtures'

class Capture_CLI_Test < Test::Unit::TestCase

  include CaptureFixtures

  def setup
    @out = StringIO.new
    @cli = BGP::Capture::CLI.new(@out, @out)
  end

  # Runs the command over a pcap file built from these frames, and
  # returns the parsed JSON lines.
  def run_capture(frames, *argv)
    status = nil
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write(pcap(frames)) }
      status = @cli.capture(['-r', path] + argv)
    end
    [status, @out.string.each_line.collect { |l| JSON.parse(l) }]
  end

  def packets(lines)
    lines.collect { |l| l['packet'] }.compact
  end

  # ---- the umbrella's dispatch

  def test_version_prints_the_librarys_version
    assert_equal(0, @cli.start(['version']))
    assert_equal(BGP::VERSION, @out.string.strip)
  end

  def test_the_gemspec_reads_the_version_rather_than_carrying_its_own
    # One place for the version, which is why bgp/version.rb exists: a
    # command cannot print what the library does not answer.
    #
    # **Read as text and not loaded, and the first draft of this test
    # loaded it.** `Gem::Specification.load` evaluates the gemspec, which
    # runs `git ls-files`, and the Docker image has neither git nor a
    # .git: the spec came back nil and the test errored in the three
    # `docker ruby` CI jobs while passing on every runner job and
    # locally. Same family as the base64 and frozen-literal entries in
    # CLAUDE.md, one step over: the local tree is not the image.
    #
    # Asserting the two agree would also be vacuous, since the gemspec
    # reads the constant. What is worth asserting is that it still does
    # and has grown no literal of its own, which is a claim about what a
    # file does, so it is matched as code and not as a word.
    src = File.read(File.expand_path('../../../bgp4r.gemspec', __dir__))
    assert_match(/^\s*s\.version\s*=\s*BGP::VERSION\s*$/, src)
    assert_no_match(/^\s*s\.version\s*=\s*["']/, src)
    assert_match(%r{^require File\.expand_path\('bgp/version', __dir__\)$}, src)
  end

  def test_no_subcommand_prints_the_usage_and_succeeds
    assert_equal(0, @cli.start([]))
    assert_match(/Usage: bgp4r SUBCOMMAND/, @out.string)
  end

  def test_help_prints_the_usage
    assert_equal(0, @cli.start(['--help']))
    assert_match(/capture/, @out.string)
  end

  def test_an_unknown_subcommand_prints_the_usage_and_fails
    assert_equal(1, @cli.start(['nonesuch']))
    assert_match(/Usage: bgp4r SUBCOMMAND/, @out.string)
  end

  def test_the_usage_lists_the_commands_that_do_not_exist_yet
    # docs/daemon.md names four commands and this ships one. Saying so is
    # the point: an executable in a released gem that answers nothing is
    # worse than one that is not there.
    @cli.start([])
    assert_match(/Not yet implemented: sim, routegen, lab new/, @out.string)
  end

  def test_capture_is_reached_through_the_dispatch
    # Every other test here calls #capture directly, so without this the
    # one arm of the case that matters is never taken.
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write(pcap([frame(keepalive)])) }
      assert_equal(0, @cli.start(['capture', '-r', path]))
    end
    assert_equal(1, @out.string.each_line.count { |l| JSON.parse(l)['packet'] })
  end

  def test_a_dash_reads_standard_input
    # `-r -` is what a console pipes a capture into, so the branch is
    # worth a test even though the live tcpdump path is not reachable
    # here.
    old = $stdin
    begin
      $stdin = StringIO.new(pcap([frame(keepalive)]))
      assert_equal(0, @cli.capture(['-r', '-']))
    ensure
      $stdin = old
    end
    lines = @out.string.each_line.collect { |l| JSON.parse(l) }
    assert_equal('-', lines.first['capture']['file'])
    assert_equal(1, packets(lines).size)
  end

  def test_the_subcommands_are_the_two_that_exist
    assert_equal(%w{capture version}, BGP::Capture::CLI::SUBCOMMANDS)
  end

  # ---- the envelope

  def test_the_first_line_is_the_capture_header
    _, lines = run_capture([frame(keepalive)])
    h = lines.first['capture']
    assert_not_nil(h)
    assert_equal('ethernet', h['link'])
    # Reading a file, so there is no interface and no filter of ours.
    assert_nil(h['interface'])
    assert_nil(h['filter'])
  end

  def test_the_header_says_the_unit_is_a_message_and_not_a_frame
    # The one key of ospfv2's envelope that means something different
    # here, because a BGP message is not a frame. A consumer that reads
    # `hex` as a frame's octets would be wrong about every offset.
    _, lines = run_capture([frame(keepalive)])
    assert_equal('message', lines.first['capture']['unit'])
  end

  def test_the_header_names_the_interface_and_the_filter_on_a_live_run
    # Not run here, since tcpdump is absent, but the header is built
    # before the spawn, so the two keys are checked through the error
    # path: the filter has to be ours and reported, because routescope
    # passes none and only displays the string the image says it used.
    assert_equal('tcp port 179', BGP::Capture::CLI::DEFAULT_FILTER)
    assert_equal('eth0', BGP::Capture::CLI::DEFAULT_INTERFACE)
  end

  def test_one_message_in_one_frame
    status, lines = run_capture([frame(keepalive)])
    assert_equal(0, status)
    p = packets(lines)
    assert_equal(1, p.size)
    assert_equal(1, p.first['seq'])
    assert_equal('KEEPALIVE', p.first['summary'])
    assert_equal(19, p.first['length'])
    assert_equal(keepalive.unpack('H*')[0], p.first['hex'])
    assert_equal('10.0.0.1:179 > 10.0.0.2:51234', p.first['flow'])
    assert_equal([], p.first['errors'])
  end

  def test_the_length_and_the_hex_are_the_messages_and_not_the_frames
    # A frame is 54 octets of headers plus the message, so a tool that
    # reported the frame would say 73 here and hand over the Ethernet
    # octets as hex.
    _, lines = run_capture([frame(keepalive)])
    p = packets(lines).first
    assert_equal(19, p['length'])
    assert_equal(p['length'] * 2, p['hex'].size)
  end

  def test_every_field_offset_is_from_the_start_of_the_message
    _, lines = run_capture([frame(open_msg)])
    f = packets(lines).first['fields']
    assert_equal(0, f.first['offset'])
    assert_equal('BGP header', f.first['name'])
  end

  def test_the_time_comes_from_the_pcap_record
    _, lines = run_capture([frame(keepalive)])
    assert_equal('2023-11-14T22:13:20.500000Z', packets(lines).first['time'])
  end

  # ---- the framing, end to end

  def test_a_message_split_across_two_frames_is_one_packet_line
    o = open_msg
    status, lines = run_capture([frame(o[0, 12]), frame(o[12..-1], :seq => 13)])
    assert_equal(0, status)
    p = packets(lines)
    assert_equal(1, p.size)
    assert_equal(o.unpack('H*')[0], p.first['hex'])
    assert_equal(29, p.first['length'])
  end

  def test_two_messages_in_one_frame_are_two_packet_lines
    status, lines = run_capture([frame(keepalive + open_msg)])
    assert_equal(0, status)
    p = packets(lines)
    assert_equal(['KEEPALIVE', 'OPEN AS 65001 holdtime 30s id 10.0.0.1'],
                 p.collect { |x| x['summary'] })
    assert_equal([1, 2], p.collect { |x| x['seq'] })
  end

  def test_a_trailing_part_message_prints_nothing
    # Held, not emitted, which is the reassembly rule reaching the
    # output: the next frame may complete it and there is no next frame.
    #
    # **The part has to be longer than a header**, 25 octets of the 29
    # octet OPEN, or the test passes against a reader that emits what it
    # has: a 10 octet tail is refused by the "not even a header" rule
    # before the hold rule is reached. Found by sabotage, which passed
    # with the 10 octet version.
    _, lines = run_capture([frame(keepalive), frame(open_msg[0, 25], :seq => 20)])
    assert_equal(1, packets(lines).size)
  end

  def test_a_session_in_both_directions_keeps_its_two_flows_apart
    o = open_msg
    status, lines = run_capture([
      frame(o[0, 10]),
      frame(keepalive, :src => '10.0.0.2', :dst => '10.0.0.1', :sport => 51_234, :dport => 179),
      frame(o[10..-1], :seq => 11)
    ])
    assert_equal(0, status)
    p = packets(lines)
    assert_equal(2, p.size)
    assert_equal('10.0.0.2:51234 > 10.0.0.1:179', p.first['flow'])
    assert_equal('10.0.0.1:179 > 10.0.0.2:51234', p.last['flow'])
    assert_equal(o.unpack('H*')[0], p.last['hex'])
  end

  def test_a_length_field_that_lies_below_the_minimum_still_prints_its_octets
    # The keep-what-you-cannot-read rule reaching the output. The
    # unframeable octets are a packet line with the reason, and the
    # message behind them is read.
    liar = msg(BGP::Message::KEEPALIVE, '', 2)
    _, lines = run_capture([frame(liar + open_msg)])
    p = packets(lines)
    assert_equal(2, p.size)
    assert_match(/below the 19 octet minimum/, p.first['errors'].join(' '))
    assert_equal(liar.unpack('H*')[0], p.first['hex'])
    assert_equal('OPEN AS 65001 holdtime 30s id 10.0.0.1', p.last['summary'])
  end

  def test_a_message_type_bgp4r_cannot_decode_still_prints
    _, lines = run_capture([frame(msg(99, 'abcd'))])
    p = packets(lines).first
    assert_equal('type 99', p['summary'])
    assert_equal(msg(99, 'abcd').unpack('H*')[0], p['hex'])
    assert(p['errors'].any? { |e| e =~ /bgp4r could not decode/ }, p['errors'].inspect)
  end

  def test_the_reassemblers_errors_and_the_dissectors_both_reach_the_line
    # Two sources, one list, and the framing one comes first because it
    # happened first.
    liar = ("\x00".b * 16) + [2, 4].pack('nC')
    _, lines = run_capture([frame(liar + keepalive)])
    errs = packets(lines).first['errors']
    assert_match(/below the 19 octet minimum/, errs.first)
    assert(errs.any? { |e| e =~ /Marker is not all ones/ }, errs.inspect)
  end

  def test_a_frame_that_is_not_bgp_prints_no_packet_line_and_does_not_stop_the_read
    # No filter is applied to a file, so a capture can hold anything.
    not_ip = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') +
             [0x0806].pack('n') + ('x' * 20)
    status, lines = run_capture([not_ip, frame(keepalive)])
    assert_equal(0, status)
    assert_equal(1, packets(lines).size)
  end

  # ---- the flags

  def test_count_stops_the_read
    frames = [frame(keepalive + keepalive + keepalive), frame(keepalive, :seq => 58)]
    _, lines = run_capture(frames, '-c', '2')
    # The frame is read whole, so the count stops after the frame that
    # reached it rather than mid frame. Three came out of the first one.
    assert_equal(3, packets(lines).size)
  end

  def test_count_stops_before_a_later_frame
    frames = [frame(keepalive), frame(keepalive, :seq => 20), frame(keepalive, :seq => 39)]
    _, lines = run_capture(frames, '-c', '1')
    assert_equal(1, packets(lines).size)
  end

  def test_the_link_type_in_the_file_header_chooses_the_dissector
    status = nil
    lines = nil
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write(pcap([frame(keepalive, :link => :ip)], 101)) }
      status = @cli.capture(['-r', path])
    end
    lines = @out.string.each_line.collect { |l| JSON.parse(l) }
    assert_equal(0, status)
    assert_equal('ip', lines.first['capture']['link'])
    assert_equal(1, packets(lines).size)
  end

  # ---- the error line

  def test_a_link_type_with_no_dissector_is_one_error_line_and_a_status_of_one
    status = nil
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write(pcap([frame(keepalive)], 999)) }
      status = @cli.capture(['-r', path])
    end
    assert_equal(1, status)
    assert_match(/link type 999 is not supported/, JSON.parse(@out.string)['error'])
  end

  def test_a_file_that_is_not_a_pcap_is_one_error_line_and_a_status_of_one
    status = nil
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write('x' * 40) }
      status = @cli.capture(['-r', path])
    end
    assert_equal(1, status)
    assert_match(/not a pcap stream/, JSON.parse(@out.string)['error'])
  end

  def test_a_file_that_is_not_there_is_one_error_line_and_a_status_of_one
    # A SystemCallError, so it goes down the same path rather than out of
    # the process with a backtrace.
    assert_equal(1, @cli.capture(['-r', '/nonesuch/nope.pcap']))
    assert_match(/No such file/, JSON.parse(@out.string)['error'])
  end

  def test_an_empty_file_is_one_error_line
    status = nil
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write('') }
      status = @cli.capture(['-r', path])
    end
    assert_equal(1, status)
    assert_match(/produced nothing/, JSON.parse(@out.string)['error'])
  end

  def test_every_line_is_one_json_object
    # Newline delimited JSON, which is the contract: a reader takes a
    # line at a time and never buffers to a document.
    _, lines = run_capture([frame(keepalive + open_msg)])
    assert_equal(3, lines.size)
    assert(lines.all? { |l| l.is_a?(Hash) and l.keys.size == 1 })
  end

end
