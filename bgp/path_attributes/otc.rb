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

require 'bgp/path_attributes/attribute'

module BGP

  # Only to Customer (OTC), RFC 9234 section 5: an optional transitive
  # attribute holding one 4-octet AS number. Once added, a route with OTC
  # must only go down to customers; the AS number is the one that added it.
  #
  #   Otc.new(64512)
  #   Otc.new(:otc => 64512)
  #   Otc.new(wire_bytes)
  #
  # bgp4r only carries the attribute. The ingress and egress procedures of
  # section 5 are up to the script, so a test can send a route leak.
  class Otc < Attr

    def initialize(arg = nil)
      @flags, @type = OPTIONAL_TRANSITIVE, ONLY_TO_CUSTOMER
      if arg.is_a?(String) and arg.is_packed?
        parse(arg)
      elsif arg.is_a?(self.class)
        parse(arg.encode)
      elsif arg.is_a?(Hash)
        self.asn = arg[:otc]
      else
        self.asn = arg
      end
    end

    def asn=(val)
      unless val.is_a?(Integer) and val >= 0 and val <= 0xffffffff
        raise ArgumentError, "invalid OTC AS number #{val.inspect}, expected 0 to 4294967295"
      end
      @asn, @value = val, nil
    end

    # The AS number, or nil when the value received was not 4 octets.
    def asn
      @asn
    end
    alias to_i asn

    def to_hash
      { :otc => @asn }
    end

    def attribute_name
      'OTC'
    end

    def to_s(method=:default)
      super(@asn ? @asn.to_s : "malformed, #{@value.size} octets", method)
    end

    # RFC 9234 section 5: 4 octets, the AS number. A value of another size
    # received from the wire is written back as it came.
    def encode
      super(@value || [@asn].pack('N'))
    end

    private

    # A value that is not 4 octets is malformed (RFC 9234 section 5);
    # Path_attribute#errors reports it. It is kept as received.
    def parse(s)
      @flags, @type, _, value = super(s)
      if value.size == 4
        @asn, @value = value.unpack1('N'), nil
      else
        @asn, @value = nil, value.b
      end
    end

  end

  Attr.register(ATTR::ONLY_TO_CUSTOMER, Otc, :otc)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
