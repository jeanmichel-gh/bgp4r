#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

require "bgp/path_attributes/atomic_aggregate"
require 'bgp/path_attributes/attributes'

require 'test/unit'
class Atomic_aggregate_Test < Test::Unit::TestCase
  include BGP
  # RFC 4271 section 4.3: well-known discretionary, so the Transitive
  # bit is set and the Optional bit is not. This asserted 800600, the
  # optional flags bgp4r used to write.
  def test_1
    assert_equal("400600", Atomic_aggregate.new.to_shex)
    assert_equal("Atomic Aggregate (6), length: 0, Flags [T]: ", Atomic_aggregate.new.to_s)
    obj =  Atomic_aggregate.new
    assert_equal("400600", Atomic_aggregate.new(obj.encode).to_shex)
  end
  def test_2
    # The attribute carries no value, so the hash says only that it is
    # there. It used to answer {}, which added no key when
    # Path_attribute#to_hash merged it, so the attribute vanished from a
    # round tripped attribute set in silence.
    assert_equal({:atomic_aggregate=>true},Atomic_aggregate.new.to_hash)
  end
  def test_flags_are_well_known
    assert ! Atomic_aggregate.new.is_optional?
    assert Atomic_aggregate.new.is_transitive?
    assert_equal [], Path_attribute.new(Atomic_aggregate.new).validate
    assert_equal "400600", Path_attribute.new(:atomic_aggregate=>true).encode.unpack1('H*')
  end
  # A receiver treats the optional form as malformed (RFC 7606 section
  # 3 (c)). bgp4r can still send it, and reports it on receive.
  def test_optional_flags_from_the_wire
    pa = Path_attribute.new(["800600"].pack('H*').is_packed)
    assert_equal [[6, 4, :treat_as_withdraw]], pa.errors.collect { |f| [f.type, f.subcode, f.action] }
    assert_equal "800600", pa.encode.unpack1('H*'), "the flags received must be sent back"
    assert_equal [], Path_attribute.new(["400600"].pack('H*').is_packed).errors
  end
end

