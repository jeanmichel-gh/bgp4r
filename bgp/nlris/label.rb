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

require 'bgp/common'

module BGP
  class Label
    attr_reader :label

    # The Bottom of Stack bit this label arrived with, or nil on one built
    # from values. RFC 8277 section 2.2 says of that bit: "This 1-bit field
    # MUST be set to one on transmission and MUST be ignored on reception",
    # so a build writes 1 and encode answered 1 for everything.
    #
    # A label read off the wire with the bit clear therefore came back with
    # it set, which is the one thing encode must not do. The case that
    # matters is a withdrawal: section 2.4 replaces the label of a
    # withdrawn route with a Compatibility field that "SHOULD be set to
    # 0x800000", whose low octet is zero, so the three octets a peer sent
    # came back as 0x800001 and the UPDATE could not be sent again. A
    # label stack whose bottom entry arrived with the bit clear had the
    # same thing happen to it, since Label_stack#encode leaves the last
    # entry to write its own.
    attr_reader :bottom

    def initialize(*args)
      @label, @exp = [0]*3
      if args.size==1 and args[0].is_a?(Hash)
        @label=args[0][:label] if args[0][:label]
        @exp=args[0][:exp] if args[0][:exp]
        @bottom=args[0][:bottom] if args[0].has_key?(:bottom)
      elsif args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else args[0].is_a?(Integer)
        @label, @exp = args + [0]
      end
    end
    # bottom defaults to the bit that arrived, and to 1 on a label built
    # from values, which is what RFC 8277 section 2.2 asks a sender for and
    # what every caller got before. Label_stack#encode still passes 0 for
    # every entry above the bottom of a stack.
    def encode(bottom=@bottom.nil? ? 1 : @bottom)
      n = (@label << 4) | ((@exp & 0x7)<< 1) |(bottom & 0x1)
      o1 = (n & 0xff0000) >> 16
      o2 = (n & 0x00ff00) >> 8
      o3 = (n & 0x0000ff)
      [o1,o2,o3].pack('CCC')
    end
    def parse(s)
      octets = s.slice!(0,3).unpack('CCC')
      n = (octets[0] << 16) + (octets[1] << 8) + octets[2]
      @exp = (n >> 1) & 0x7
      @label = (n >> 4)
      @bottom = n & 0x1
    end
    # :bottom only when the bit is clear, since a build from the hash
    # writes 1 without it. A label whose bit is set, which is every label
    # RFC 8277 section 2.2 asks a sender to write, hashes as the two keys
    # it always did.
    def to_hash
      h = {:label=>@label, :exp=>@exp}
      h[:bottom] = @bottom if @bottom == 0
      h
    end
  end
  class Label_stack

    # The three octets of the RFC 8277 section 2.4 Compatibility field,
    # kept whole, on a stack read from a withdrawal. nil on every other
    # stack, so nothing else here changes shape.
    #
    # Section 2.4 puts this where a label would be on a withdrawn route:
    # "Upon transmission, the Compatibility field SHOULD be set to
    # 0x800000", and "Upon reception, the value of the Compatibility field
    # MUST be ignored". Its own S bit is therefore 0, and section 2.2 says
    # of that bit "This 1-bit field MUST be set to one on transmission and
    # MUST be ignored on reception" precisely so a reader can find the end
    # of a stack.
    #
    # With the bit clear the octets are ambiguous and the walk below has
    # only the bit to go on, so it read straight on into the prefix: a
    # withdrawal of 10.0.0.0/24 came back as two labels and a 0.0.0.0/0
    # prefix. Nothing in the octets can tell a reader otherwise, so the
    # only fix is to know the NLRI came from MP_UNREACH_NLRI, which is
    # where section 2.4 says a withdrawal travels. Mp_unreach#parse passes
    # that fact down.
    attr_reader :compatibility

    # Three octets, because section 2.4 shows the field in Figure 4 where
    # a label goes and says "the length of the Compatibility field must be
    # subtracted from the length of the NLRI". The section never states a
    # size in words, so this is the figure's and not a sentence's.
    COMPATIBILITY_SIZE = 3

    # What section 2.4 asks a sender for: "it is RECOMMENDED by this
    # document that the Compatibility field be set to 0x800000". Only used
    # by to_s, since reception must ignore the value, and some
    # implementations send 0x000000 instead.
    RECOMMENDED_COMPATIBILITY = "\x80\x00\x00".b

    # The wire path takes the withdrawal fact as a second positional
    # argument rather than a keyword, because a keyword parameter on
    # initialize makes Ruby 3 read a bare Hash as keywords and the hash
    # build path here passes one. Same reason Optional_parameter::Unknown
    # does it positionally; see Conventions in CLAUDE.md.
    def initialize(*args)
      @label_stack=[]
      if args.size>=1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0], args[1] ? true : false)
      elsif args.size==1 and args[0].is_a?(Hash) and args[0][:compatibility]
        @compatibility = [args[0][:compatibility].to_s].pack('H*')
      elsif args.size==1 and args[0].is_a?(Hash)
        @label_stack = args[0][:labels].collect { |l| Label.new(l) }
      else
        @label_stack = args.collect { |arg| (arg.is_a?(Label) ? arg : Label.new(arg)) }
      end
    end

    # 1 for a Compatibility field, so the 24 bits it occupies come off the
    # NLRI length the way section 2.4 asks. It is not a label and there is
    # no label to count, but it is one field of a label's width.
    def size
      @compatibility ? 1 : @label_stack.size
    end

    def encode
      return @compatibility if @compatibility
      enc = @label_stack[0..-2].collect { |l| l.encode(0) }
      enc << @label_stack[-1].encode
      enc.join
    end
    # RFC 8277 section 2.2 gives each entry 3 octets, and the Bottom of
    # Stack bit of the last one ends the stack. Fewer than three octets
    # left is not an entry, so the walk stops there and leaves them for the
    # caller, which is Labeled#parse reading the prefix behind the stack.
    #
    # It used to walk while any octet was left and unpack s[2,1] out of
    # what it found, so it raised NoMethodError on nil. A conformant
    # withdrawal is exactly that case: section 2.4 replaces the label of a
    # withdrawn route with a Compatibility field that "SHOULD be set to
    # 0x800000", whose Bottom of Stack bit is 0, so the walk read on into
    # the prefix octets and off the end. bgp4r could not read such an
    # UPDATE at all.
    # withdrawn: the NLRI came from MP_UNREACH_NLRI, so the three octets
    # where a label would be are the section 2.4 Compatibility field and
    # the walk must not run. Reading them as a label is what made a
    # withdrawal unreadable.
    def parse(s, withdrawn = false)
      if withdrawn
        @compatibility = s.slice!(0, COMPATIBILITY_SIZE).b
        return
      end
      while s.size>2
        bottom = s[2,1].unpack('C')[0]
        @label_stack << label = Label.new(s)
        break if bottom & 1 > 0
      end
    end
    def to_s
      if @compatibility
        s = "Compatibility=0x#{@compatibility.unpack1('H*')}"
        # Section 2.4: "However, some implementations set it to 0x000000."
        # Worth saying, since a reader comparing two captures will see it.
        s += ' (not the RECOMMENDED 0x800000)' unless
          @compatibility == RECOMMENDED_COMPATIBILITY
        s
      elsif @label_stack.empty?
        "Label stack:(empty)"
      else
        "Label Stack=#{@label_stack.collect{ |l| l.label }.join(',')} (bottom)"
      end
    end
    def to_ary
      @label_stack.collect { |e| e.label }
    end
    # :compatibility only on a withdrawal, so every other stack hashes as
    # the one key it always did and no caller sees a new shape.
    def to_hash
      return {:compatibility => @compatibility.unpack1('H*')} if @compatibility
      @label_stack.size==1 ? {:label=>@label_stack[0].label} :  {:labels=> to_ary} 
    end
    def bit_length
      return COMPATIBILITY_SIZE*8 if @compatibility
      @label_stack.compact.size*24
    end
  end
end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

