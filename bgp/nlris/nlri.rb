#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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
require 'bgp/iana'

module BGP

  class Base_nlri

    class Nlri_element < IPAddr
      def to_s
        [super, mlen].join('/')
      end
      def encode_next_hop
        hton
      end
      def nbyte
         (mlen+7)/8
      end
      def encode(len_included=true)
        nbyte = (mlen+7)/8
        if len_included
          [mlen, hton].pack("Ca#{nbyte}")
        else
          [hton].pack("a#{nbyte}")
        end
      end
      def parse4(arg)
        s = arg.dup
        s +=([0]*3).pack('C*')
        plen, *nlri = s.unpack('CC4')
        arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
        ipaddr = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
      end
      def parse6(arg)
        s = arg.dup
        s +=([0]*16).pack('C*')
        plen, *nlri = s.unpack('Cn8')
        arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
        ipaddr = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
      end
    end

    class Ip4 < Nlri_element
      def initialize(arg)
        if arg.is_a?(String) and arg.packed?
          super(parse4(arg))
        elsif arg.is_a?(Ip4)
          super(arg.to_s)
        else
          # p arg.class
          super(arg)
        end
      end
    end

    class Ip6 < Nlri_element
      def initialize(arg)
        if arg.is_a?(String) and arg.packed?
          super(parse6(arg))
        elsif arg.is_a?(Ip6)
          super(arg.to_s)
        else
          super(arg)
        end
      end
    end

    attr_reader :nlris

    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else
        add(*args)
      end
    end
    def add(*args)
      @nlris ||=[]
      # p args
      args.flatten.each { |arg| @nlris << Ip4.new(arg) }
    end
    alias << add

    def parse(s)
      @nlris ||=[]
      while s.size>0
        add(s)
      end
    end

    def encode(len_included=false)
      enc = @nlris.collect { |x| x.encode }.join
      if len_included
        [enc.size].pack('n') + enc
      else
        enc
      end
    end

    def to_s(indent=0)
      @nlris.join("\n#{[' ']*indent}")
    end
    
    def size
      @nlris.size
    end

  end

  class Nlri < Base_nlri
    def encode
      super
    end
  end
  class Withdrawn < Base_nlri
    def encode(len_included=true)
      super(len_included)
    end
  end

  class Nlri
    def self.factory(s, afi, safi)
      case safi
      when 1,2
        Prefix.new(s.is_packed, afi)
      when 4,128,129
        Labeled.new(s.is_packed, afi, safi)
      end
    end
  end

  class Path_Nlri < Nlri
    def initialize(*args)
      if args.size>1 and args[0].is_a?(Integer)
        @path=args.shift
        super(*args)
      elsif args[0].is_a?(self.class)
        # p 'HERE'
        # p args[0].to_shex
        parse args[0].encode
      else
        @path=0
        super
      end
    rescue => e
      p e
    end
    def path_id=(val)
      @path=(val)
    end
    def path_id
      @path
    end
    def path_id2ip
      IPAddr.new_ntoh([@path].pack('N')).to_s
    end
    def to_s(indent=0)
      sindent = [' ']*indent
      format "#{sindent}Path ID: %d  '%s': [0x%8.8x]\n#{sindent}%s",  path_id, path_id2ip, path_id, super
    end
    def encode
      [@path,super].pack('Na*')
    end
    def parse(s)
      @path = s.slice!(0,4).unpack('N')[0]
      super(s)
    end
  end
end

load "../../test/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


__END__


Nlri is a collection of Nlri_elements or a collection of Path_nlri_elements


Path_nlri_element

  - path_id
  - Nlri_element



3. Extended NLRI Encodings

   In order to carry the Path Identifier in an UPDATE message, the
   existing NLRI encodings are extended by prepending the Path
   Identifier field, which is of four-octets.

   For example, the NLRI encodings specified in [RFC4271, RFC4760] are
   extended as the following:


               +--------------------------------+
               | Path Identifier (4 octets)     |
               +--------------------------------+
               | Length (1 octet)               |
               +--------------------------------+
               | Prefix (variable)              |
               +--------------------------------+


   and the NLRI encoding specified in [RFC3107] is extended as the
   following:





Walton, et al        Expiration Date February 2011              [Page 3]





INTERNET DRAFT      draft-ietf-idr-add-paths-04.txt          August 2010


               +--------------------------------+
               | Path Identifier (4 octets)     |
               +--------------------------------+
               | Length (1 octet)               |
               +--------------------------------+
               | Label (3 octets)               |
               +--------------------------------+
               | ...                            |
               +--------------------------------+
               | Prefix (variable)              |
               +--------------------------------+


   The usage of the extended NLRI encodings is specified in the
   Operation section.
   
  
   
  =======
  
  RFC 3107          Carrying Label Information in BGP-4           May 2001
  
  
  3. Carrying Label Mapping Information

     Label mapping information is carried as part of the Network Layer
     Reachability Information (NLRI) in the Multiprotocol Extensions
     attributes.  The AFI indicates, as usual, the address family of the
     associated route.  The fact that the NLRI contains a label is
     indicated by using SAFI value 4.

     The Network Layer Reachability information is encoded as one or more
     triples of the form <length, label, prefix>, whose fields are
     described below:

        +---------------------------+
        |   Length (1 octet)        |
        +---------------------------+
        |   Label (3 octets)        |
        +---------------------------+
        .............................
        +---------------------------+
        |   Prefix (variable)       |
        +---------------------------+

     The use and the meaning of these fields are as follows:

        a) Length:

           The Length field indicates the length in bits of the address
           prefix plus the label(s).

        b) Label:

           The Label field carries one or more labels (that corresponds to
           the stack of labels [MPLS-ENCAPS]).  Each label is encoded as 3
           octets, where the high-order 20 bits contain the label value,
           and the low order bit contains "Bottom of Stack" (as defined in
           [MPLS-ENCAPS]).

        c) Prefix:

           The Prefix field contains address prefixes followed by enough
           trailing bits to make the end of the field fall on an octet
           boundary.  Note that the value of trailing bits is irrelevant.



  Rekhter & Rosen             Standards Track                     [Page 3]

  RFC 3107          Carrying Label Information in BGP-4           May 2001


     The label(s) specified for a particular route (and associated with
     its address prefix) must be assigned by the LSR which is identified
     by the value of the Next Hop attribute of the route.

     When a BGP speaker redistributes a route, the label(s) assigned to
     that route must not be changed (except by omission), unless the
     speaker changes the value of the Next Hop attribute of the route.

     A BGP speaker can withdraw a previously advertised route (as well as
     the binding between this route and a label) by either (a) advertising
     a new route (and a label) with the same NLRI as the previously
     advertised route, or (b) listing the NLRI of the previously
     advertised route in the Withdrawn Routes field of an Update message.
     The label information carried (as part of NLRI) in the Withdrawn
     Routes field should be set to 0x800000.  (Of course, terminating the
     BGP session also withdraws all the previously advertised routes.)
  
  
   

