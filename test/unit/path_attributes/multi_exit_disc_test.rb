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

require "bgp/path_attributes/multi_exit_disc"
require 'test/unit'
class Multi_exit_disc_Test < Test::Unit::TestCase
  include BGP
  def test_1
    assert_equal("80040400000000", Multi_exit_disc.new.to_shex)
    assert_equal("80040400000064", Multi_exit_disc.new(100).to_shex)
    assert_equal("800404000000c8", Multi_exit_disc.new(200).to_shex)
    assert_equal("800404000000c8", Multi_exit_disc.new(:med=>200).to_shex)
    assert_equal("800404000000c8", Multi_exit_disc.new(:multi_exit_disc=>200).to_shex)
    assert_raise(ArgumentError) { Multi_exit_disc.new(:local_pref=>200) }
    assert_equal("(0x00c8) 200", Multi_exit_disc.new(200).multi_exit_disc)
    assert_equal("[Oncr]  (4) Multi Exit Disc: [800404000000c8] '(0x00c8) 200'", Multi_exit_disc.new(200).to_s)
    assert_raise(ArgumentError) { Multi_exit_disc.new({})}
  end
  def test_2
    mp =  Multi_exit_disc.new(200)
    assert_equal("800404000000c8", Multi_exit_disc.new(mp.encode).to_shex)
    assert_equal("(0x00c8) 200", Multi_exit_disc.new(200).multi_exit_disc)
    assert_equal(200, Multi_exit_disc.new(200).to_i)
    mp1 = Multi_exit_disc.new(mp)
    assert_equal(mp.encode, mp1.encode)
  end
end
