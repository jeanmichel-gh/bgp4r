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


require 'bgp/path_attributes/attribute'

module BGP
  
  class Origin < Attr

    # RFC 4271 section 5.1.1, "ORIGIN is a well-known mandatory
    # attribute": 0 IGP, 1 EGP, 2 INCOMPLETE. Read by the Symbol branch
    # and by the Hash one, which is the whole point of naming it once.
    CODES = { :igp => 0, :egp => 1, :incomplete => 2 }.freeze

    def initialize(arg=0)
      @type=ORIGIN
      @flags=WELL_KNOWN_MANDATORY
      if arg.is_a?(String) and arg.packed?
        parse(arg)
      elsif arg.is_a?(self.class)
        parse(arg.encode)
      elsif arg.is_a?(Hash) and (arg[:origin].is_a?(Hash) or not arg.key?(:origin))
        # The unusual form to_hash answers for a value that is not one
        # octet: :code is the first octet, absent when there was none,
        # and :tail the octets after it. See to_hash. Path_attribute
        # hands over what is under the :origin key, so the bare inner
        # Hash comes here too.
        h = arg.key?(:origin) ? arg[:origin] : arg
        unless (h.keys - [:code, TAIL_KEY]).empty?
          raise ArgumentError, "invalid argument, #{arg.class} (#{arg})"
        end
        @origin = h[:code]
        take_tail_key(h)
      elsif arg.is_a?(Hash) and arg[:origin]
        # to_hash answers what to_sym says, so the value here is usually a
        # Symbol and has to go through the same translation the Symbol
        # branch below does. It was assigned raw, which left @origin
        # holding a Symbol and encode then raised in pack: the class could
        # not read back its own to_hash at all.
        @origin = CODES.fetch(arg[:origin], arg[:origin])
      # RFC 4271 section 4.3 gives ORIGIN a one octet value, so anything
      # that fits one octet can be built and sent. It used to refuse
      # above 2, which is the only three section 5.1.1 defines, and
      # Conventions is explicit that a constructor must not refuse a
      # value that is merely wrong by the RFC: building one no RFC allows
      # is the point of this library. It also blocked the round trip,
      # since an ORIGIN read off the wire with value 5 hashes as 5 and
      # Path_attribute could not build it back.
      elsif arg.is_a?(Integer) and (0..255)===arg
        @origin=arg
      elsif arg.is_a?(Symbol)
        @origin = CODES[arg]
      else
        raise ArgumentError, "invalid argument, #{arg.class} (#{arg})"
      end
    end

    # The value as it arrived. RFC 4271 section 4.3 gives ORIGIN one
    # octet, and RFC 7606 section 7.1 makes any other length malformed,
    # which validation.rb reports. A value of no octets or of more than
    # one is still kept and written back, so a capture replays: the
    # first octet is the code and the rest is a tail.
    def encode
      super(value_octets)
    end

    def to_i
      @origin
    end
    
    def to_sym
      case @origin
      when 1 ; :egp
      when 2 ; :incomplete
      when 0 ; :igp
      else
        :undefined
      end
    end
    
    # The Symbol for the three values RFC 4271 section 5.1.1 defines,
    # which is what every caller and test has always seen. For any other
    # value, which can only arrive off the wire, the code itself: to_sym
    # answers :undefined for all of them alike, so a hash saying
    # :undefined cannot be read back. Same rule as a kept tail, nothing
    # unusual means nothing new in the hash.
    #
    # A value that was not one octet hashes as {:code, :tail}, with
    # :code absent for an empty value and :tail absent when there is
    # none. An ordinary ORIGIN has neither, so its hash is unchanged.
    def to_hash
      unless @origin && tail.nil?
        h = {}
        h[:code] = @origin if @origin
        h.merge!(tail_entry) if tail
        return {:origin=>h}
      end
      sym = to_sym
      {:origin=> sym == :undefined ? @origin : sym}
    end

    def origin
      case to_i
      when 0 ; 'igp'
      when 1 ; 'egp'
      when 2 ; 'incomplete'
      else
        'bogus'
      end
    end

    def to_s(method=:default)
      super(origin, method)
    end

    private

    def value_octets
      v = @origin ? [@origin].pack('C') : String.new
      tail ? v + tail : v
    end

    # Reads the whole value rather than one octet of it, so an ORIGIN of
    # the wrong length is kept and not silently cut to fit. A zero length
    # ORIGIN used to leave @origin nil, and encode then raised, which
    # killed a Neighbor's event thread through its debug log line.
    def parse(s)
      @flags, @type, _, value = super(s)
      @origin = value.getbyte(0)
      @tail = value.byteslice(1..-1) if value.bytesize > 1
    end

  end

  Attr.register(ATTR::ORIGIN, Origin, :origin)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

