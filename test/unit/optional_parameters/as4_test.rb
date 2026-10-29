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

class As4_capability_Test < Test::Unit::TestCase
  include BGP::OPT_PARM::CAP
  def test_1
    cap1 = As4.new(100)
    cap2 = As4.new(['0206410400000064'].pack('H*'))
    cap3 = As4.new(cap1.encode)
    assert_equal(cap2.encode, cap3.encode)
  end

  # The third build path, which was missing: a Hash became @as and encode
  # raised TypeError inside pack. Both the nested form to_hash writes and
  # the bare inner hash are taken.
  def test_builds_from_its_own_hash
    cap = As4.new(100)
    assert_equal({ :code => 65, :capability => { :as => 100 } }, cap.to_hash)
    assert_equal(cap.encode, As4.new(cap.to_hash).encode)
    assert_equal(cap.encode, As4.new(:as => 100).encode)
    # A 4-octet AS, which is the whole point of the capability.
    big = As4.new(0x1_0000)
    assert_equal(big.encode, As4.new(big.to_hash).encode)
  end
end
