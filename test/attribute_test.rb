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

require 'bgp/common'
require 'bgp/path_attribute'
require 'test/unit'

class ATTR_Test < Test::Unit::TestCase
  include BGP
  def test_1
    my_attr = Class.new(Attr)
    my_attr.class_eval do
      attr_reader :type, :flags, :value
      attr_writer :value
      def initialize(*args)
        if args.size>1
          @flags, @type,	@value = args
        else
          arr = parse(*args)
        end
      end
      def parse(s)
        @flags, @type, len, @value = super
      end
      def encode
        super(value)
      end
    end
    assert_equal('40010101',my_attr.new(['40010101'].pack('H*')).to_shex)
    assert_equal('40010101',my_attr.new(BGP::ATTR::WELL_KNOWN_MANDATORY, 1, [1].pack('C')).to_shex)
    
    bogus_0 = my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 0, 'A BOGUS OPTIONAL TRANSITIVE ATTR WITH TYPE 0')
    bogus_999 = my_attr.new(ATTR::OPTIONAL_TRANSITIVE, 999, 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 999')
    assert_equal bogus_0.to_shex, my_attr.new(bogus_0.encode).to_shex
    assert_equal bogus_999.to_shex, my_attr.new(bogus_999.encode).to_shex
    assert_equal 'A BOGUS OPTIONAL TRANSITIVE ATTR WITH TYPE 0', bogus_0.value
    assert_equal 'AN OPTIONAL TRANSITIVE ATTR WITH TYPE 999', bogus_999.value
  end
end
class Attr_factory_Test < Test::Unit::TestCase
  include BGP
  def test_1
    s = ['400101014003040a000001800404000000644005040000006440020c020500010002000300040005c0080c051f00010137003b0af50040'].pack('H*')
    assert_equal(Origin, BGP::Attr.factory(s).class)
    assert_equal(Next_hop, BGP::Attr.factory(s).class)
    assert_equal(Multi_exit_disc, BGP::Attr.factory(s).class)
    assert_equal(Local_pref, BGP::Attr.factory(s).class)
    assert_equal(As_path, BGP::Attr.factory(s).class)
    assert_equal(Communities, BGP::Attr.factory(s).class)
    assert_equal('',s)
  end
end
