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
require 'tmpdir'
require 'json'
require 'bgp4r'
require 'bgp/capture/cli'
require 'test/unit/capture/capture_fixtures'

# The AS number size of a captured UPDATE. RFC 6793 section 3: a speaker
# puts 4-octet AS numbers in AS_PATH and AGGREGATOR when both OPENs of
# the session carried the 4-octet AS capability, and 2-octet ones
# otherwise. The UPDATE itself does not say which, so the capture has to
# know the session.
#
# Before this, every UPDATE was read with 2-octet AS numbers. On a
# session between two speakers of this century, AS 65010 in a 4-octet
# AS_PATH read as an unknown segment type, the capture said "the sender
# got this wrong", and the message did not decode. Found on 2026-11-18
# by capturing bgp4rd and bgp4r-sim on loopback.
class Capture_AS4_Test < Test::Unit::TestCase

  include CaptureFixtures
  include BGP

  def setup
    @out = StringIO.new
    @cli = BGP::Capture::CLI.new(@out, @out)
  end

  def run_capture(frames)
    Dir.mktmpdir('bgp4r-capture') do |dir|
      path = File.join(dir, 'c.pcap')
      File.open(path, 'wb') { |f| f.write(pcap(frames)) }
      @cli.capture(['-r', path])
    end
    @out.string.each_line.collect { |l| JSON.parse(l)['packet'] }.compact
  end

  def open4(as, id)
    Open.new(4, as, 90, id, OPT_PARM::CAP::As4.new(as)).encode
  end

  def open2(as, id)
    Open.new(4, as, 90, id).encode
  end

  def update
    Update.new(Path_attribute.new(Origin.new(0), As_path.new(65010),
                                  Next_hop.new('10.0.0.2')),
               Nlri.new('192.0.2.0/24'))
  end

  # The client's side of the connection, and the server's.
  A = { :src => '10.0.0.2', :dst => '10.0.0.1', :sport => 51_234, :dport => 179 }
  B = { :src => '10.0.0.1', :dst => '10.0.0.2', :sport => 179, :dport => 51_234 }

  def last_update(packets)
    packets.reverse.find { |p| p['summary'].start_with?('UPDATE') }
  end

  def test_both_opens_with_the_capability_read_4_octet_as_numbers
    p = last_update(run_capture([frame(open4(65010, '10.0.0.2'), **A),
                                 frame(open4(65000, '10.0.0.1'), **B),
                                 frame(update.encode4, **A.merge(:seq => 100))]))
    assert_equal([], p['errors'])
    assert_match(/65010/, p['decoded'])
    # The printed message is the one captured, not a 2-octet copy of it.
    assert_match(/\AUpdate Message \(2\), 4 bytes AS, length: #{update.encode4.bytesize}\b/, p['decoded'])
    assert_equal(4, p['as_octets'])
    assert_equal('open', p['as_octets_from'])
  end

  def test_one_open_without_the_capability_reads_2_octet_as_numbers
    p = last_update(run_capture([frame(open4(65010, '10.0.0.2'), **A),
                                 frame(open2(65000, '10.0.0.1'), **B),
                                 frame(update.encode, **A.merge(:seq => 100))]))
    assert_equal([], p['errors'])
    assert_equal(2, p['as_octets'])
    assert_equal('open', p['as_octets_from'])
  end

  def test_the_session_holds_for_the_other_direction_too
    p = last_update(run_capture([frame(open4(65010, '10.0.0.2'), **A),
                                 frame(open4(65000, '10.0.0.1'), **B),
                                 frame(update.encode4, **B.merge(:seq => 100))]))
    assert_equal([], p['errors'])
    assert_equal('open', p['as_octets_from'])
  end

  # A capture started after the OPENs, which is how a console opens one
  # on a lab that is already up. Nothing on the wire says the size, so
  # the capture tries 4 octets, then 2, and says it guessed.
  def test_without_the_opens_a_4_octet_update_is_guessed_right
    p = last_update(run_capture([frame(update.encode4, **A)]))
    assert_equal([], p['errors'])
    assert_equal(4, p['as_octets'])
    assert_equal('guess', p['as_octets_from'])
  end

  def test_without_the_opens_a_2_octet_update_is_guessed_right
    p = last_update(run_capture([frame(update.encode, **A)]))
    assert_equal([], p['errors'])
    assert_equal(2, p['as_octets'])
    assert_equal('guess', p['as_octets_from'])
  end

  # A real fault is still reported: the guess takes the reading with
  # fewer findings, not one with none.
  def test_a_malformed_as_path_is_still_reported_when_guessing
    bad = Update.new(Path_attribute.new(Origin.new(0), Fault.build(:as_path_segment),
                                        Next_hop.new('10.0.0.2')),
                     Nlri.new('192.0.2.0/24'))
    p = last_update(run_capture([frame(bad.encode4, **A)]))
    assert_match(/the sender got this wrong: attribute 2/, p['errors'].join)
  end

  def test_a_message_that_is_not_an_update_has_no_as_size
    p = run_capture([frame(open4(65010, '10.0.0.2'), **A)]).first
    assert_nil(p['as_octets'])
  end

  # The library entry point says the same, for a caller that knows the
  # session: true or false, or nil to guess.
  def test_dissect_message_takes_the_size
    r = BGP::Capture::Dissect.message(update.encode4, :as4byte => true).to_h
    assert_equal([[], 4, 'session'], [r[:errors], r[:as_octets], r[:as_octets_from]])
    r = BGP::Capture::Dissect.message(update.encode4, :as4byte => false).to_h
    assert_match(/the sender got this wrong/, r[:errors].join)
  end

end
