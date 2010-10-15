#--
# Copyright 2010 Jean-Michel Esnault.
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

class Capability_Test < Test::Unit::TestCase
  include BGP::OPT_PARM
  include BGP::OPT_PARM::CAP
  def test_1
    cap = Capability.new(100)
    assert_equal '02026400', cap.to_shex
    assert_equal '0207640576616c7565', cap.to_shex('value')
    assert_equal "Option Capabilities Advertisement (2): [02026400]", cap.to_s
    assert_equal cap.to_shex, Capability.factory(cap.encode).to_shex
  end
  def test_factory_graceful_restart
    s = '020c400a00780001010100010201'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Graceful_restart, cap)
  end
  def test_factory_add_path
    s = '020e450c000101010002800200020103'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Add_path, cap)
  end
  def test_factory_as4
    s = '0206410400000064'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(As4, cap)
  end
  def test_factory_route_refresh
    s = '02020200'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Route_refresh, cap)
    s = '02028000'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Route_refresh, cap)
  end
  def test_factory_mbgp
    s = '0206010400010001'
    cap = Capability.factory([s].pack('H*'))
    assert_instance_of(Mbgp, cap)
  end
  def test_factory_orf
    s = '0218031600010001030101020103010001000203010102010301'
    cap = Capability.factory([s].pack('H*'))
    assert_equal(Orf, cap.class)
  end
  def test_factory_unknown
    s = '0207640576616c7565'
    cap = Capability.factory([s].pack('H*'))
    assert_equal(Capability::Unknown, cap.class)
  end
end
