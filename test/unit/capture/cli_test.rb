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

  def test_the_usage_calls_nothing_unimplemented_any_more
    # Saying so was the point while anything was missing: an executable
    # in a released gem that answers nothing is worse than one that is
    # not there. **`sim` and `routegen` came off that line, and `lab new`
    # was the last name on it**, so the guard is re-pointed at the new
    # truth rather than weakened: the usage must now claim nothing is
    # missing at all, and no subcommand that exists may be listed as
    # missing if the line ever comes back.
    @cli.start([])
    assert_no_match(/Not yet implemented/, @out.string)
    BGP::Capture::CLI::SUBCOMMANDS.each do |s|
      assert_match(/^  #{s}\b/, @out.string, "#{s} is not in the usage")
      assert_no_match(/Not yet implemented:.*\b#{s}\b/, @out.string,
                      "#{s} exists and the usage still calls it missing")
    end
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

  # Three of docs/daemon.md's four commands reach something here:
  # `capture`, `sim` and `routegen`, with `lab` and `version` beside
  # them. **`lab` is the last of the umbrella's own subcommands**, so
  # this list is the whole of what that document's table names.
  def test_the_subcommands_are_the_five_that_exist
    assert_equal(%w{capture sim routegen lab version}, BGP::Capture::CLI::SUBCOMMANDS)
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

  # ---- lab new
  #
  # The assertions run against the **real** `lab/topologies/` folders
  # wherever they can, so a discovery that stopped working fails here
  # rather than passing against a copy of itself. What no real folder
  # can make a claim about gets a source folder of its own, built here
  # and reached through `CLI.topologies`'s injected root: a file mode
  # that is not 0644, a `*.clab.yml`, a `.gitignore`, a folder with
  # nothing in it, a name this repository has never had, and a
  # `lab/topologies/` that is not there.
  #
  # `Dir.mktmpdir` for the destinations, as the capture tests above use
  # it, so the whole file honours TMPDIR and nothing writes into the
  # repository.

  def lab_new(*argv)
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      dir = File.join(tmp, 'lab')
      yield dir, @cli.lab(['new', dir] + argv)
    end
  end

  # The relative path of every file and directory under a folder, which
  # is what "the copy reproduces the folder" means.
  def entries(dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, :base => dir).
      reject { |r| File.basename(r) == '.' || r.start_with?('.git/') || r == '.git' }.sort
  end

  def topologies_dir
    BGP::Capture::CLI::TOPOLOGIES
  end

  def git?
    system('git', '--version', :out => File::NULL, :err => File::NULL)
  end

  def test_the_topologies_are_discovered_and_not_listed
    # The four folders in the repository when this was written must all
    # be offered, and the default has to be one of whatever is there, or
    # `bgp4r lab new DIR` with no name refuses its own default. A folder
    # added later passes this unchanged, which is the point of
    # discovering them; what says discovery really reads the filesystem
    # is the test below.
    found = BGP::Capture::CLI.topologies
    %w{add-path fault-matrix routegen two-speakers}.each do |n|
      assert(found.include?(n), "#{n} is a topology folder and was not discovered")
    end
    assert(found.include?(BGP::Capture::CLI::DEFAULT_TOPOLOGY),
           'the default topology is not among the discovered ones')
    found.each do |n|
      assert(File.directory?(File.join(topologies_dir, n)), "#{n} is not a folder")
    end
  end

  def test_discovery_reads_the_filesystem_and_not_a_list
    # **The assertion that cannot pass by luck**, which is why it is
    # here beside the one above: the four names in that test would be
    # answered by a hard coded table exactly as well as by a directory
    # read, the way CLAUDE.md's free port probe answered whether or not
    # the code read its argument. A name this repository has never had
    # cannot be in any table.
    Dir.mktmpdir('bgp4r-lab-root') do |root|
      Dir.mkdir(File.join(root, 'invented-topology'))
      Dir.mkdir(File.join(root, 'another-one'))
      File.write(File.join(root, 'not-a-folder.yml'), "x\n")
      assert_equal(%w{another-one invented-topology},
                   BGP::Capture::CLI.topologies(root))
    end
  end

  def test_a_copy_reproduces_the_folders_contents
    # `add-path` and not the default, because it is the only topology
    # with a subfolder, so this is also the test that says the copy
    # recurses. Naming a topology that is not the default is what makes
    # it fail if NAME is ignored.
    src = File.join(topologies_dir, 'add-path')
    lab_new('add-path') do |dir, status|
      assert_equal(0, status)
      assert_equal(entries(src), entries(dir))
      assert(entries(dir).include?('scenarios/two-paths.yml'),
             'the scenarios subfolder did not come across')
      entries(src).each do |rel|
        from = File.join(src, rel)
        next if File.directory?(from)
        assert_equal(File.binread(from), File.binread(File.join(dir, rel)),
                     "#{rel} differs from the one it was copied from")
      end
      # And the copy is of the topology that was asked for, not of
      # whichever one came first: a default-name bug passes everything
      # above except this.
      assert_match(/^name: bgp4r-add-path$/,
                   File.read(File.join(dir, 'compose.yml')))
    end
  end

  def test_file_modes_are_preserved
    # Two things make this test the shape it is, and the second was
    # found by sabotaging the first version of it.
    #
    # **Every file in `lab/topologies/` is 0644 today**, which is what an
    # 022 umask gives a freshly created file, so a copy that dropped the
    # chmod would pass against the real folders. Hence a source folder
    # built here with modes that are not the default.
    #
    # **And that was still not enough: with `File.chmod` deleted from
    # `copy_lab` the whole file passed.** `FileUtils.cp` opens the
    # destination with the source's mode, so under the usual 022 umask it
    # already answers 0755 and the explicit chmod is redundant. Measured
    # on 2026-11-02: under umask 077 it answers **0700** for the same
    # source, because the umask applies to that open, and the chmod is
    # then the whole of what keeps an executable bit. So the copy runs
    # under a restrictive umask here, which is the only umask that can
    # see the line, and it is the one a person in a hardened container
    # has. Same family as CLAUDE.md's free port probe: the obvious
    # assertion passed whether or not the code did its job.
    Dir.mktmpdir('bgp4r-lab-root') do |root|
      src = File.join(root, 'modes')
      Dir.mkdir(src)
      File.write(File.join(src, 'run.sh'), "#!/bin/sh\n")
      File.chmod(0o755, File.join(src, 'run.sh'))
      File.write(File.join(src, 'secret.yml'), "k: v\n")
      File.chmod(0o600, File.join(src, 'secret.yml'))
      Dir.mktmpdir('bgp4r-lab') do |tmp|
        dir = File.join(tmp, 'lab')
        old = File.umask(0o077)
        begin
          BGP::Capture::CLI.copy_lab(src, dir)
        ensure
          File.umask(old)
        end
        assert_equal(0o755, File.stat(File.join(dir, 'run.sh')).mode & 0o777)
        assert_equal(0o600, File.stat(File.join(dir, 'secret.yml')).mode & 0o777)
      end
    end
  end

  def test_a_gitignore_in_the_source_is_honoured_and_its_absence_is_not_an_error
    # The absent case is the one every other test here takes, since
    # four of the five topologies have no `.gitignore`, so it is
    # asserted by all of them. This is the present case, in the three
    # shapes `copy_lab`'s header names: a comment and a blank line are
    # skipped, a basename matches at any depth, a slash pattern matches
    # the relative path and nothing else, and a trailing slash matches
    # a directory and takes everything under it.
    Dir.mktmpdir('bgp4r-lab-root') do |root|
      src = File.join(root, 'ignores')
      Dir.mkdir(src)
      Dir.mkdir(File.join(src, 'runs'))
      Dir.mkdir(File.join(src, 'recordings'))
      Dir.mkdir(File.join(src, 'recordings', 'deep'))
      Dir.mkdir(File.join(src, 'keep'))
      Dir.mkdir(File.join(src, 'runs', 'deep'))
      Dir.mkdir(File.join(src, 'clab-run'))
      File.write(File.join(src, '.gitignore'),
                 "# a comment\nstate.json\n\n*.log\nruns/*.yml\nrecordings/\nclab-*/\n")
      File.write(File.join(src, 'compose.yml'), "name: x\n")
      File.write(File.join(src, 'state.json'), "{}\n")
      File.write(File.join(src, 'speaker.log'), "noise\n")
      File.write(File.join(src, 'runs', 'state.json'), "{}\n")      # basename, any depth
      File.write(File.join(src, 'runs', 'old.yml'), "x\n")          # the slash pattern
      # **The case that makes FNM_PATHNAME load-bearing**, and it was
      # added because sabotaging that flag away passed everything else:
      # `runs/*.yml` is one directory deep, so git does not let its `*`
      # cross a separator and this file is kept. Without the flag it is
      # wrongly excluded, which is a file silently missing from a lab.
      File.write(File.join(src, 'runs', 'deep', 'b.yml'), "x\n")
      File.write(File.join(src, 'keep', 'old.yml'), "x\n")          # not under runs/, kept
      File.write(File.join(src, 'recordings', 'run.pcap'), "x\n")   # the directory
      File.write(File.join(src, 'recordings', 'deep', 'more'), "x\n")
      File.write(File.join(src, 'clab-run', 'state'), "x\n")        # directory, excluded
      # **The case that makes the `directory &&` guard load-bearing**,
      # added for the same reason as the one above: sabotaging the guard
      # away passed everything else. `clab-*/` is a directory pattern,
      # so a *file* whose name it would otherwise match is kept, which
      # is git's rule and is `bgp4r-lab`'s own pattern shape.
      File.write(File.join(src, 'clab-notes.md'), "x\n")
      Dir.mktmpdir('bgp4r-lab') do |tmp|
        dir = File.join(tmp, 'lab')
        BGP::Capture::CLI.copy_lab(src, dir)
        assert_equal(%w{.gitignore clab-notes.md compose.yml keep keep/old.yml
                        runs runs/deep runs/deep/b.yml},
                     entries(dir))
      end
    end
  end

  def test_the_real_gitignore_of_bgp4r_lab_keeps_its_directories_out
    # **The one real `.gitignore` in the tree, and the reason `copy_lab`
    # is not ospfv2's basename `fnmatch`.** `bgp4r-lab`'s carries
    # `recordings/` and `clab-*/`, which a basename match never fires
    # on, so a lab somebody had deployed in the template folder would
    # have had containerlab's own working directory copied into every
    # new lab made from it. This reads that file verbatim rather than a
    # paraphrase of it, by copying the real folder and then writing
    # into the copy what its own comment says the patterns are about.
    src0 = File.join(topologies_dir, 'bgp4r-lab')
    omit 'bgp4r-lab has no .gitignore any more' unless
      File.file?(File.join(src0, '.gitignore'))
    Dir.mktmpdir('bgp4r-lab-src') do |t|
      src = File.join(t, 'src')
      BGP::Capture::CLI.copy_lab(src0, src)
      Dir.mkdir(File.join(src, 'clab-bgp4r-lab'))
      File.write(File.join(src, 'clab-bgp4r-lab', 'topology-data.json'), "{}\n")
      Dir.mkdir(File.join(src, 'recordings'))
      File.write(File.join(src, 'recordings', 'run.pcap'), "x\n")
      File.write(File.join(src, 'rtr', 'bgp4rd.yml.sav'), "old\n")
      File.write(File.join(src, '.frr.conf.bak'), "old\n")
      Dir.mktmpdir('bgp4r-lab') do |tmp|
        dir = File.join(tmp, 'lab')
        BGP::Capture::CLI.copy_lab(src, dir)
        got = entries(dir)
        assert_equal([], got.grep(/\Aclab-/), 'containerlab working files came across')
        assert_equal([], got.grep(/\Arecordings/), 'recordings came across')
        assert_equal([], got.grep(/\.sav\z|\.bak\z/), 'router backups came across')
        # And the folder itself still arrived, or the assertions above
        # would pass against a copy of nothing.
        assert(got.include?('bgp4r-lab.clab.yml'), 'the topology file did not')
        assert(got.include?('rtr/bgp4rd.yml'), 'a nested config did not')
        assert(got.size > 10, "only #{got.size} entries came across")
      end
    end
  end

  def test_the_copy_is_a_git_repository_with_one_commit
    omit 'git is not installed here' unless git?
    lab_new do |dir, status|
      assert_equal(0, status)
      assert(File.directory?(File.join(dir, '.git')), 'the copy is not a repository')
      count = `git -C #{dir} rev-list --count HEAD`.strip
      assert_equal('1', count)
      subject = `git -C #{dir} log -1 --format=%s`.strip
      assert_equal('Lab created from bgp4r lab/topologies/two-speakers', subject)
      # The commit holds the lab and not an empty tree, which is the
      # half `git init` alone would satisfy.
      tracked = `git -C #{dir} ls-files`.split("\n").sort
      assert_equal(%w{compose.yml r1.yml r2.yml}, tracked)
      assert_match(/git: repository created with a first commit/, @out.string)
    end
  end

  def test_no_git_copies_and_leaves_no_repository
    lab_new('--no-git') do |dir, status|
      assert_equal(0, status)
      assert(File.file?(File.join(dir, 'compose.yml')), 'the copy did not happen')
      assert(!File.exist?(File.join(dir, '.git')), '--no-git still made a repository')
      assert_no_match(/^git:/, @out.string)
    end
  end

  def test_an_unknown_topology_lists_what_was_found
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      assert_equal(1, @cli.lab(['new', File.join(tmp, 'lab'), 'nonesuch']))
    end
    assert_match(/no topology nonesuch/, @out.string)
    # The list is what was found and not a list written down anywhere,
    # so every real folder has to be in it.
    BGP::Capture::CLI.topologies.each do |n|
      assert_match(/\b#{Regexp.escape(n)}\b/, @out.string, "#{n} is not in the refusal")
    end
  end

  def test_lab_new_with_no_folder_prints_the_usage_and_fails
    assert_equal(1, @cli.lab(['new']))
    assert_match(/Usage: bgp4r lab new DIR/, @out.string)
    # The usage lists what was found too, for the same reason.
    BGP::Capture::CLI.topologies.each do |n|
      assert_match(/^  #{Regexp.escape(n)}$/, @out.string, "#{n} is not in the usage")
    end
  end

  def test_lab_without_new_prints_the_usage_and_fails
    assert_equal(1, @cli.lab([]))
    assert_match(/Usage: bgp4r lab new DIR/, @out.string)
  end

  def test_lab_is_reached_through_the_dispatch
    # Without this the one arm of the case that matters is never taken,
    # which is what `test_capture_is_reached_through_the_dispatch` says
    # about capture.
    assert_equal(1, @cli.start(['lab', 'new']))
    assert_match(/Usage: bgp4r lab new DIR/, @out.string)
  end

  def test_a_destination_that_exists_and_is_not_empty_is_refused
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      File.write(File.join(tmp, 'mine.yml'), "k: v\n")
      assert_equal(1, @cli.lab(['new', tmp]))
      assert_match(/exists and is not empty/, @out.string)
      assert(!File.exist?(File.join(tmp, 'compose.yml')), 'it copied anyway')
    end
  end

  def test_an_empty_destination_that_exists_is_accepted
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      assert_equal(0, @cli.lab(['new', tmp, 'two-speakers', '--no-git']))
      assert(File.file?(File.join(tmp, 'r1.yml')))
    end
  end

  def test_an_unknown_flag_prints_the_usage_and_fails
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      assert_equal(1, @cli.lab(['new', File.join(tmp, 'lab'), '--nope']))
      assert_match(/invalid option: --nope/, @out.string)
      assert_match(/Usage: bgp4r lab new DIR/, @out.string)
    end
  end

  def test_a_folder_that_cannot_be_made_is_a_message_and_not_a_backtrace
    # The one thing a caller gets wrong that nothing above catches: a
    # destination whose parent is not a directory, or is not writable.
    # A file in the path is the shape that reproduces everywhere,
    # including as root, where an unwritable directory does not.
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      blocker = File.join(tmp, 'afile')
      File.write(blocker, "not a directory\n")
      assert_equal(1, @cli.lab(['new', File.join(blocker, 'lab')]))
      assert_match(/cannot make the lab folder/, @out.string)
    end
  end

  def test_a_topology_with_nothing_in_it_degrades_to_messages
    # Two of the "say so rather than fail" paths at once, and the only
    # source that reaches either: an empty folder gives `git commit`
    # nothing to commit, so the init succeeds and the commit does not,
    # and it holds neither a *.clab.yml nor a compose.yml, so there is
    # nothing truthful to say about starting it. **The status is still
    # 0**, because the copy is what was asked for and it happened.
    Dir.mktmpdir('bgp4r-lab-root') do |root|
      Dir.mkdir(File.join(root, 'empty'))
      Dir.mktmpdir('bgp4r-lab') do |tmp|
        dir = File.join(tmp, 'lab')
        assert_equal(0, @cli.lab(['new', dir, 'empty'], root))
        assert(File.directory?(dir), 'the folder was not made')
        assert_match(/holds neither a \*\.clab\.yml nor a compose\.yml/, @out.string)
        if git?
          assert_match(/the first commit failed/, @out.string)
          assert(File.directory?(File.join(dir, '.git')),
                 'the repository was not created either')
        end
      end
    end
  end

  def test_a_missing_topologies_folder_is_a_message_and_not_a_crash
    # Running as an installed gem the topologies are shipped, since
    # `s.files` is `git ls-files` and all sixteen are tracked. This is
    # the case where something has gone wrong with that anyway: it must
    # name the folder it looked in rather than raise.
    Dir.mktmpdir('bgp4r-lab') do |tmp|
      gone = File.join(tmp, 'no-such-topologies')
      assert_equal(1, @cli.lab(['new', File.join(tmp, 'lab')], gone))
      assert_match(/no lab topologies here/, @out.string)
      assert_match(/#{Regexp.escape(gone)}/, @out.string)
    end
  end

  def test_a_compose_topology_says_how_to_start_it
    # Every Compose topology here builds from the bgp4r checkout with a
    # context three directories up, so the message has to say the copy
    # cannot build it where it landed.
    lab_new('two-speakers', '--no-git') do |dir, status|
      assert_equal(0, status)
      assert_match(/is a Compose topology/, @out.string)
      assert_match(/bgp4r-speaker/, @out.string)
      assert_match(/docker compose up -d/, @out.string)
      assert_no_match(/containerlab/, @out.string)
    end
  end

  def test_the_image_to_build_is_read_out_of_the_compose_file
    # Not every topology builds the same image: `fault-matrix` builds
    # `bgp4r-conformance`, so a message naming one constant would be
    # wrong for it. And the GoBGP image is pulled, so it must not be
    # named as something to build.
    assert_equal(%w{bgp4r-speaker},
                 BGP::Capture::CLI.local_images(
                   File.join(topologies_dir, 'two-speakers', 'compose.yml')))
    assert_equal(%w{bgp4r-conformance},
                 BGP::Capture::CLI.local_images(
                   File.join(topologies_dir, 'fault-matrix', 'compose.yml')))
    assert_equal(%w{bgp4r-speaker},
                 BGP::Capture::CLI.local_images(
                   File.join(topologies_dir, 'add-path', 'compose.yml')))
  end

  def test_a_containerlab_topology_says_how_to_start_it
    # Which kind a topology is comes from its own files and not from a
    # list, which is what let `bgp4r-lab` take this arm with no change to
    # cli.rb: this test was written against a fixture folder because no
    # `*.clab.yml` was in the tree, and it asserts against the real one
    # now that there is.
    lab_new('bgp4r-lab', '--no-git') do |_, status|
      assert_equal(0, status)
      assert_match(/is a containerlab topology/, @out.string)
      assert_match(/containerlab deploy -t bgp4r-lab\.clab\.yml/, @out.string)
      assert_match(/containerlab destroy -t bgp4r-lab\.clab\.yml/, @out.string)
      assert_no_match(/is a Compose topology/, @out.string)
      assert_no_match(/docker compose/, @out.string)
    end
  end

  def test_the_clab_file_is_found_whatever_it_is_called
    # The real folder names its topology file after itself, so the
    # assertion above would pass against a message that printed the
    # topology's name rather than the file it found. A fixture whose
    # two do not match is what tells them apart.
    Dir.mktmpdir('bgp4r-lab-root') do |root|
      src = File.join(root, 'six-nodes')
      Dir.mkdir(src)
      File.write(File.join(src, 'ring.clab.yml'), "name: ring\n")
      Dir.mktmpdir('bgp4r-lab') do |tmp|
        dir = File.join(tmp, 'lab')
        assert_equal(0, @cli.lab(['new', dir, 'six-nodes', '--no-git'], root))
        assert_match(/containerlab deploy -t ring\.clab\.yml/, @out.string)
      end
    end
  end

  # `add-path` is the one folder with a README and the other three have
  # none, so this is two tests rather than one assertion: a message that
  # always mentioned a README would be wrong three times out of four,
  # and one that never did would be wrong for the fourth.

  def test_a_readme_is_mentioned_when_the_topology_has_one
    lab_new('add-path', '--no-git') { |_, status| assert_equal(0, status) }
    assert_match(%r{/README\.md says what it shows}, @out.string)
  end

  def test_no_readme_is_mentioned_when_the_topology_has_none
    lab_new('two-speakers', '--no-git') { |_, status| assert_equal(0, status) }
    assert_no_match(/README/, @out.string)
  end

  def test_every_line_is_one_json_object
    # Newline delimited JSON, which is the contract: a reader takes a
    # line at a time and never buffers to a document.
    _, lines = run_capture([frame(keepalive + open_msg)])
    assert_equal(3, lines.size)
    assert(lines.all? { |l| l.is_a?(Hash) and l.keys.size == 1 })
  end

end
