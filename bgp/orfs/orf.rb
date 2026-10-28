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


module BGP
  module ORF
    # RFC 5292 section 3: "The value of the ORF-Type for the Address Prefix
    # ORF-Type is 64."
    PREFIX = 64
    # RFC 5291 section 7 leaves the ORF-Type values 128 through 255 to
    # vendors: they "are not to be assigned by IANA". 130 is the vendor code
    # point bgp4r sends for the Cisco style prefix ORF, from
    # Prefix_orf#cisco_prefix_entry_type. No RFC describes it, so this is a
    # vendor convention and not a citation.
    PREFIX_CISCO = 130
  end

  class Orf

    class Entry
    end

    attr_accessor :type, :entries

    def initialize(*args)
      @entries=[]
      if args[0].is_a?(String) and args.size==1
        parse(args[0])
      elsif args.size==1 and args[0].is_a?(self.class) and args[0].respond_to?(:encode)
        parse(args[0].encode)
      else
        @type, *arr = args
        arr.flatten.each { |e| add(e) }
      end
    end

    # An ORF carries ORF entries and nothing else. Something that is not an
    # Entry at all is a caller mistake, not a wire shape the RFC happens to
    # forbid, and there is no field it could go in, so it is refused. Adding
    # it to no effect would build an ORF with no entry, which a router takes
    # and ignores while the caller hears nothing.
    def add(e)
      raise ArgumentError, "invalid argument: #{e.inspect}, expected an ORF entry" unless e.is_a?(Entry)
      @entries << e
      self
    end
    alias << add

    # The octets of ORF entries this class could not read. Kept so that
    # encode returns byte for byte what arrived. Empty once a subclass has
    # read the entries into Entry objects.
    def value
      @value ||= String.new
    end

    # The Length of ORF entries that arrived, when it is not the number of
    # entry octets that came with it. Kept so that encode writes back the
    # length the peer sent rather than the length that is really there, and
    # nil on an ORF built from values, which always writes its own.
    attr_reader :declared_len

    # RFC 5291 section 4: an ORF is an ORF Type (1 octet), a Length of ORF
    # entries (2 octets) and that many octets of entries. Reading an entry
    # takes the ORF Type, so a subclass that knows the type does that; here
    # the entry octets are kept as they are.
    def parse(s, afi=1)
      @entries=[]
      @type, len = s.unpack('Cn')
      # Fewer than three octets is not an ORF header, so there is no Length
      # of ORF entries to trust and the rest is taken as it stands. Orf
      # .factory answers nil for those octets now, so this is the path of a
      # caller that built an Orf from them directly.
      octets = s.slice!(0, len ? len+3 : s.size)
      @value = octets.size>3 ? octets[3..-1] : String.new
      # A Length longer than the octets that followed it. encode used to
      # write the length that was really there, so an ORF that said 9 and
      # carried 2 came back saying 2, and the message a negative test had
      # captured could not be sent again.
      @declared_len = len if len and len != @value.size
      self
    end

    def encode
      # RFC 5291 section 4: ORF Type, Length of ORF entries, the entries.
      # Entries this class read, then the octets it could not: an ORF Type
      # with no class of its own has all of them in @value, and a prefix ORF
      # whose entry list was cut short has the remainder there.
      entries = @entries.collect { |e| e.encode }.join + value
      [@type, @declared_len || entries.size, entries].pack('Cna*')
    end

    def to_s
      "#{self.class}, #{@entries.size} entries:\n  " + @entries.collect { |e| e.to_s}.join("\n  ")
    end

    # RFC 5291 section 4: an ORF Type bgp4r does not implement keeps its ORF
    # Type octet and the octets of its entries and writes them back, rather
    # than raising and taking the whole ROUTE-REFRESH with it. The library is
    # here to send what a router may not expect, and an ORF it can send but
    # not read back is the worst shape of bug for a test tool, because the
    # operator cannot look at what they just sent. RFC 5291 section 7 leaves
    # the types 128 to 255 to vendors, so an ORF off the wire may well be one
    # no RFC describes.
    #
    # All three build paths:
    #   Orf::Unknown.new(65, 'value')
    #   Orf::Unknown.new(wire_bytes)
    #   Orf::Unknown.new(:type=>65, :value=>'76616c7565')
    #
    # Nothing is checked: any type, any length, any octets.
    class Unknown < Orf

      def initialize(*args)
        @entries=[]
        @value=String.new
        if args[0].is_a?(String) and args[0].is_packed?
          parse(*args)
        elsif args.size==1 and args[0].is_a?(Unknown)
          parse(args[0].encode.is_packed)
        elsif args.size==1 and args[0].is_a?(Hash)
          @type = args[0][:type].to_i
          @value = [args[0][:value].to_s].pack('H*')
          @declared_len = args[0][:length].to_i if args[0][:length]
        elsif (1..2).include?(args.size) and args[0].is_a?(Integer)
          @type = args[0]
          @value = args[1].to_s.b
        else
          raise ArgumentError, "invalid argument: #{args.inspect}, " \
                               "expected (type, value), wire bytes or a hash"
        end
      end

      # :length only when the Length that arrived is not the number of
      # entry octets, since that is the only time a build from the value
      # alone would write a different one. An ordinary ORF has no such key,
      # so its hash is the two it has always been.
      def to_hash
        h = {:type=> @type}
        h[:value] = value.unpack('H*')[0] unless value.empty?
        h[:length] = @declared_len if @declared_len
        h
      end

      def to_s
        s = "#{self.class}, ORF type #{@type}, #{value.size} entry octets: [#{value.unpack('H*')[0]}]"
        s += ", Length of ORF entries says #{@declared_len}" if @declared_len
        s
      end

    end

  end

end

__END__

  
  an ORF as a type and entries, RFC 5291 section 4

   +--------------------------------------------------+
   | ORF Type (1 octet)                               |
   +--------------------------------------------------+
   | Length of ORF entries (2 octets)                 |
   +--------------------------------------------------+
   | First ORF entry (variable)                       |
   +--------------------------------------------------+
   | Second ORF entry (variable)                      |
   +--------------------------------------------------+
   | ...                                              |
   +--------------------------------------------------+
   | N-th ORF entry (variable)                        |
   +--------------------------------------------------+
  
  http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-9
  
