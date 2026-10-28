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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP

  # The Route Refresh Capability, RFC 2918 section 3: capability code 2,
  # and "Capability Length field of this capability is zero." Code 128 is
  # the pre-standard Cisco value, which bgp4r reads and writes too.
  #
  #   CAP::Route_refresh.new             # code 2
  #   CAP::Route_refresh.new(128)        # the Cisco code
  #   CAP::Route_refresh.new(wire_bytes)
  #   CAP::Route_refresh.new(:code=>2)
  #
  # The capability carries no value, so there is nothing to build from
  # field values but the code. Value octets that arrive anyway are kept
  # and written back rather than dropped: nothing is validated here, on
  # either side. Same shape as CAP::Enhanced_route_refresh, which is where
  # it came from.
  class Route_refresh < BGP::OPT_PARM::Capability

    attr_reader :value

    def initialize(arg=OPT_PARM::CAP_ROUTE_REFRESH)
      @value = ''.b
      if arg.is_a?(String) and arg.is_packed?
        super(nil)
        parse(arg)
      elsif arg.is_a?(Hash)
        super(arg[:code] || OPT_PARM::CAP_ROUTE_REFRESH)
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
      super + "\n    Route Refresh #{@code==128 ? "(Cisco) " : ""}(#{@code}), length: #{2 + @value.size}"
    end
  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
