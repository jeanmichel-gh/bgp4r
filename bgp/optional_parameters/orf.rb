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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP

class Orf < BGP::OPT_PARM::Capability

  # RFC 5291 section 5, "Outbound Route Filtering Capability", Figure 3:
  # Address Family Identifier (2 octets), Reserved (1), Subsequent
  # Address Family Identifier (1), Number of ORFs (1), then that many
  # pairs of ORF Type (1) and Send/Receive (1). The figure says "Number
  # of ORFs" where the section's own text says "Number of ORF Types";
  # they are the same field.
  #
  # Section 5 gives Send/Receive three values: "whether the sender is
  # (a) willing to receive ORF entries from its peer (value 1)", "(b)
  # would like to send ORF entries to its peer (value 2), or (c) both
  # (value 3) for the ORF Type".
  #
  # **Section 4 is a different layout** and a different reserved field:
  # the ORF entry inside a ROUTE-REFRESH, where "Reserved is a 5-bit
  # field. It is set to 0 on transmit and ignored on receipt". That
  # sentence is not about this octet, which section 5 labels in its
  # figure and never describes.
  class Entry

    attr_reader :afi, :safi, :types

    # The Reserved octet as it arrived, so encode gives it back. It was
    # unpacked into a throwaway and written as 0, so a capability
    # carrying a non-zero one could not be sent again: 0001ff0101 came
    # back as 0001000101. Section 5 says nothing about the field, which
    # is all the more reason to keep what arrived rather than invent a
    # value for it.
    attr_reader :reserved

    # new(afi, safi, [type, send_recv], ...), the wire octets, or its own
    # hash. The Hash branch was empty, so every field stayed nil and
    # encode raised; nothing could read this entry's hash because it had
    # none to read.
    def initialize(*args)
      @reserved = 0
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size==1 and args[0].is_a?(Hash)
        h = args[0]
        @afi, @safi = h[:afi], h[:safi]
        @reserved = h[:reserved].to_i
        @types = [h[:types]].flatten(1).compact.collect { |t| Array(t) }
      else
        @afi, @safi, *@types = *args
      end
    end

    def encode
      [@afi, @reserved, @safi, @types.size,@types.collect { |e| e.pack('CC')}.join].pack('nCCCa*')
    end

    def parse(s)
      @afi, @reserved, @safi, n = s.slice!(0,5).unpack('nCCC')
      @types=[]
      types = s.slice!(0, 2*n)
      while types.size>0
        @types<< types. slice!(0,2).unpack('CC')
      end
    end

    # The three fields the entry always has, plus the Reserved octet only
    # when it arrived set. Same rule as a kept tail: nothing unusual,
    # nothing new in the hash.
    def to_hash
      h = { :afi => @afi, :safi => @safi, :types => @types }
      h[:reserved] = @reserved unless @reserved.to_i.zero?
      h
    end

    def to_s
      "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi}): #{@types.inspect}"
    end
  end

  def initialize(*args)
    @entries=[]
    if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    else
      # Its own hash, {:code=>3, :capability=>{:entries=>[...]}}, and the
      # inner hash alone. Neither was read: a Hash fell through to the
      # bare super below and built a capability with no entries at all,
      # so 26 octets became 4 and nothing said so.
      if args.size==1 and args[0].is_a?(Hash)
        h = args[0]
        h = h[:capability] if h.key?(:capability)
        [h[:entries]].flatten.compact.each { |e| add Entry.new(e) }
      end
      super(OPT_PARM::CAP_ORF)
    end
  end

  def add(entry)
    @entries << entry
  end

  def encode(extended: false)
    super(@entries.collect { |e| e.encode }.join, :extended => extended)
  end

  def parse(s)
    entries = super(s)
    while entries.size>0
      @entries << Entry.new(entries)
    end
  end

  def to_s
    super + "\n    Outbound Route Filtering (#{@code}), length: #{encode.size}" +
    (['']+@entries.collect { |e| e.to_s }).join("\n      ")
  end

  # The entries, under the :capability key CAP::As4 and CAP::Mbgp use for
  # theirs. It used to inherit Capability's bare {:code=>3}, so every
  # Entry was lost, and since Capability.from_hash routes this code
  # straight back here, a round trip through the hash answered a
  # capability with nothing in it.
  def to_hash
    super.merge(:capability => { :entries => @entries.collect { |e| e.to_hash } })
  end

end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
