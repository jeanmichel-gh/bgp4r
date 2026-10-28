#--
# Copyright 2026 Jean-Michel Esnault.
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

  # RFC 7313 section 3.1, the Enhanced Route Refresh Capability: "IANA has
  # assigned a Capability Code of 70 for this capability" and "The
  # Capability Length field of this capability is zero." Advertising it is
  # what lets a peer send the BoRR and EoRR subtypes of RFC 7313 section
  # 3.2, and what makes the ROUTE-REFRESH Message Error of section 5 apply.
  #
  #   CAP::Enhanced_route_refresh.new
  #   CAP::Enhanced_route_refresh.new(wire_bytes)
  #   CAP::Enhanced_route_refresh.new(:code=>70)
  #
  # The capability carries no value, so there is nothing to build from
  # field values but the code, as with CAP::Route_refresh and CAP::Dynamic.
  # Value octets that arrive anyway are kept and written back rather than
  # dropped: nothing is validated here, on either side.
  class Enhanced_route_refresh < BGP::OPT_PARM::Capability

    attr_reader :value

    def initialize(arg=BGP::OPT_PARM::CAP_ENHANCED_ROUTE_REFRESH)
      @value = ''.b
      if arg.is_a?(String) and arg.is_packed?
        super(nil)
        parse(arg)
      elsif arg.is_a?(Hash)
        super(arg[:code] || BGP::OPT_PARM::CAP_ENHANCED_ROUTE_REFRESH)
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

    # "length: 2" is the length of the optional parameter, the capability
    # code and its length octet, the way CAP::Route_refresh#to_s reads it.
    def to_s
      super + "\n    Enhanced Route Refresh (#{@code}), length: #{2 + @value.size}"
    end

  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
