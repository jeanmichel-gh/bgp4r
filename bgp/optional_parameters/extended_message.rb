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

  # The BGP Extended Message Capability, RFC 8654 section 3: "a new BGP
  # capability [RFC5492] defined with Capability Code 6 and Capability
  # Length 0". Advertising it says this speaker can receive a message of
  # up to 65,535 octets, which section 4 allows for every message but
  # OPEN and KEEPALIVE.
  #
  #   CAP::Extended_message.new
  #   CAP::Extended_message.new(wire_bytes)
  #   CAP::Extended_message.new(:code=>6)
  #
  # **This names the capability and nothing more.** bgp4r still packs and
  # reads at the RFC 4271 limit, BGP::Message::MAX_SIZE, whatever was
  # negotiated. Raising that limit when both sides advertised this is a
  # change to every packer and to the receive path, so it is its own
  # piece of work. What this buys today is that a peer's OPEN prints the
  # capability by name where it printed as Unknown: FRR and GoBGP both
  # send it, measured in lab/routescope/bgp4r-lab on 2026-11-03.
  #
  # The capability carries no value. RFC 8654 says nothing about one that
  # arrives anyway, so the octets are kept and written back, as
  # CAP::Enhanced_route_refresh does: nothing is validated here, on either
  # side.
  class Extended_message < BGP::OPT_PARM::Capability

    attr_reader :value

    def initialize(arg=BGP::OPT_PARM::CAP_EXTENDED_MESSAGE)
      @value = String.new
      if arg.is_a?(String) and arg.is_packed?
        super(nil)
        parse(arg)
      elsif arg.is_a?(Hash)
        super(arg[:code] || BGP::OPT_PARM::CAP_EXTENDED_MESSAGE)
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
      h[:value] = @value.unpack1('H*') unless @value.empty?
      h
    end

    # "length: 2" is the length of the capability, its code and its
    # length octet, the way CAP::Enhanced_route_refresh#to_s reads it.
    def to_s
      super + "\n    BGP Extended Message (#{@code}), length: #{2 + @value.size}"
    end

  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
