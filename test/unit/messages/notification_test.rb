#--
# Copyright 2008, 2009, 2010, 2026 Jean-Michel Esnault.
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
require 'bgp4r'

class Notification_Test < Test::Unit::TestCase
  include BGP
  # Value 0 of the error code registry and of five of the six subcode
  # registries. Every one of these read "Undefined" before, which is the
  # answer for a code point IANA has not named, and these are named.
  #
  # "Unspecific" for the Message Header, OPEN and UPDATE subcodes, which
  # IANA references to RFC Errata 4493; "Unspecified Error" for the Finite
  # State Machine subcodes, RFC 6608 section 3, which lists "0 -
  # Unspecified Error" above the three bgp4r already had; "Reserved" for
  # the error codes, for Cease, and for the ROUTE-REFRESH subcodes of RFC
  # 7313 section 6.
  def test_value_zero_is_named_in_every_registry_that_names_it
    assert_equal('Reserved', Notification.code_to_s(0))
    assert_equal('Unspecific', Notification.code_to_s(1, 0))
    assert_equal('Unspecific', Notification.code_to_s(2, 0))
    assert_equal('Unspecific', Notification.code_to_s(3, 0))
    assert_equal('Unspecified Error', Notification.code_to_s(5, 0))
    assert_equal('Reserved', Notification.code_to_s(6, 0))
    assert_equal('Reserved', Notification.code_to_s(7, 0))
    # Code 4, Hold Timer Expired, has no subcode registry at all, so there
    # is nothing to name under it. IANA lists a subcode registry for 1, 2,
    # 3, 5, 6 and 7 and none for 4.
    assert_equal('Undefined', Notification.code_to_s(4, 0))
    # And a code point IANA leaves unassigned still reads Undefined, which
    # is what this table says when it does not know a name.
    assert_equal('Undefined', Notification.code_to_s(10))
    assert_equal('Undefined', Notification.code_to_s(255))
    assert_equal('Undefined', Notification.code_to_s(7, 2))
    assert_equal('Undefined', Notification.code_to_s(6, 11))
    assert_equal('Undefined', Notification.code_to_s(5, 4))
    # A NOTIFICATION that carries one says so rather than reading as a
    # code bgp4r has yet to learn.
    assert_equal('Notification (3), length: 21: Cease (6), Reserved (0) ',
                 Notification.new(6, 0).to_s)
    assert_equal('Notification (3), length: 21: ' \
                 'Finite State Machine Error (5), Unspecified Error (0) ',
                 Notification.new(5, 0).to_s)
  end

  def test_1
    # The error code registry names 0 "Reserved"; this used to pin
    # "Undefined", which was less than the table knew.
    assert_equal('Reserved', Notification.code_to_s(0))
    assert_equal('Header Error', Notification.code_to_s(1))
    assert_equal('OPEN msg error', Notification.code_to_s(2))
    assert_equal('UPDATE msg error', Notification.code_to_s(3))
    # RFC 7313 section 5 and section 6: code 7 is "ROUTE-REFRESH Message
    # Error" and its only assigned subcode is 1, "Invalid Message Length".
    # These three lines pinned the name and two subcodes of the expired
    # dynamic capability draft, which IANA never registered against code 7.
    assert_equal('ROUTE-REFRESH Message Error', Notification.code_to_s(7))
    assert_equal('Connection Not Synchronized', Notification.code_to_s(1,1))
    assert_equal('Unrecognized Well-known Attribute', Notification.code_to_s(3,2))
    assert_equal('Invalid Message Length', Notification.code_to_s(7,1))
    assert_equal('Undefined', Notification.code_to_s(7,3))
    notif = BGP::Notification.new(1,1)
    assert_match(/^(ff){16}0015030101$/, notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    notif = BGP::Notification.new(2,2,'some data')
    assert_match(/(ff){16}001e030202736f6d652064617461/, notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    s = 'ffffffffffffffffffffffffffffffff001e030202736f6d652064617461'
    m = Message.factory([s].pack('H*'))
    assert_equal(Notification, m.class)
    assert_equal(m.encode, Notification.new(m).encode)
  end

  # RFC 7313 section 5 and section 6: IANA allocated error code 7 with the
  # name "ROUTE-REFRESH Message Error" and created the "BGP ROUTE-REFRESH
  # Message Error subcodes" registry, in which 0 is Reserved and 1 is
  # "Invalid Message Length". bgp4r named code 7 "CAPABILITY Message Error"
  # with four subcodes of the expired dynamic capability draft, which IANA
  # never registered and no RFC defines.
  def test_error_code_7_is_the_route_refresh_message_error_registry
    assert_equal('ROUTE-REFRESH Message Error', BGP::Notification.code_to_s(7))
    assert_equal('Invalid Message Length', BGP::Notification.code_to_s(7, 1))
    # the four draft subcodes are gone, so a code point IANA leaves
    # unassigned reads as undefined rather than naming something
    assert_equal('Undefined', BGP::Notification.code_to_s(7, 2))
    assert_equal('Undefined', BGP::Notification.code_to_s(7, 3))
    assert_equal('Undefined', BGP::Notification.code_to_s(7, 4))
    assert_equal('Notification (3), length: 21: ' \
                 'ROUTE-REFRESH Message Error (7), Invalid Message Length (1) ',
                 BGP::Notification.new(7, 1).to_s)
  end

  # RFC 7313 section 5: a BoRR or an EoRR whose length is not 4 octets
  # beyond the fixed header draws this NOTIFICATION, and "The Data field of
  # the NOTIFICATION message MUST contain the complete ROUTE-REFRESH
  # message." bgp4r names the error and carries the octets; it does not
  # detect the condition, which is receive side validation and needs the
  # session to know the peer sent capability 70.
  def test_a_route_refresh_message_error_carries_the_whole_route_refresh
    borr = BGP::Route_refresh.new(1, 1, :borr).encode
    notif = BGP::Notification.new(7, 1, borr)
    assert_equal(borr, notif.to_hash[:data])
    # the complete ROUTE-REFRESH, its 19 octet header included
    assert_equal(23, notif.to_hash[:data].size)
    assert_equal(('ff' * 16) + '002c' + '03' + '07' + '01' +
                 ('ff' * 16) + '00170500010101', notif.to_shex)
    back = BGP::Message.factory(notif.encode)
    assert_equal(BGP::Notification, back.class)
    assert_equal(notif.to_shex, back.to_shex)
    assert_equal(BGP::Route_refresh.new(1, 1, :borr).to_shex,
                 BGP::Message.factory(back.to_hash[:data].is_packed).to_shex)
  end

  # RFC 5492 section 5: the Unsupported Capability subcode of the OPEN
  # Message Error, "The value of this Subcode is 7." bgp4r had subcode 7
  # repeating the name of subcode 4, Unsupported Optional Parameter, which
  # is a different error: RFC 4271 section 6.2 sends 4 for an optional
  # parameter type it does not recognize, RFC 5492 sends 7 for a capability
  # inside one.
  def test_open_message_error_subcode_7_is_unsupported_capability
    assert_equal('Unsupported Optional Parameter', BGP::Notification.code_to_s(2, 4))
    assert_equal('Unsupported Capability', BGP::Notification.code_to_s(2, 7))
  end

  # RFC 9234 section 7: IANA "has marked values 8-10 as "Deprecated"" in
  # the "OPEN Message Error subcodes" registry and registered 11 as "Role
  # Mismatch". Section 4.2 is what sends 11, when the two Roles are not a
  # correct pair or, under strict mode, when the peer advertised no BGP
  # Role capability.
  def test_open_message_error_subcode_11_is_role_mismatch
    assert_equal('Deprecated', BGP::Notification.code_to_s(2, 8))
    assert_equal('Deprecated', BGP::Notification.code_to_s(2, 9))
    assert_equal('Deprecated', BGP::Notification.code_to_s(2, 10))
    assert_equal('Role Mismatch', BGP::Notification.code_to_s(2, 11))
    assert_equal('Undefined', BGP::Notification.code_to_s(2, 12))
    assert_equal('Notification (3), length: 21: ' \
                 'OPEN msg error (2), Role Mismatch (11) ',
                 BGP::Notification.new(2, 11).to_s)
  end

  # The notification a speaker sends on a Role mismatch, with the OPEN it
  # refused in the Data field. bgp4r sends it when a script says to; it
  # does not compare the two Roles itself, which is session state.
  def test_a_role_mismatch_carries_the_open_it_refused
    open = BGP::Open.new(4, 100, 200, '10.0.0.1',
                         BGP::OPT_PARM::CAP::Role.new(:customer))
    notif = BGP::Notification.new(2, 11, open.encode)
    back = BGP::Message.factory(notif.encode)
    assert_equal(BGP::Notification, back.class)
    assert_equal(notif.to_shex, back.to_shex)
    assert_equal(open.to_shex,
                 BGP::Message.factory(back.to_hash[:data].is_packed).to_shex)
  end

  # The BGP Error (Notification) Codes registry, checked code point by code
  # point while fixing code 7. 8 is RFC 9687, 9 is RFC 9815, and 10 to 255
  # are unassigned.
  def test_the_error_code_registry_is_complete
    assert_equal('Send Hold Timer Expired', BGP::Notification.code_to_s(8))
    assert_equal('Loss of LSDB Synchronization', BGP::Notification.code_to_s(9))
    assert_equal('Undefined', BGP::Notification.code_to_s(10))
  end

  # The subcode registries of the codes bgp4r already named. RFC 6608
  # defines the three Finite State Machine Error subcodes; RFC 8538 adds
  # Cease subcode 9 and RFC 9384 subcode 10.
  def test_the_subcode_registries_of_the_other_codes
    assert_equal('Receive Unexpected Message in OpenSent State',
                 BGP::Notification.code_to_s(5, 1))
    assert_equal('Receive Unexpected Message in OpenConfirm State',
                 BGP::Notification.code_to_s(5, 2))
    assert_equal('Receive Unexpected Message in Established State',
                 BGP::Notification.code_to_s(5, 3))
    assert_equal('Undefined', BGP::Notification.code_to_s(5, 4))
    assert_equal('Hard Reset', BGP::Notification.code_to_s(6, 9))
    assert_equal('BFD Down', BGP::Notification.code_to_s(6, 10))
    assert_equal('Undefined', BGP::Notification.code_to_s(6, 11))
  end
end
