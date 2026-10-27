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

  # LARGE_COMMUNITY, RFC 8092: an optional transitive attribute holding
  # 12-octet values, each a Global Administrator and two Local Data Parts.
  #
  #   Large_communities.new('64496:4294967295:2', '64496:1:1')
  #   Large_communities.new('64496:1:1 64496:1:2')
  #   Large_communities.new([64496, 1, 1])
  #   Large_communities.new(wire_bytes)
  #   Path_attribute.new(:large_communities => ['64496:1:1'])
  #
  # Values are kept in the order given, and duplicates are kept, so a test
  # can send what RFC 8092 section 3 says not to. A receiver removes them
  # (section 6); uniq returns the attribute without them.
  class Large_communities < Attr

    class Large_community
      include Comparable

      MAX = 0xffffffff

      attr_reader :global_admin, :local_data1, :local_data2

      # "GA:LD1:LD2" (RFC 8092 section 5), [ga, ld1, ld2], or another
      # Large_community. Each part is 0 to 4294967295.
      def initialize(arg)
        parts = case arg
        when Large_community ; arg.to_a
        when Array           ; arg
        when String
          unless arg.strip =~ /\A\d+:\d+:\d+\z/
            raise ArgumentError, "invalid large community #{arg.inspect}, expected GA:LD1:LD2"
          end
          arg.strip.split(':').collect(&:to_i)
        else
          raise ArgumentError, "invalid large community #{arg.inspect}"
        end
        unless parts.size == 3 and parts.all? { |p| p.is_a?(Integer) and p >= 0 and p <= MAX }
          raise ArgumentError, "invalid large community #{arg.inspect}, each part is 0 to #{MAX}"
        end
        @global_admin, @local_data1, @local_data2 = parts
      end

      def to_a
        [@global_admin, @local_data1, @local_data2]
      end

      # RFC 8092 section 5: decimal, no leading zeros, colons.
      def to_s
        to_a.join(':')
      end

      # RFC 8092 section 3: three 4-octet fields.
      def encode
        to_a.pack('N3')
      end

      def <=>(other)
        to_a <=> other.to_a
      end

      def eql?(other)
        other.is_a?(Large_community) and to_a == other.to_a
      end

      def hash
        to_a.hash
      end
    end

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, LARGE_COMMUNITY
      @communities = []
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode)
      elsif args.size == 1 and args[0].is_a?(Hash) and args[0].has_key?(:large_communities)
        # A hash with no :large_communities key, {:tail=>'05'} for one,
        # goes to add like any other value.
        add(*[args[0][:large_communities]].flatten.compact)
      else
        add(*args)
      end
    end

    # Adds values: strings, space or comma separated strings, [ga, ld1,
    # ld2] arrays, or Large_community objects. Returns self.
    def add(*args)
      take_tail(args).each do |arg|
        if arg.is_a?(Array) and arg.size == 3 and arg.all? { |p| p.is_a?(Integer) }
          @communities << Large_community.new(arg)
        elsif arg.is_a?(Array)
          add(*arg)
        elsif arg.is_a?(String) and arg.strip =~ /[\s,]/
          arg.split(/[\s,]+/).reject(&:empty?).each { |v| @communities << Large_community.new(v) }
        else
          @communities << Large_community.new(arg)
        end
      end
      self
    end
    alias << add

    # The values, as Large_community objects.
    def communities
      @communities.dup
    end

    def large_communities
      @communities.collect(&:to_s).join(' ')
    end

    def size
      @communities.size
    end

    def has?(arg)
      @communities.include?(Large_community.new(arg))
    end

    def has_no?(arg)
      ! has?(arg)
    end

    # Without duplicates, as a receiver keeps it (RFC 8092 section 6).
    # Kept octets are not a duplicate of anything, so they stay.
    def uniq
      Large_communities.new(*@communities.uniq, *[tail_entry].compact)
    end

    def to_s(method=:default)
      super(large_communities, method)
    end

    # The values, plus a {:tail=>hex} entry when octets were kept
    # (Attr::TAIL_KEY), so the hash of a malformed attribute round trips
    # byte for byte through new.
    def to_hash
      { :large_communities => @communities.collect(&:to_s) + [tail_entry].compact }
    end

    def encode
      super(@communities.collect(&:encode).join + (@tail || ''))
    end

    private

    # RFC 8092 section 3. Octets past the last whole value are kept, so
    # encode gives back what was received. Section 6 makes such an
    # attribute malformed; Path_attribute#errors reports it.
    def parse(s)
      @flags, @type, _, value = super(s)
      whole = value.size / 12 * 12
      value.byteslice(0, whole).unpack('N*').each_slice(3) { |p| @communities << Large_community.new(p) }
      @tail = value.byteslice(whole, value.size - whole).b if value.size > whole
    end

  end

  Attr.register(ATTR::LARGE_COMMUNITY, Large_communities, :large_communities, :large_community)

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
