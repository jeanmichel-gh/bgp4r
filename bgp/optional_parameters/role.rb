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

  # The BGP Role Capability, RFC 9234 section 4.1. The section gives the
  # three fields as labels: "Code:" is "9", "Length:" is "1 (octet)", and
  # the value is an "integer corresponding to the speaker's BGP Role (see
  # Table 1)". Table 1, "Predefined BGP Role Values", names five of them
  # and leaves 5 to 255 unassigned:
  #
  #   0  Provider
  #   1  RS
  #   2  RS-Client
  #   3  Customer
  #   4  Peer (i.e., Lateral Peer)
  #
  #   CAP::Role.new(:customer)
  #   CAP::Role.new(3)
  #   CAP::Role.new(:role => :customer)
  #   CAP::Role.new(wire_bytes)
  #
  # Section 4.1: "If the BGP Role is locally configured, the eBGP speaker
  # MUST advertise the BGP Role Capability in the BGP OPEN message" and "An
  # eBGP speaker MUST NOT advertise multiple versions of the BGP Role
  # Capability." Both are the speaker's business, so neither is enforced
  # here: a script can send two of these, or a Role no RFC defines, which
  # is the point of the library.
  #
  # Section 4.2, Role Correctness, is what the capability buys. The Roles
  # of the two speakers have to form one of three pairs, Provider with
  # Customer, RS with RS-Client, Peer with Peer, and a pair that does not
  # match is rejected with the Role Mismatch notification, "code 2,
  # subcode 11". bgp4r names that subcode in Notification.code_to_s; the
  # check itself needs the session to know both Roles and belongs with the
  # OPEN handling, not with a capability that by design never validates.
  #
  # The OTC attribute of section 5 is already usable without this
  # capability, because section 4.2 says a speaker that advertised a Role
  # and received none "SHOULD ignore the absence of the BGP Role
  # Capability and proceed with session establishment", and then "The
  # locally configured BGP Role is used for the procedures described in
  # Section 5."
  class Role < BGP::OPT_PARM::Capability

    # RFC 9234 section 4.1, Table 1.
    PROVIDER  = 0
    RS        = 1
    RS_CLIENT = 2
    CUSTOMER  = 3
    PEER      = 4

    ROLE_NAMES = {
      PROVIDER  => 'Provider',
      RS        => 'RS',
      RS_CLIENT => 'RS-Client',
      CUSTOMER  => 'Customer',
      PEER      => 'Peer',
    }

    # The Role, or nil when the value received was not one octet, in
    # which case those octets are in value and encode writes them back.
    attr_reader :role, :value

    def initialize(arg)
      @value = nil
      if arg.is_a?(String) and arg.is_packed?
        super(nil)
        parse(arg)
      elsif arg.is_a?(Hash)
        super(arg[:code] || BGP::OPT_PARM::CAP_ROLE)
        if arg.has_key?(:value)
          @role, @value = nil, [arg[:value].to_s].pack('H*')
        else
          self.role = arg[:role]
        end
      else
        super(BGP::OPT_PARM::CAP_ROLE)
        self.role = arg
      end
    end

    # A name from Table 1 or a number. An unassigned value, 5 to 255, is
    # taken as it is: nothing refuses a Role the RFC does not define,
    # since sending one to see what a router does is the job. An Integer
    # the one octet field cannot hold is refused, because the alternative
    # is sending a different Role than the one asked for.
    def role=(val)
      v = _role(val)
      unless v.is_a?(Integer) and (0..255).include?(v)
        raise ArgumentError, "invalid BGP Role #{val.inspect}, expected 0 to 255 " \
                             "or one of #{_role_symbols.join(', ')}"
      end
      @role, @value = v, nil
    end

    # The name Table 1 gives the Role, or 'Unassigned' for 5 to 255.
    def role_name
      ROLE_NAMES[@role] || 'Unassigned'
    end

    # RFC 9234 section 4.1: one octet, the Role. A value of another size
    # received from the wire is written back as it came.
    def encode
      super(@value || [@role].pack('C'))
    end

    def parse(s)
      value = super(s)
      if value.size == 1
        @role, @value = value.unpack1('C'), nil
      else
        @role, @value = nil, value.b
      end
    end

    def to_hash
      h = { :code => @code }
      if @role
        h[:role] = @role
      else
        h[:value] = @value.unpack1('H*')
      end
      h
    end

    # "length" is the length of the optional parameter, the capability code
    # and its length octet included, the way CAP::Enhanced_route_refresh
    # reads it: 3 for the one octet Role of RFC 9234 section 4.1.
    def to_s
      len = 2 + (@value ? @value.size : 1)
      super + "\n    BGP Role (#{@code}), length: #{len}: #{_role_to_s}"
    end

    # The Role is the whole of this capability, and a revision that
    # advertises or removes it says nothing without it.
    def to_s_brief
      "BGP Role #{_role_to_s}"
    end

    private

    def _role_to_s
      @role ? "#{role_name} (#{@role})" : "malformed, #{@value.size} value octets"
    end

    def _role(val)
      case val
      when :provider                        then PROVIDER
      when :rs, :route_server               then RS
      when :rs_client, :route_server_client then RS_CLIENT
      when :customer                        then CUSTOMER
      when :peer, :lateral_peer             then PEER
      else
        val
      end
    end

    def _role_symbols
      [:provider, :rs, :rs_client, :customer, :peer]
    end

  end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
