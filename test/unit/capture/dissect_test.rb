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

# Every expectation here is this reader's own arithmetic from the RFC
# figures, since RFC 4271 carries no worked example and no hex; see the
# header of capture_fixtures.rb. Where the library and an expectation
# here disagree, doubt the expectation first.

require 'test/unit'
require 'bgp4r'
require 'bgp/capture/dissect'
require 'test/unit/capture/capture_fixtures'

class Capture_Dissect_Test < Test::Unit::TestCase

  include CaptureFixtures

  D = BGP::Capture::Dissect

  # The field at a path of names, so a test names what it is about rather
  # than indexing into a tree.
  def at(result, *names)
    fields = result.fields
    f = nil
    names.each do |n|
      f = fields.find { |x| x.name == n }
      flunk("no field named #{n.inspect} among #{fields.collect { |x| x.name }.inspect}") unless f
      fields = f.children || []
    end
    f
  end

  # Every octet of a message belongs to a field, reserved octets and bits
  # included, which is the rule a decoder pane rests on: it lights up the
  # field of a byte and the bytes of a field. So the fields at each level
  # must tile their parent's extent exactly, with no gap and no overlap,
  # and the top level must tile the message.
  #
  # **A bit field is the one exception and it has to be stated, not
  # waved at**: the children of a bit field all claim the same octet and
  # differ by their mask, so there they tile the octet's *bits* instead.
  # A first draft of this helper asserted one leaf per octet and failed
  # on the attribute flags, which is a decoder shape and not a defect.
  def assert_every_octet_covered(octets)
    r = D.message(octets)
    assert_tiles(r.fields, 0, octets.bytesize, 'the message')
    r.fields.each { |f| assert_children_tile(f) }
  end

  def assert_tiles(fields, from, to, what)
    at = from
    fields.each do |f|
      flunk("#{f.name} starts at #{f.offset}, #{at} expected inside #{what}") unless f.offset == at
      at += f.length
    end
    assert_equal(to, at, "the fields of #{what} end at #{at} and it ends at #{to}")
  end

  def assert_children_tile(f)
    kids = f.children
    return if kids.nil? or kids.empty?
    if kids.first.mask
      # A bit field: every child is the same octet under a mask, and the
      # masks tile it with no overlap.
      kids.each do |c|
        assert_equal([f.offset, f.length], [c.offset, c.length], "#{c.name} is not #{f.name}'s octet")
        assert_not_nil(c.mask, "#{c.name} sits beside masked fields with no mask")
      end
      full = f.length == 1 ? 0xff : 0xffff
      assert_equal(full, kids.collect { |c| c.mask }.inject(0) { |a, m| a | m },
                   "the masks of #{f.name} do not cover its octets")
      kids.collect { |c| c.mask }.combination(2).each do |a, b|
        assert_equal(0, a & b, "two masks of #{f.name} overlap")
      end
    else
      assert_tiles(kids, f.offset, f.offset + f.length, f.name)
      kids.each { |c| assert_children_tile(c) }
    end
  end

  # ---- the header, RFC 4271 section 4.1

  def test_the_header_is_three_fields_over_nineteen_octets
    r = D.message(keepalive)
    h = at(r, 'BGP header')
    assert_equal(0, h.offset)
    assert_equal(19, h.length)
    assert_equal(%w{marker length type}, h.children.collect { |c| c.name })
    assert_equal([0, 16], [at(r, 'BGP header', 'marker').offset,
                           at(r, 'BGP header', 'length').offset])
    assert_equal(18, at(r, 'BGP header', 'type').offset)
  end

  def test_a_keepalive_is_the_header_and_nothing_else
    r = D.message(keepalive)
    assert_equal('KEEPALIVE', r.summary)
    assert_equal(19, r.length)
    assert_equal([], r.errors)
    assert_every_octet_covered(keepalive)
  end

  def test_an_all_ones_marker_is_said_to_be_so
    assert_equal('all ones', at(D.message(keepalive), 'BGP header', 'marker').show)
  end

  def test_a_marker_that_is_not_all_ones_is_reported_and_still_read
    bad = ("\x00".b * 16) + [19, 4].pack('nC')
    r = D.message(bad)
    assert_match(/Marker is not all ones/, r.errors.join(' '))
    assert_equal('not all ones', at(r, 'BGP header', 'marker').show)
    assert_equal('KEEPALIVE', r.summary)
  end

  def test_a_length_field_that_disagrees_with_the_octets_is_reported
    r = D.message(msg(BGP::Message::KEEPALIVE, '', 25))
    assert_match(/says 25 and 19 octets were framed/, r.errors.join(' '))
  end

  def test_a_length_below_the_minimum_is_reported
    r = D.message(msg(BGP::Message::KEEPALIVE, '', 3))
    assert_match(/below the 19 octet minimum/, r.errors.join(' '))
  end

  def test_a_length_above_the_maximum_is_reported
    r = D.message(msg(BGP::Message::KEEPALIVE, '', 5000))
    assert_match(/above the 4096 octet maximum/, r.errors.join(' '))
  end

  def test_octets_too_few_for_a_header_are_kept_and_reported
    short = ("\xff".b * 10)
    r = D.message(short)
    assert_equal('truncated BGP message', r.summary)
    assert_match(/needs 19 octets at 0/, r.errors.join(' '))
    assert_equal('a0a'.sub('a0a', short.unpack('H*')[0]), at(r, 'data').value)
    assert_every_octet_covered(short)
  end

  # ---- a type bgp4r does not decode

  def test_an_unknown_message_type_is_kept_with_its_hex_and_an_error
    # The keep-what-you-cannot-read rule. A capture tool that drops what
    # it cannot parse is useless for the job this library exists to do,
    # so the header is still read and the body still handed over.
    m = msg(99, 'abcd')
    r = D.message(m)
    assert_equal('type 99', r.summary)
    assert_equal(99, at(r, 'BGP header', 'type').value)
    assert_equal('61626364', at(r, 'body').value)
    assert_match(/message type 99 is not one bgp4r decodes/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_type_bgp4r_cannot_decode_is_named_as_bgp4rs_gap_and_not_the_senders_fault
    # Conventions keep these two apart inside the library and the
    # distinction matters as much in a capture: calling bgp4r's own
    # missing code a protocol error gives a confident wrong verdict about
    # a correct router.
    errs = D.message(msg(99, 'abcd')).errors
    assert(errs.any? { |e| e =~ /\Abgp4r could not decode this message/ },
           "no entry naming bgp4r's own gap in #{errs.inspect}")
    assert(errs.none? { |e| e =~ /the sender got this wrong/ }, errs.inspect)
  end

  # ---- OPEN, RFC 4271 section 4.2

  def test_an_open_with_no_parameters
    m = open_msg(65001, 30, '10.0.0.1')
    r = D.message(m)
    assert_equal('OPEN AS 65001 holdtime 30s id 10.0.0.1', r.summary)
    assert_equal([], r.errors)
    assert_equal(4, at(r, 'OPEN', 'version').value)
    assert_equal(65001, at(r, 'OPEN', 'my autonomous system').value)
    assert_equal(30, at(r, 'OPEN', 'hold time').value)
    assert_equal('10.0.0.1', at(r, 'OPEN', 'BGP identifier').value)
    assert_equal(0, at(r, 'OPEN', 'optional parameters length').value)
    assert_every_octet_covered(m)
  end

  def test_the_open_field_offsets_are_the_figures
    # Version at 19, My Autonomous System at 20, Hold Time at 22, BGP
    # Identifier at 24, Opt Parm Len at 28. A reader that got the figure
    # wrong by an octet shifts all of them.
    r = D.message(open_msg)
    assert_equal([19, 20, 22, 24, 28],
                 ['version', 'my autonomous system', 'hold time',
                  'BGP identifier', 'optional parameters length'].collect { |n| at(r, 'OPEN', n).offset })
    assert_equal([1, 2, 2, 4, 1],
                 ['version', 'my autonomous system', 'hold time',
                  'BGP identifier', 'optional parameters length'].collect { |n| at(r, 'OPEN', n).length })
  end

  def test_an_open_carrying_a_capabilities_parameter
    # RFC 5492 section 4: one Capabilities parameter, type 2, carrying a
    # sequence of capabilities, each a 1 octet code, a 1 octet length and
    # the value. Here MBGP (code 1) and 4 octet AS (code 65).
    mbgp = [1, 4, 0, 1, 0, 1].pack('C6')
    as4  = [65, 4].pack('C2') + [65_536].pack('N')
    parm = [2, mbgp.bytesize + as4.bytesize].pack('C2') + mbgp + as4
    m = open_msg(23_456, 90, '10.0.0.2', parm)
    r = D.message(m)
    assert_equal([], r.errors)
    assert_equal('Capabilities', at(r, 'optional parameter').show)
    caps = at(r, 'optional parameter', 'capabilities').children
    assert_equal(2, caps.size)
    assert_equal(['MBGP', 'AS4'], caps.collect { |c| c.show })
    assert_equal([1, 65], caps.collect { |c| c.children.first.value })
    assert_every_octet_covered(m)
  end

  def test_the_capability_names_come_from_the_librarys_own_constants
    # Discovered rather than written down here, so a capability the
    # library learns is named the same day. CAP_ADD_PATH is 69.
    assert_equal('ADD PATH', D::CAPABILITIES[BGP::OPT_PARM::CAP_ADD_PATH])
    assert_equal('ROLE', D::CAPABILITIES[BGP::OPT_PARM::CAP_ROLE])
    assert_nil(D::CAPABILITIES[200])
  end

  def test_a_capability_whose_length_overruns_its_parameter_is_clamped_and_reported
    cap = [1, 40].pack('C2') + 'ab'
    parm = [2, cap.bytesize].pack('C2') + cap
    r = D.message(open_msg(1, 1, '0.0.0.0', parm))
    assert_match(/capability at \d+ says 40 octets and 2 are left/, r.errors.join(' '))
    assert_every_octet_covered(open_msg(1, 1, '0.0.0.0', parm))
  end

  def test_an_optional_parameter_whose_length_overruns_the_message_is_clamped_and_reported
    # The length octet says 90 and 2 octets followed it.
    body = [4, 1, 1].pack('Cnn') + "\x00\x00\x00\x00" + [4].pack('C') + [7, 90].pack('C2') + 'ab'
    m = msg(BGP::Message::OPEN, body)
    r = D.message(m)
    assert_match(/optional parameter at \d+ says 90 octets and 2 are left/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_an_optional_parameters_length_that_disagrees_is_reported
    # Opt Parm Len says 4 and nothing followed it.
    body = [4, 1, 1].pack('Cnn') + "\x00\x00\x00\x00" + [4].pack('C')
    r = D.message(msg(BGP::Message::OPEN, body))
    assert_match(/Optional Parameters Length says 4 and 0 octets followed it/, r.errors.join(' '))
  end

  def test_the_extended_open_of_rfc_9072_is_read_by_its_type_octet
    # RFC 9072 section 2: a Non-Ext OP Type of 255 "is the indication
    # that the extended format is in use", and the length before it "MUST
    # be ignored on receipt once the use of the extended format is
    # determined positively". So the octet at 29 decides and the one at
    # 28 is read as whatever arrived; here it is 7, not the recommended
    # 255, and the message is still read extended.
    parm = [2, 2].pack('Cn') + [1, 0].pack('C2')
    body = [4, 65_001, 30].pack('Cnn') + "\x0a\x00\x00\x01" +
           [7, 255, parm.bytesize].pack('CCn') + parm
    m = msg(BGP::Message::OPEN, body)
    r = D.message(m)
    assert_equal([], r.errors)
    assert_equal(7, at(r, 'OPEN', 'non-ext optional parameters length').value)
    assert_equal(255, at(r, 'OPEN', 'non-ext optional parameters type').value)
    # Two octets here, where the non extended form has one.
    assert_equal(2, at(r, 'OPEN', 'optional parameters length').length)
    assert_equal(30, at(r, 'OPEN', 'optional parameters length').offset)
    # And the parameter's own length is two octets as well.
    assert_equal(2, at(r, 'optional parameter', 'parameter length').length)
    assert_every_octet_covered(m)
  end

  def test_an_optional_parameter_header_that_does_not_fit_is_kept_as_data
    # One octet after the Optional Parameters Length, which is not a
    # parameter header: RFC 4271 section 4.2 gives one a type octet and a
    # length octet.
    body = [4, 1, 1].pack('Cnn') + "\x00\x00\x00\x00" + [1].pack('C') + "\x02"
    m = msg(BGP::Message::OPEN, body)
    r = D.message(m)
    assert_match(/optional parameter header: needs 2 octets/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_capability_header_that_does_not_fit_in_its_parameter_is_kept_as_data
    # One octet inside the Capabilities parameter, where RFC 5492
    # section 4 wants a code octet and a length octet.
    parm = [2, 1].pack('C2') + "\x01"
    m = open_msg(1, 1, '0.0.0.0', parm)
    r = D.message(m)
    assert_match(/capability header at \d+ runs past the parameter/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_an_open_too_short_for_its_fixed_fields_keeps_its_octets
    m = msg(BGP::Message::OPEN, 'abc')
    r = D.message(m)
    assert_match(/OPEN body: needs 10 octets/, r.errors.join(' '))
    assert_equal('616263', at(r, 'body').value)
    assert_every_octet_covered(m)
  end

  # ---- UPDATE, RFC 4271 section 4.3

  def test_an_update_with_one_attribute_and_one_prefix
    a = attr(0x40, 1, "\x00")                       # ORIGIN igp
    m = update_msg('', a, prefix('192.0.2.0/24'))
    r = D.message(m)
    assert_equal('UPDATE 1 attribute 1 nlri 0 withdrawn', r.summary)
    assert_equal([], r.errors)
    assert_equal(0, at(r, 'withdrawn routes length').value)
    assert_equal(a.bytesize, at(r, 'total path attribute length').value)
    assert_equal('origin', at(r, 'path attributes', 'path attribute').show)
    assert_equal('192.0.2.0/24',
                 at(r, 'network layer reachability information', 'prefix').value)
    assert_every_octet_covered(m)
  end

  def test_the_path_attribute_names_come_from_the_librarys_own_registry
    # So an attribute the library learns is named by this dissector the
    # same day. 2 is AS_PATH and 99 is registered to nothing.
    r = D.message(update_msg('', attr(0x40, 2, '') + attr(0xc0, 99, 'x'), ''))
    assert_equal(['as_path', 'type 99'],
                 at(r, 'path attributes').children.collect { |c| c.show })
  end

  def test_the_attribute_flags_are_one_field_per_bit
    # RFC 4271 section 4.3: Optional 0x80, Transitive 0x40, Partial 0x20,
    # Extended Length 0x10, and "the lower four bits ... are unused".
    # Asserted against the masks the RFC gives and not against a round
    # trip, which passes whenever the reader and the writer share a
    # reversal.
    r = D.message(update_msg('', attr(0xc0, 16, 'ab'), ''))
    f = at(r, 'path attributes', 'path attribute', 'flags')
    assert_equal(0xc0, f.value)
    assert_equal('Optional Transitive', f.show)
    got = f.children.inject({}) { |h, c| h[c.name] = [c.mask, c.value] ; h }
    assert_equal([0x80, 1], got['Optional'])
    assert_equal([0x40, 1], got['Transitive'])
    assert_equal([0x20, 0], got['Partial'])
    assert_equal([0x10, 0], got['Extended Length'])
    assert_equal([0x0f, 0], got['unused'])
  end

  def test_every_bit_of_the_flags_octet_belongs_to_exactly_one_field
    # The tiling check: the masks must cover the octet and must not
    # overlap. Coverage alone proves nothing, since OR is idempotent.
    masks = D::ATTR_FLAGS.keys + [0x0f]
    assert_equal(0xff, masks.inject(0) { |a, m| a | m })
    masks.combination(2).each { |a, b| assert_equal(0, a & b, "0x%02x and 0x%02x overlap" % [a, b]) }
  end

  def test_the_extended_length_flag_widens_the_length_field
    # Flag 0x10 set, so the attribute's length is two octets and the
    # value starts one octet later.
    one = D.message(update_msg('', attr(0x40, 1, 'a'), ''))
    two = D.message(update_msg('', attr(0x50, 1, 'a'), ''))
    assert_equal(1, at(one, 'path attributes', 'path attribute', 'length').length)
    assert_equal(2, at(two, 'path attributes', 'path attribute', 'length').length)
    assert_equal(1, at(one, 'path attributes', 'path attribute', 'length').value)
    assert_equal(1, at(two, 'path attributes', 'path attribute', 'length').value)
    assert_every_octet_covered(update_msg('', attr(0x50, 1, 'a'), ''))
  end

  def test_withdrawn_routes_and_nlri_are_both_read
    w = prefix('10.0.0.0/8') + prefix('172.16.0.0/12')
    n = prefix('192.0.2.0/24')
    m = update_msg(w, '', n)
    r = D.message(m)
    assert_equal('UPDATE 0 attributes 1 nlri 2 withdrawn', r.summary)
    assert_equal(['10.0.0.0/8', '172.16.0.0/12'],
                 at(r, 'withdrawn routes').children.collect { |c| c.value })
    assert_equal(['192.0.2.0/24'],
                 at(r, 'network layer reachability information').children.collect { |c| c.value })
    assert_every_octet_covered(m)
  end

  def test_a_prefix_is_packed_to_the_minimum_octets_for_its_length
    # RFC 4271 section 4.3: "the minimum number of octets necessary to
    # contain the value", which is (bits + 7) / 8. A /8 is one octet and
    # a /0 is none.
    m = update_msg(prefix('10.0.0.0/8') + prefix('0.0.0.0/0'), '', '')
    r = D.message(m)
    kids = at(r, 'withdrawn routes').children
    assert_equal([2, 1], kids.collect { |c| c.length })
    assert_equal(['10.0.0.0/8', '0.0.0.0/0'], kids.collect { |c| c.value })
    assert_every_octet_covered(m)
  end

  def test_an_end_of_rib_marker_says_so
    # RFC 4724 section 2: no NLRI and no withdrawn routes.
    assert_equal('UPDATE End-of-RIB', D.message(update_msg).summary)
  end

  def test_a_withdrawn_routes_length_that_overruns_is_clamped_and_reported
    m = msg(BGP::Message::UPDATE, [40].pack('n') + prefix('10.0.0.0/8'))
    r = D.message(m)
    assert_match(/Withdrawn Routes Length says 40 and 2 octets are left/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_total_path_attribute_length_that_overruns_is_clamped_and_reported
    m = msg(BGP::Message::UPDATE, [0].pack('n') + [50].pack('n') + attr(0x40, 1, "\x00"))
    r = D.message(m)
    assert_match(/Total Path Attribute Length says 50 and 4 octets are left/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_path_attribute_length_that_overruns_is_clamped_and_reported
    m = update_msg('', [0x40, 1, 30].pack('CCC') + "\x00", '')
    r = D.message(m)
    assert_match(/path attribute at \d+ says 30 octets and 1 are left/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_prefix_whose_length_wants_more_octets_than_are_left_is_kept_as_data
    m = update_msg('', '', [24].pack('C') + "\xc0\x00")
    r = D.message(m)
    assert_match(/a prefix at \d+ of 24 bits needs 3 octets and 2 are left/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_truncated_path_attribute_header_is_kept_as_data
    m = update_msg('', [0x40, 1].pack('C2'), '')
    r = D.message(m)
    assert_match(/path attribute header at \d+ runs past/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_a_path_attribute_whose_length_field_itself_runs_past_is_kept_as_data
    # The Extended Length flag is set, so the length is two octets, and
    # only one is left. A reader that read it anyway would unpack nil.
    m = update_msg('', [0x50, 1, 0].pack('CCC'), '')
    r = D.message(m)
    assert_match(/path attribute length at \d+ runs past the attributes/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_an_update_whose_body_cannot_hold_the_first_length_keeps_its_octet
    m = msg(BGP::Message::UPDATE, 'a')
    r = D.message(m)
    assert_match(/UPDATE body: needs 2 octets/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  def test_an_update_that_ends_before_its_attribute_length_keeps_what_is_left
    m = msg(BGP::Message::UPDATE, [1].pack('n') + [8].pack('C'))
    r = D.message(m)
    assert_match(/total path attribute length: needs 2 octets/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  # ---- what validation.rb says about a received UPDATE

  def test_a_finding_from_validation_is_named_as_the_senders_fault
    # The library's own receive side checks reach the capture, which is
    # the thing bgp4r can say about an UPDATE that no other dissector
    # can. An attribute length that runs past the list is RFC 7606
    # section 4.
    r = D.message(update_msg('', [0x40, 1, 2].pack('CCC') + "\x00", ''))
    assert(r.errors.any? { |e| e =~ /\Athe sender got this wrong/ }, r.errors.inspect)
    assert_match(/RFC 7606/, r.errors.join(' '))
  end

  def test_an_attribute_bgp4r_cannot_decode_is_named_as_bgp4rs_gap
    # An MP_REACH in a family bgp4r does not decode becomes an
    # Attr::Gap in `undecoded`, which is #116's channel: valid octets
    # bgp4r has no code for are bgp4r's coverage and not the peer's
    # fault. SAFI 255 is **Reserved** by IANA, so nothing can ever be
    # assigned there and this example cannot expire, which is the choice
    # mp_reach_test.rb and path_attribute_test.rb settled on after
    # moving theirs three times.
    reach = [1, 255, 4].pack('nCC') + "\x0a\x00\x00\x01" + "\x00" + "\x01\x02\x03"
    m = update_msg('', attr(0x80, 14, reach), '')
    r = D.message(m)
    assert(r.errors.any? { |e| e =~ /\Abgp4r could not decode this: / }, r.errors.inspect)
    assert(r.errors.none? { |e| e =~ /the sender got this wrong/ }, r.errors.inspect)
    assert_every_octet_covered(m)
  end

  def test_a_clean_update_has_no_finding_at_all
    u = BGP::Update.new(BGP::Path_attribute.new(BGP::Origin.new(:igp),
                                                BGP::Next_hop.new('10.0.0.1'),
                                                BGP::As_path.new(65_001)),
                        BGP::Nlri.new('192.0.2.0/24'))
    r = D.message(u.encode)
    assert_equal([], r.errors)
    assert_equal('UPDATE 3 attributes 1 nlri 0 withdrawn', r.summary)
    assert_every_octet_covered(u.encode)
  end

  # ---- NOTIFICATION, RFC 4271 section 4.5

  def test_a_notification_names_its_code_and_subcode
    m = msg(BGP::Message::NOTIFICATION, [6, 2].pack('C2') + 'why')
    r = D.message(m)
    assert_equal('NOTIFICATION 6/2 Cease / Administrative Shutdown', r.summary)
    assert_equal(6, at(r, 'NOTIFICATION', 'error code').value)
    assert_equal(2, at(r, 'NOTIFICATION', 'error subcode').value)
    assert_equal('776879', at(r, 'NOTIFICATION', 'data').value)
    assert_every_octet_covered(m)
  end

  def test_a_notification_with_no_data
    m = msg(BGP::Message::NOTIFICATION, [4, 0].pack('C2'))
    r = D.message(m)
    assert_equal(21, r.length)
    assert_every_octet_covered(m)
  end

  def test_a_notification_too_short_for_its_two_codes_keeps_its_octet
    m = msg(BGP::Message::NOTIFICATION, "\x06")
    r = D.message(m)
    assert_match(/NOTIFICATION body: needs 2 octets/, r.errors.join(' '))
    assert_every_octet_covered(m)
  end

  # ---- KEEPALIVE, RFC 4271 section 4.4

  def test_a_keepalive_with_a_body_is_reported_and_its_octets_kept
    # "A KEEPALIVE message consists of only the message header and has a
    # length of 19 octets." bgp4r's own Keepalive.new ignores whatever
    # arrived, so without this the octets would vanish.
    m = msg(BGP::Message::KEEPALIVE, 'junk')
    r = D.message(m)
    assert_match(/carries 4 octets after its header/, r.errors.join(' '))
    assert_equal('6a756e6b', at(r, 'body').value)
    assert_every_octet_covered(m)
  end

  # ---- ROUTE-REFRESH, RFC 2918 section 3 and RFC 7313 section 3.2

  def test_a_route_refresh_reads_its_afi_subtype_and_safi
    m = msg(BGP::Message::ROUTE_REFRESH, [1, 0, 1].pack('nCC'))
    r = D.message(m)
    assert_equal('ROUTE-REFRESH IPv4/Unicast normal', r.summary)
    assert_equal([19, 21, 22], ['afi', 'message subtype', 'safi'].collect { |n|
      at(r, 'ROUTE-REFRESH', n).offset })
    assert_every_octet_covered(m)
  end

  def test_the_reserved_octet_is_the_message_subtype_of_rfc_7313
    r = D.message(msg(BGP::Message::ROUTE_REFRESH, [2, 2, 1].pack('nCC')))
    assert_equal('2 EoRR', at(r, 'ROUTE-REFRESH', 'message subtype').show)
    assert_equal('ROUTE-REFRESH IPv6/Unicast EoRR', r.summary)
  end

  def test_a_subtype_no_rfc_defines_is_still_read
    r = D.message(msg(BGP::Message::ROUTE_REFRESH, [1, 7, 1].pack('nCC')))
    assert_equal('7 unassigned', at(r, 'ROUTE-REFRESH', 'message subtype').show)
  end

  def test_the_orf_entries_of_a_route_refresh_are_kept_as_octets
    m = msg(BGP::Message::ROUTE_REFRESH, [1, 0, 1].pack('nCC') + 'orfbytes')
    r = D.message(m)
    assert_equal('6f7266627974657300'.sub('00', ''),
                 at(r, 'ROUTE-REFRESH', 'outbound route filters').value)
    assert_every_octet_covered(m)
  end

  # ---- the frame, down to the TCP payload

  def test_an_ethernet_frame_gives_the_four_tuple_and_the_payload
    seg = D.segment(frame(keepalive, :seq => 7))
    assert_equal('10.0.0.1', seg.src)
    assert_equal('10.0.0.2', seg.dst)
    assert_equal(179, seg.sport)
    assert_equal(51_234, seg.dport)
    assert_equal(7, seg.seq)
    assert_equal(keepalive.unpack('H*')[0], seg.payload.unpack('H*')[0])
    assert_equal([], seg.errors)
  end

  def test_the_payload_of_a_segment_is_binary
    # The payload is what the reassembly appends to its buffer, so its
    # encoding decides the buffer's. Asserted, not trusted.
    assert_equal(Encoding::BINARY, D.segment(frame(keepalive)).payload.encoding)
    # A bare ACK, which is the empty case where the encoding of a fresh
    # buffer shows and where String.new rather than +'' is the fix.
    assert_equal(Encoding::BINARY, D.segment(frame('')).payload.encoding)
  end

  def test_a_vlan_tagged_frame_is_read_past_the_tag
    seg = D.segment(frame(keepalive, :vlan => 100))
    assert_equal('10.0.0.1', seg.src)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_a_raw_ip_link_starts_at_the_ip_header
    seg = D.segment(frame(keepalive, :link => :ip), :link => :ip)
    assert_equal('10.0.0.1', seg.src)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_a_linux_cooked_link_is_read
    seg = D.segment(frame(keepalive, :link => :sll), :link => :sll)
    assert_equal('10.0.0.1', seg.src)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_an_ipv6_frame_gives_the_four_tuple_and_the_payload
    # Version 6, then Payload Length at 4, Next Header 6 at 6, Hop Limit,
    # then two 16 octet addresses. 40 octets.
    tcp = [179, 5000, 1, 0, 0x50, 0x18, 8192, 0, 0].pack('nnNNCCnnn')
    ip = [0x60_00_00_00, tcp.bytesize + keepalive.bytesize, 6, 64].pack('NnCC') +
         IPAddr.new('2001:db8::1').hton + IPAddr.new('2001:db8::2').hton
    eth = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') + [0x86dd].pack('n')
    seg = D.segment(eth + ip + tcp + keepalive)
    assert_equal('2001:db8::1', seg.src)
    assert_equal('2001:db8::2', seg.dst)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_a_frame_that_is_not_ip_says_so_and_has_no_payload
    eth = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') + [0x0806].pack('n')
    seg = D.segment(eth + ('x' * 20))
    assert_nil(seg.payload)
    assert_match(/ethertype 0x0806 is not IPv4 or IPv6/, seg.errors.join(' '))
  end

  def test_a_frame_that_is_not_tcp_says_so
    f = frame(keepalive)
    f.setbyte(14 + 9, 17)        # protocol 17, UDP
    seg = D.segment(f)
    assert_nil(seg.payload)
    assert_match(/IP protocol 17 is not TCP/, seg.errors.join(' '))
  end

  def test_an_ipv4_fragment_is_reported_rather_than_read_as_a_tcp_header
    # A non-zero Fragment Offset means there is no transport header in
    # this frame, so reading one would invent fields. IP level
    # reassembly is deliberately not done.
    f = frame(keepalive)
    f[14 + 6, 2] = [10].pack('n')
    seg = D.segment(f)
    assert_nil(seg.payload)
    assert_match(/IPv4 fragment at offset 80/, seg.errors.join(' '))
  end

  def test_ipv4_options_shift_the_tcp_header
    # IHL of 6 words, so 24 octets of header with 4 of options. A reader
    # that assumed 20 reads the options as the TCP ports.
    opts = "\x01\x01\x01\x00"
    tcp = [179, 5000, 1, 0, 0x50, 0x18, 8192, 0, 0].pack('nnNNCCnnn')
    ip = [0x46, 0, 24 + tcp.bytesize + 19, 0, 0, 64, 6, 0].pack('CCnnnCCn') +
         "\x0a\x00\x00\x01" + "\x0a\x00\x00\x02" + opts
    eth = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') + [0x0800].pack('n')
    seg = D.segment(eth + ip + tcp + keepalive)
    assert_equal(179, seg.sport)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_tcp_options_shift_the_payload
    # Data Offset of 8 words, so 32 octets of header with 12 of options.
    opts = "\x00" * 12
    tcp = [179, 5000, 1, 0, 0x80, 0x18, 8192, 0, 0].pack('nnNNCCnnn') + opts
    ip = [0x45, 0, 20 + tcp.bytesize + 19, 0, 0, 64, 6, 0].pack('CCnnnCCn') +
         "\x0a\x00\x00\x01" + "\x0a\x00\x00\x02"
    eth = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') + [0x0800].pack('n')
    seg = D.segment(eth + ip + tcp + keepalive)
    assert_equal(keepalive.unpack('H*')[0], seg.payload.unpack('H*')[0])
  end

  def test_a_tcp_segment_with_no_payload_gives_an_empty_one_and_not_nil
    # A bare ACK. It frames nothing and it is not an error.
    seg = D.segment(frame(''))
    assert_equal('', seg.payload)
    assert_equal([], seg.errors)
  end

  def test_the_payload_ends_where_the_ip_total_length_says
    # Ethernet padding after a short frame is not payload. A 19 octet
    # KEEPALIVE in a frame padded to 60 octets would otherwise come back
    # with the padding on the end.
    f = frame(keepalive) + ("\x00" * 7)
    seg = D.segment(f)
    assert_equal(19, seg.payload.bytesize)
  end

  def test_a_frame_cut_short_by_the_snaplen_gives_what_arrived
    # The Total Length says more than the capture holds, which is what a
    # snaplen does, so the payload is clamped to what is there.
    f = frame(keepalive)
    seg = D.segment(f[0, f.bytesize - 5])
    assert_equal(14, seg.payload.bytesize)
  end

  def test_an_ip_version_that_is_neither_four_nor_six_says_so_and_has_no_payload
    f = frame(keepalive)
    f.setbyte(14, 0x75)          # version 7
    seg = D.segment(f)
    assert_nil(seg.payload)
  end

  def test_an_ipv4_header_length_below_the_minimum_is_reported
    # An IHL of 4 words is 16 octets, which cannot hold the 20 the header
    # needs, so there is nothing behind it to read.
    f = frame(keepalive)
    f.setbyte(14, 0x44)
    seg = D.segment(f)
    assert_nil(seg.payload)
    assert_match(/IPv4 header length 16 is below the 20 octet minimum/, seg.errors.join(' '))
  end

  def test_a_tcp_data_offset_below_the_minimum_is_reported
    f = frame(keepalive)
    f.setbyte(14 + 20 + 12, 0x40)   # 4 words, 16 octets
    seg = D.segment(f)
    assert_nil(seg.payload)
    assert_match(/TCP data offset 16 is below the 20 octet minimum/, seg.errors.join(' '))
  end

  def test_an_ipv6_next_header_that_is_not_tcp_is_reported
    # An extension header chain is not walked: each header in it has its
    # own length rule, and a BGP session over one is not a case this tool
    # has met. So it is reported and skipped rather than guessed at.
    tcp = [179, 5000, 1, 0, 0x50, 0x18, 8192, 0, 0].pack('nnNNCCnnn')
    ip = [0x60_00_00_00, tcp.bytesize, 44, 64].pack('NnCC') +
         IPAddr.new('2001:db8::1').hton + IPAddr.new('2001:db8::2').hton
    eth = [2, 0, 0, 0, 0, 2].pack('C6') + [2, 0, 0, 0, 0, 1].pack('C6') + [0x86dd].pack('n')
    seg = D.segment(eth + ip + tcp)
    assert_nil(seg.payload)
    assert_match(/IPv6 next header 44 is not TCP/, seg.errors.join(' '))
  end

  def test_a_linux_cooked_frame_that_is_not_ip_is_reported
    f = frame(keepalive, :link => :sll)
    f[14, 2] = [0x0806].pack('n')
    seg = D.segment(f, :link => :sll)
    assert_nil(seg.payload)
    assert_match(/Linux cooked protocol 0x0806 is not IPv4 or IPv6/, seg.errors.join(' '))
  end

  def test_a_frame_too_short_for_its_headers_says_so
    assert_match(/Ethernet header/, D.segment('abc').errors.join(' '))
    assert_match(/IPv4 header/, D.segment(frame(keepalive)[0, 20]).errors.join(' '))
    assert_match(/TCP header/, D.segment(frame(keepalive)[0, 40]).errors.join(' '))
  end

  def test_an_unsupported_link_says_so
    assert_match(/link type .* is not supported/, D.segment('abc', :link => :fddi).errors.join(' '))
  end

  def test_the_link_map_is_the_one_ospfv2_reads
    # The two tools accept the same pcap files, which is the contract in
    # docs/routescope-labs.md section 4.
    assert_equal(:ethernet, D::LINKS[1])
    assert_equal(:ip, D::LINKS[101])
    assert_equal(:ip, D::LINKS[12])
    assert_equal(:sll, D::LINKS[113])
    assert_equal(:ip, D::LINKS[228])
  end

  # ---- the hash form a console reads

  def test_the_hash_leaves_out_what_is_not_set
    h = D.message(keepalive).to_h
    assert_equal(%w{summary length fields errors}, h.keys.collect { |k| k.to_s })
    marker = h[:fields].first[:children].first
    assert(!marker.has_key?(:mask), marker.inspect)
    assert(!marker.has_key?(:children), marker.inspect)
  end

  def test_a_bit_field_carries_its_mask_in_the_hash
    h = D.message(update_msg('', attr(0x80, 1, "\x00"), '')).to_h
    flags = h[:fields].find { |f| f[:name] == 'path attributes' }[:children]
                      .first[:children].first
    assert_equal('flags', flags[:name])
    assert_equal(0x80, flags[:children].first[:mask])
  end

end
