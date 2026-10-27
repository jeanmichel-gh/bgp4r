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
    
    class As_path < Attr
      
      class Segment
        include ATTR
        
        def self.factory(s, as4byte=false)
          seg_type, num = s.slice(0,2).unpack('CC')
          len = num * (as4byte ? 4 : 2)+2
          segment = s.slice!(0, len).is_packed
          case seg_type
          when SET ; Set.new(segment, as4byte)
          when SEQUENCE ; Sequence.new(segment, as4byte)
          when CONFED_SEQUENCE ; Confed_sequence.new(segment, as4byte)
          when CONFED_SET ; Confed_set.new(segment, as4byte)
          end
        end
        
        attr_reader :as
        
        def initialize(seg_type, *args)
          @as=[]
          if seg_type.is_a?(String) and seg_type.is_packed?
            parse(seg_type, *args)
          elsif args.size>0 and args.is_a?(Array)
            self.seg_type = seg_type
            @as = args
          else
            raise ArgumentError, "invalid argument #{args.inspect}"
          end
          
        end
        
        def seg_type
          @seg_type
        end
        
        def prepend(as)
          @as.insert(0,as)
        end
        
        def seg_type=(val)
          case val
          when :set             ; @seg_type = SET
          when :sequence        ; @seg_type = SEQUENCE
          when :confed_sequence ; @seg_type = CONFED_SEQUENCE
          when :confed_set      ; @seg_type = CONFED_SET
          else
            raise ArgumentError, "invalid segment type #{val.class} #{val}"
          end
        end
        
        def encode(as4byte=false)
          [@seg_type, @as.size, @as].flatten.pack("CC#{as4byte ? 'N' : 'n'}*")
        end
        
        def as4byte?
          defined?(@as4byte) and @as4byte
        end
        
        def parse(s, as4byte=false)
          @seg_type, _, *@as = s.unpack("CC#{as4byte ? 'N' : 'n'}*")
          @as = [@as].flatten
        end
        
        def to_s
          case @seg_type
          when SET             ; s = "{" ; join=", "
          when SEQUENCE        ; s = ""  ; join= " "
          when CONFED_SET      ; s = "[" ; join= ", "
          when CONFED_SEQUENCE ; s = "(" ; join= " "
          else ; s = "?("
          end
          s += @as.join(join)
          case @seg_type
          when SET             ; s += "}"
          when CONFED_SET      ; s += "]"
          when CONFED_SEQUENCE ; s += ")"
          when SEQUENCE
          else ; s += ")"
          end
          s
        end
        
      end
      
      class As_path::Set < As_path::Segment
        def initialize(*args)
          if args[0].is_a?(String)
            super(*args)
          else
            super(:set, *args)
          end
        end
        def to_hash
          {:set=> as}
        end
      end
      
      class As_path::Sequence < As_path::Segment
        def initialize(*args)
          if args[0].is_a?(String)
            super(*args)
          else
            super(:sequence, *args)
          end
        end
        def to_hash
          {:sequence=> as}
        end        
      end
      
      class As_path::Confed_set < As_path::Segment
        def initialize(*args)
          if args[0].is_a?(String)
            super(*args)
          else
            super(:confed_set, *args)
          end
        end
        def to_hash
          {:confed_set=> as}
        end        
      end
      
      class As_path::Confed_sequence < As_path::Segment
        def initialize(*args)
          if args[0].is_a?(String)
            super(*args)
          else
            super(:confed_sequence, *args)
          end
        end
        def to_hash
          {:confed_sequence=> as}
        end        
      end
      
      # The segment class for each hash key. RFC 4271 section 4.3 for
      # AS_SET and AS_SEQUENCE, RFC 5065 section 3 for the two
      # confederation types.
      SEGMENT_CLASSES = {
        :set             => As_path::Set,
        :sequence        => As_path::Sequence,
        :confed_set      => As_path::Confed_set,
        :confed_sequence => As_path::Confed_sequence,
      }.freeze

      def integer?(arg)
        arg.is_a?(Integer)
      end
      
      attr_accessor :as4byte
      
      def initialize(*args)
        
        @flags, @type, @segments, @as4byte = WELL_KNOWN_MANDATORY, AS_PATH, [], false
        
        if args[0].is_a?(String) and args[0].is_packed?
          parse(*args)
        elsif args[0].is_a?(self.class)
          parse(args[0].encode, *args[1..-1])
        elsif self.class.hash_form?(args[0])
          @segments = self.class.segments_from_hash(args[0])
        elsif integer?(args[0])
          @segments << Sequence.new(*args.dup)
        elsif args[0].is_a?(Segment)
          unless args.find { |seg| ! seg.is_a?(Segment) }.nil?
            raise ArgumentError, "at least one arg is not a segment"
          end
          @segments = args.dup
        end
        
      end
      
      def <<(val)
        raise ArgumentError, "invalid argument, #{val.class} #{val}" unless val.is_a?(Segment)
        @segments << val
      end
      
      def encode(as4byte=@as4byte)
        super(@segments.collect { |segment| segment.encode(as4byte) }.join)
      end
      
      def encode4
        encode(true)
      end
      
      def as_path
        return 'empty' if @segments.empty?
        @segments.collect { |seg| seg.to_s }.join(' ')
      end
      
      def to_s(method=:default, as4byte=false)
        super(as_path, method, as4byte)
      end
      
      # The segments, in order. A copy, so callers cannot change the path.
      def segments
        @segments.dup
      end

      def find_set
        @segments.find { |s| s.seg_type == SET }
      end

      def find_sequence
        @segments.find { |s| s.seg_type == SEQUENCE }
      end
      
      # A hash that round trips through new. One key per segment type
      # while the types are all different, which is the shape bgp4r has
      # always returned. That shape cannot hold the same type twice, so
      # when a type repeats the segments go in order under :segments.
      def to_hash
        segs = @segments.collect { |s| s.to_hash }
        types = segs.collect { |s| s.keys.first }
        h = if types.uniq.size == types.size
          segs.inject({}) { |acc, s| acc.merge(s) }
        else
          { :segments=> segs }
        end
        { :as_path=> h}
      end
      
      private
      
      def parse(s,as4byte=false)
        @flags, @type, _, value=super(s)
        while value.size>0
          @segments << Segment.factory(value.is_packed, as4byte)
        end
      end
      
    end
    
    class As4_path < As_path
      def initialize(*args)
        super(*args)
        @flags, @type, @as4byte =OPTIONAL_TRANSITIVE, AS4_PATH, true        
      end
      def parse(s,as4byte=@as4byte)
        super(s,true)
      end
      # RFC 6793 section 3: AS4_PATH always carries 4-octet AS numbers,
      # whatever the session uses.
      def encode(as4byte=true)
        super(true)
      end
    end
    
    class As_path
      class << self
        def new_hash(arg={})
          o = new
          segments_from_hash(arg).each { |segment| o << segment }
          o
        end

        # True for a hash new builds from: the hash to_hash returns,
        # wrapped under the attribute name, or a :segments list. A bare
        # hash of segment types, which new_hash takes, is not one: new
        # has always ignored such a hash, and Path_attribute builds
        # those through new_hash.
        def hash_form?(arg)
          arg.is_a?(Hash) and
            (arg.has_key?(:as_path) or arg.has_key?(:as4_path) or arg.has_key?(:segments))
        end

        # The segments a hash describes, in order. Two shapes:
        #
        #   {:sequence=>[1,2], :set=>[3,4]}   one key per segment type
        #   {:segments=>[{:sequence=>[1,2]}, {:sequence=>[3,4]}]}
        #
        # The first is the old shape and stays the one to_hash returns
        # while no segment type repeats. The second keeps order and
        # repeats, which a single hash cannot. A bare list of segment
        # hashes, and a hash wrapped under :as_path or :as4_path as
        # to_hash returns it, are accepted too.
        def segments_from_hash(arg)
          arg = { :segments=> arg } if arg.is_a?(Array)
          raise ArgumentError, "invalid argument #{arg.inspect}" unless arg.is_a?(Hash)
          if arg.size==1 and (arg.has_key?(:as_path) or arg.has_key?(:as4_path))
            return segments_from_hash(arg[:as_path] || arg[:as4_path])
          end
          segs = if arg.has_key?(:segments)
            [arg[:segments]].flatten(1)
          else
            arg.collect { |seg_type, as| { seg_type=> as } }
          end
          segs.collect { |seg| segment_from_hash(seg) }
        end

        # One segment from a one key hash such as {:sequence=>[1,2]}.
        def segment_from_hash(arg)
          raise ArgumentError, "invalid segment #{arg.inspect}" unless arg.is_a?(Hash) and arg.size==1
          seg_type, as = arg.first
          klass = seg_type.respond_to?(:to_sym) ? SEGMENT_CLASSES[seg_type.to_sym] : nil
          raise ArgumentError, "invalid segment type #{seg_type.inspect}" unless klass
          klass.new(*[as].flatten)
        end
      end

      class << self
        def new_set(*args)
          new_hash :set=>args.flatten
        end
        def new_sequence(*args)
          new_hash :sequence=>args.flatten
        end
        def new_confed_set(*args)
          new_hash :confed_set=>args.flatten
        end
        def new_confed_sequence(*args)
          new_hash :confed_sequence=>args.flatten
        end
      end
    end

  Attr.register(ATTR::AS_PATH, As_path, :as_path, session: :as4byte) { |v| As_path.new_hash(v) }
  # RFC 6793 section 3: AS4_PATH always carries 4-octet AS numbers.
  Attr.register(ATTR::AS4_PATH, As4_path, :as4_path) { |v| As4_path.new_hash(v) }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

