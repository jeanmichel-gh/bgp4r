#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP

# The Dynamic Capability capability, code 67. RFC 5492 section 4 gives the
# code and length octets every capability has, and
# draft-ietf-idr-dynamic-cap-19 section 9 assigns 67 with no value, so the
# length is zero.
#
#   CAP::Dynamic.new
#   CAP::Dynamic.new(wire_bytes)
#   CAP::Dynamic.new(:code=>67)
#
# The capability carries no value, so there is nothing to build from field
# values but the code. Value octets that arrive anyway are kept and written
# back rather than dropped: nothing is validated here, on either side. Same
# shape as CAP::Enhanced_route_refresh, which is where it came from.
class Dynamic < BGP::OPT_PARM::Capability

  attr_reader :value

  def initialize(arg=BGP::OPT_PARM::CAP_DYNAMIC)
    @value = ''.b
    if arg.is_a?(String) and arg.is_packed?
      super(nil)
      parse(arg)
    elsif arg.is_a?(Hash)
      super(arg[:code] || BGP::OPT_PARM::CAP_DYNAMIC)
      @value = [arg[:value].to_s].pack('H*') if arg[:value]
    else
      super(arg)
    end
  end

  def encode(extended: false)
    super(@value, :extended => extended)
  end

  def parse(s)
    @value = super(s)
  end

  def to_hash
    h = { :code => @code }
    h[:value] = @value.unpack('H*')[0] unless @value.empty?
    h
  end

  # "length: 2" is the length of the capability, its code and its length
  # octet, so value octets that arrived count toward it.
  def to_s
    super + "\n    Dynamic Capability #{@code}, length: #{2 + @value.size}"
  end
end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
