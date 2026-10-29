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

  class Attr

    # A path attribute that carries any value octets. bgp4r uses it to
    # send attributes it does not know, or known ones with a bad value.
    #
    #   Attr::Raw.new(ATTR::OPTIONAL_TRANSITIVE, 99, "\x01\x02")
    #   Attr::Raw.new(wire_bytes)
    #   Attr::Raw.new(:flags=>0xc, :type=>99, :value=>'0102')
    #
    # flags are the 4 high bits of the Attribute Flags octet, as the
    # ATTR constants (ATTR::OPTIONAL is 0x8). The value is never
    # checked. The flags are written as they are; the Extended Length
    # bit is only added when the value is longer than 255 octets
    # (RFC 4271 section 4.3). Use override(flags: ...) to write any
    # header at all.
    class Raw < Attr

      attr_reader :type, :flags, :value

      class << self
        # A single Hash is the from hash form, never header options.
        def new(*args, &block)
          if args.size == 1 and args[0].is_a?(Hash)
            o = allocate
            o.send(:initialize, *args, &block)
            o
          else
            super
          end
        end
      end

      def initialize(*args)
        if args.size == 1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args.size == 1 and args[0].is_a?(Attr)
          parse(args[0].encode)
        elsif args.size == 1 and args[0].is_a?(Hash)
          h = args[0]
          # to_hash wraps the three fields in a one element :unknown list,
          # because that is the key Path_attribute#to_hash merges them
          # under and Path_attribute.new splices back. Reading only the
          # outer hash found all three nil, so 80c802ff00 rebuilt as
          # 000000: a different attribute, with no error. One Raw is one
          # attribute, so the first entry is the one being built; the list
          # is Path_attribute's business.
          h = [h[:unknown]].flatten.first || {} if h.key?(:unknown)
          @flags = h[:flags].to_i
          @type = h[:type].to_i
          @value = [h[:value].to_s].pack('H*')
        elsif args.size == 3
          @flags, @type, @value = args
          @value = @value.to_s.b
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, expected (flags, type, value), wire bytes or a hash"
        end
      end

      def encode
        super(@value)
      end

      def header_flags(len)
        len > 255 ? @flags | EXTENDED_LENGTH : @flags
      end

      def to_hash
        { :unknown => [ { :flags => @flags, :type => @type, :value => @value.unpack('H*')[0] } ] }
      end

      private

      def parse(s)
        @flags, @type, _, @value = super(s)
        @value = @value.to_s.b.is_packed
      end

    end

  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
