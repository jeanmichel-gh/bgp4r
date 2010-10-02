#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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
  def test_1
    assert_equal('Undefined', Notification.code_to_s(0))
    assert_equal('Header Error', Notification.code_to_s(1))
    assert_equal('OPEN msg error', Notification.code_to_s(2))
    assert_equal('UPDATE msg error', Notification.code_to_s(3))
    assert_equal('Connection Not Synchronized', Notification.code_to_s(1,1))
    assert_equal('Unrecognized Well-known Attribute', Notification.code_to_s(3,2))
    notif = BGP::Notification.new(1,1)
    assert_equal('ffffffffffffffffffffffffffffffff0015030101', notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    notif = BGP::Notification.new(2,2,'some data')
    assert_equal('ffffffffffffffffffffffffffffffff001e030202736f6d652064617461', notif.to_shex)
    assert_equal(notif.encode, Notification.new(notif).encode)
    s = 'ffffffffffffffffffffffffffffffff001e030202736f6d652064617461'
    m = Message.factory([s].pack('H*'))
    assert_equal(Notification, m.class)
    assert_equal(m.encode, Notification.new(m).encode)
  end
end
