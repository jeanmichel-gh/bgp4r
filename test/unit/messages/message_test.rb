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

class Message_Test < Test::Unit::TestCase
  include BGP
  class MyMessage < Message
    attr_reader :data
    def initialize(s=nil)
      @data= parse(s) if s
    end
    def encode
      @msg_type=0xee
      super('abcdefghihjklmopqrstuvwxyz')
    end
  end
  def test_1
    msg1 = MyMessage.new
    msg2 = MyMessage.new(msg1.encode)
    assert_equal('abcdefghihjklmopqrstuvwxyz',msg2.data)
  end
  def test_2
    msg = MyMessage.new
    assert msg.respond_to? :is_an_update?
    assert msg.respond_to? :is_an_open?
    assert msg.respond_to? :is_a_notification?
    assert msg.respond_to? :is_a_route_refresh?
  end
end
