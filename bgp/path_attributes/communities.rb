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

  class Communities < Attr

    class Community

      # Well known communities. Values and names from the IANA
      # "BGP Well-known Communities" registry.
      unless const_defined? :NO_EXPORT
        GRACEFUL_SHUTDOWN     = 0xFFFF0000 # RFC 8326 section 5
        ACCEPT_OWN            = 0xFFFF0001 # RFC 7611 section 2
        LLGR_STALE            = 0xFFFF0006 # RFC 9494 section 3.2
        NO_LLGR               = 0xFFFF0007 # RFC 9494 section 3.3
        BLACKHOLE             = 0xFFFF029A # RFC 7999 section 5
        NO_EXPORT             = 0xFFFFFF01 # RFC 1997
        NO_ADVERTISE          = 0xFFFFFF02 # RFC 1997
        NO_EXPORT_SUB_CONFED  = 0xFFFFFF03 # RFC 1997
        NO_PEER               = 0xFFFFFF04 # RFC 3765
      end

      unless const_defined? :WELL_KNOWN
        # Name (symbol) to value.
        WELL_KNOWN = {
          :graceful_shutdown    => GRACEFUL_SHUTDOWN,
          :accept_own           => ACCEPT_OWN,
          :llgr_stale           => LLGR_STALE,
          :no_llgr              => NO_LLGR,
          :blackhole            => BLACKHOLE,
          :no_export            => NO_EXPORT,
          :no_advertise         => NO_ADVERTISE,
          :no_export_sub_confed => NO_EXPORT_SUB_CONFED,
          :no_peer              => NO_PEER,
        }.freeze
        # Other spellings accepted when building: the IANA names
        # NO_EXPORT_SUBCONFED and NOPEER.
        ALIASES = {
          :no_export_subconfed  => NO_EXPORT_SUB_CONFED,
          :nopeer               => NO_PEER,
        }.freeze
      end

      class << self
        def method_missing(name, *args, &block)
          if WELL_KNOWN.has_key?(name)
            new name
          else
            super
          end
        end
        def respond_to_missing?(name, include_private=false)
          WELL_KNOWN.has_key?(name) || super
        end

        # Value of a well known community name, given as a Symbol or a
        # String. Case does not matter and '-' may be used for '_'.
        # Returns nil for an unknown name.
        def value_of(name)
          key = name.to_s.downcase.tr('-','_').to_sym
          WELL_KNOWN[key] || ALIASES[key]
        end
      end

      # Build from:
      # * a well known name: :no_export, 'no_export', 'NO-EXPORT'
      # * an 'asn:value' String, each half 0 to 65535
      # * an Integer, or a decimal or 0x hex String, 0 to 0xFFFFFFFF
      # * a Community
      # Any 32 bit value is accepted, reserved or not (RFC 1997).
      # Anything else raises ArgumentError.
      def initialize(arg)
        case arg
        when Symbol
          @value = self.class.value_of(arg)
          raise ArgumentError, "invalid argument #{arg.inspect}" unless @value
        when String
          self.value = parse_string(arg)
        when Integer
          self.value = arg
        else
          raise ArgumentError, "invalid argument #{arg.inspect}" if arg.nil? or ! arg.respond_to?(:to_i)
          self.value = arg.to_i
        end
      end

      def value=(val)
        unless val.is_a?(Integer) and (0..0xFFFFFFFF) === val
          raise ArgumentError, "invalid argument #{val.inspect}"
        end
        @value=val
      end

      # The well known name of this community as a Symbol, or nil.
      def name
        WELL_KNOWN.key(@value)
      end

      def to_i
        @value
      end

      def to_s
        [@value >> 16, @value & 0xffff].join(':')
      end

      # The community attribute values ranging from 0x0000000 through
      # 0x0000FFFF and 0xFFFF0000 through 0xFFFFFFFF are hereby reserved.
      def is_reserved?
        (0x0000000..0x0000FFFF ) === @value or (0xFFFF0000..0xFFFFFFFF) === @value
      end

      def encode
        [@value].pack('N')
      end

      private

      def parse_string(arg)
        str = arg.strip
        if (value = self.class.value_of(str))
          value
        elsif str =~ /\A(\d+):(\d+)\z/
          asn, val = $1.to_i, $2.to_i
          unless asn <= 0xFFFF and val <= 0xFFFF
            raise ArgumentError, "invalid argument #{arg.inspect}"
          end
          (asn << 16) | val
        elsif str =~ /\A\d+\z/
          str.to_i
        elsif str =~ /\A0x\h+\z/i
          str.hex
        else
          raise ArgumentError, "invalid argument #{arg.inspect}"
        end
      end

    end

    class << self
      def new_hash(arg={})
        o = new
        [:communities].each do |set_type|
          next unless arg.has_key? set_type
          case set_type
          when :communities
            o << arg[set_type]
          else
            raise
          end 
        end
        o
      end
    end

    def initialize(*args)
      @flags, @type = OPTIONAL_TRANSITIVE, COMMUNITIES
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class) and args[0].respond_to?(:encode)
        parse(args[0].encode, *args[1..-1])
      else
        add(*args)
      end
    end

    def add(*args)
      @communities ||=[]
      args.flatten.each do |arg|
        if arg.is_a?(String) and arg.strip =~ /[\s,]/
          arg.split(/[\s,]+/).reject(&:empty?).each { |v| @communities << Community.new(v) }
        elsif arg.is_a?(Community)
          @communities << arg
        else
          @communities << Community.new(arg)
        end
      end
      self
    end
    alias << add

    def communities
      @communities.collect { |comm| comm.to_s }.join(' ')
    end

    def to_s(method=:default)
      super(communities, method)
    end
    
    # Numbers, not names: "65535:65281" for no_export. The hash rebuilds
    # the same bytes through new_hash or Path_attribute.new.
    def to_hash
      { :communities=> @communities.collect { |comm| comm.to_s } }
    end

    # Well known names in this attribute, as Symbols.
    def names
      @communities.collect { |comm| comm.name }.compact
    end

    def encode
      super(@communities.collect { |comm| comm.encode }.join)
    end

    def parse(s)
      @flags, @type, len, value=super(s)
      self << value.unpack("N#{len/4}")
    end

    def sort
      Communities.new(to_a.sort)
    end

    def sort!
      @communities = @communities.sort_by { |c| c.to_i }
      self
    end

    def <=>(other)
      self.sort.to_shex <=> other.sort.to_shex
    end
    
    def has?(arg)
      ! has_no?(arg)
    end

    def has_no?(arg)
      @communities.find { |c| c.to_i == arg_comm_to_i(arg) }.nil? 
    end
    
    Community::WELL_KNOWN.each_key do |wkc|
      define_method("has_#{wkc}?") do
        has? Community.const_get(wkc.upcase)
      end
      define_method("does_not_have_#{wkc}?") do
        ! has? Community.const_get(wkc.upcase)
      end
    end

    private
    
    def arg_comm_to_i(arg)
      return arg if arg.is_a?(Integer)
      Community.new(arg).to_i
    end

    def to_a
      @communities.collect { |c| c.to_i }
    end

  end
  
end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
