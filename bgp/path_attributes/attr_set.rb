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
require 'bgp/path_attributes/path_attribute'

module BGP

  # The ATTR_SET attribute of RFC 6368 section 5, type code 128, an
  # optional transitive attribute. Its value is a 4-octet Origin AS
  # followed by "a variable-length field that conforms to the BGP UPDATE
  # message path attribute encoding rules", so this is a Path_attribute
  # inside a Path_attribute: the attribute level analogue of EVPN route
  # type 11's Route Key, which nests an NLRI inside an NLRI.
  #
  # Two encoding rules of section 5 are not free and both are here:
  #
  #   The Origin AS is a 32-bit unsigned integer "regardless of whether
  #   or not the originating PE supports 4-octet AS numbers", so unlike
  #   AGGREGATOR this field never follows the session.
  #
  #   The attributes inside "MUST be encoded using 4-octet AS numbers",
  #   again "regardless of the capabilities advertised by the BGP
  #   speaker to which the ATTR_SET attribute is transmitted". bgp4r's
  #   encode has a 2 against 4 octet AS switch, so that is a constraint
  #   on it rather than something that falls out: see INNER below, and
  #   the encode and parse methods that pass it.
  #
  # Nothing here validates, per the Conventions in CLAUDE.md. Section 5
  # says the attribute "can carry any attribute that can appear in a BGP
  # UPDATE" except MP_REACH and MP_UNREACH, and a set carrying one of
  # those still builds and encodes, so a test can put it on the wire and
  # watch a router decide. validation.rb reports it on receipt.
  class Attr_set < Attr

    # The session argument for the nested attributes. Two halves, and
    # each is a decision rather than a default.
    #
    # :as4byte is true unconditionally, because section 5 fixes the AS
    # size inside the set and says so twice, once for encoding and once
    # for the capabilities of the peer it is sent to. So the nested set
    # ignores the session, which is the opposite of how AGGREGATOR
    # behaves one level up.
    #
    # :policy is :lenient so a malformed nested attribute cannot raise
    # out of this decoder. Section 5 does make an included attribute
    # being malformed a malformed ATTR_SET, but that is a finding and
    # belongs in validation.rb, which runs on the raw octets and never
    # on a decoder's output. A decoder that raised here would file the
    # fault as a gap in bgp4r instead, which is the one thing CLAUDE.md
    # calls the worst failure a conformance tool has.
    INNER = { :as4byte => true, :policy => :lenient }.freeze

    # The nested attributes, as a Path_attribute.
    attr_reader :attributes

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, ATTR_SET
      if args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args[0].is_a?(Hash)
        # Unwrap our own to_hash before reading fields. Without this the
        # wrapped form builds an ATTR_SET with origin AS 0 and no
        # attributes, in silence, because neither key is found. That is
        # the failure Extended_community::Traffic_action records: a
        # class may refuse the wrapped form, it may not accept it and
        # build something else. Unwrapping is cheaper than refusing and
        # makes Attr_set.new(an_attr_set.to_hash) work as well.
        h = args[0][:attr_set] || args[0]
        take_tail_key(h)
        return @origin_as, @attributes = 0, Path_attribute.new if tail
        self.origin_as = h[:origin_as]
        @attributes = _coerce_attributes_(h[:attributes])
      elsif args[0].is_a?(Integer)
        self.origin_as = args.shift
        @attributes = _coerce_attributes_(args)
      else
        raise ArgumentError, "invalid argument, #{args.inspect}"
      end
    end

    # RFC 6368 section 5: a 32-bit unsigned integer, so this refuses a
    # value that does not fit. That is a representability refusal, which
    # Conventions allows, and not a judgement: the alternative is
    # silently sending a different AS than the caller asked for. The
    # octet level routes stay open for anything else.
    def origin_as=(val)
      return @origin_as = 0 if val.nil?
      raise ArgumentError, "origin AS must be an Integer" unless val.is_a?(Integer)
      unless (0..0xffffffff).include?(val)
        raise ArgumentError, "origin AS #{val} does not fit in 4 octets"
      end
      @origin_as = val
    end

    def origin_as
      @origin_as
    end

    # Add attributes to the set after building, the way
    # Path_attribute#add does, so a test can grow one a line at a time.
    def add(*args)
      @attributes ||= Path_attribute.new
      @attributes.add(*args)
      self
    end
    alias << add

    # RFC 6368 section 5: Origin AS, then the path attributes. The true
    # is the section's 4-octet AS rule for AS_PATH and AGGREGATOR
    # inside, and it is not optional.
    def encode
      return super(tail) if tail
      super([@origin_as].pack('N') + @attributes.encode(true))
    end

    def parse(s)
      @flags, @type, _, value = super(s)
      value = value.to_s.dup
      # A value too short to hold the Origin AS is kept as it came, so
      # encode gives back what arrived. RFC 6368 section 5 makes such an
      # attribute malformed and validation.rb reports it; the octets are
      # not ours to repair, and a reader that invented a zero AS would
      # answer encode with three octets the peer never sent. Same rule
      # and same shape as pmsi_tunnel.rb, which keeps a value shorter
      # than its own fixed part.
      if value.size < 4
        @tail = value.b
        @origin_as, @attributes = 0, Path_attribute.new
        return
      end
      @origin_as = value.slice!(0, 4).unpack1('N')
      # Path_attribute consumes the String it is handed, which is fine
      # here because value is already a slice of our own making. INNER
      # is what makes the nested AS numbers 4 octets.
      @attributes = Path_attribute.new(value.is_packed, INNER)
    end

    def to_s(method=:default)
      super("Origin AS #{@origin_as}, #{@attributes.to_s(method, true)}", method)
    end

    # The wrapped form, as every attribute answers, because
    # Path_attribute#to_hash merges one key per attribute. new reads the
    # bare inner hash, which is the shape recorded in
    # test/unit/to_hash_catalog.rb for the 38 attributes written test
    # first.
    def to_hash
      # A kept tail rides as the whole value, the way Pmsi_tunnel does
      # it. No tail, no key, so an ordinary set hashes as the two
      # fields it has always hashed as.
      return { :attr_set => tail_entry } if tail
      { :attr_set => { :origin_as => @origin_as,
                       :attributes => @attributes.to_hash } }
    end

    private

    # Accept a ready made Path_attribute, the hash one answers, a list
    # of attributes, or nothing.
    def _coerce_attributes_(arg)
      case arg
      when Path_attribute then arg
      when Hash           then Path_attribute.new(arg)
      when nil            then Path_attribute.new
      when Array
        list = arg.flatten.compact
        return Path_attribute.new if list.empty?
        return list[0] if list.size == 1 and list[0].is_a?(Path_attribute)
        return Path_attribute.new(list[0]) if list.size == 1 and list[0].is_a?(Hash)
        Path_attribute.new(*list)
      else
        Path_attribute.new(arg)
      end
    end

  end

  # No session: argument, unlike AGGREGATOR. RFC 6368 section 5 fixes
  # the AS size inside the set whatever the session negotiated, so there
  # is nothing for the registry to pass down.
  Attr.register(ATTR::ATTR_SET, Attr_set, :attr_set)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
