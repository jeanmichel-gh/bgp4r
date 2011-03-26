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
require 'bgp/nlris/prefix2'
module BGP


  #
  # Container for prefix(1,1) 
  #
  class Base_nlri
    
    attr_reader :nlris
    
    class << self
      def new_ntop(s, path_id=nil)
        nlri = new
        while s.size>0
          #TODO if only used for afi 1, this parameter is not needed
          #TODO wait until other afi are coded....
          nlri.add Prefix.new_ntop_extended(s,1) if path_id
          nlri.add Prefix.new_ntop(s,1)          unless path_id
        end
        nlri
      end
      
    end
    
    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        add(*args)
      end
    end
    def add(*args)
      @nlris ||=[]
      args.each { |arg|
        case arg
        when Hash
          if arg.has_key? :path_id
            @nlris << Prefix.new(arg[:path_id], arg[:nlri])
          else
            raise
          end
        when String
          o = Prefix.new(arg)
          @nlris << o
        when Array
          if arg[0].is_a?(Integer)
            @nlris << Prefix.new(*arg)
          else
            raise
          end
        when Prefix
          @nlris << arg
        else
          raise ArgumentError, "Invalid argument #{arg.class} #{arg.inspect}"
        end
      }
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
      @nlris.join("\n#{([' ']*indent).join}")
    end

    def size
      @nlris.size
    end

  end

  Nlri      = Class.new(Base_nlri)
  Withdrawn = Class.new(Base_nlri)
  
  
  # TODO: Nlri.factory() is about build nlri_elements ... 
  # 

  class Nlri
    def self.factory(s, afi, safi, path_id=nil)
      
      if afi== 1 and safi==1
        Nlri.new_ntop(s.is_packed, path_id)
      else
        case safi
        when 1,2
          # FIXME: add a path_id arg ... same as Labeld.new_ntop ... to be consistent.
          p = Prefix.new_ntop(s.is_packed, afi)
          p.path_id=path_id if path_id
          p
        when 4,128,129
          # The prefix will contain the path_id if any.
          Labeled.new_ntop(s.is_packed, afi, safi, path_id)
        else
          raise RuntimeError, "Afi #{afi} Safi #{safi} not supported!"
        end
      end
    end
  end
  
end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


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



===

# class Nlri_element < IPAddr
# 
#   def to_s
#     [super, mlen].join('/')
#   end
#   def encode_next_hop
#     hton
#   end
#   def nbyte
#     (mlen+7)/8
#   end
#   def encode(len_included=true)
#     nbyte = (mlen+7)/8
#     if len_included
#       [mlen, hton].pack("Ca#{nbyte}")
#     else
#       [hton].pack("a#{nbyte}")
#     end
#   end
#   def parse(arg)
#     s = arg.dup
#     s +=([0]*3).pack('C*')
#     plen, *nlri = s.unpack('CC4')
#     arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
#     ipaddr = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
#   end
#   alias :parse4 :parse
#   def parse6(arg)
#     s = arg.dup
#     s +=([0]*16).pack('C*')
#     plen, *nlri = s.unpack('Cn8')
#     arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
#     ipaddr = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
#   end
# end
# 
# class Ip4 < Nlri_element
#   def initialize(arg)
#     if arg.is_a?(String) and arg.packed?
#       super(parse4(arg))
#     elsif arg.is_a?(Ip4)
#       super(arg.to_s)
#     else
#       super(arg)
#     end
#   rescue => e
#     p e
#     p arg
#     raise
#   end
# end
# 
# class Ip6 < Nlri_element
#   def initialize(arg)
#     if arg.is_a?(String) and arg.packed?
#       super(parse6(arg))
#     elsif arg.is_a?(Ip6)
#       super(arg.to_s)
#     else
#       super(arg)
#     end
#   end
# end
# 
# class Ext_Nlri_element < Nlri_element
#   def initialize(*args)
#     if args.size>1
#       @path_id = args.shift
#       super
#     elsif args.size==1 and args[0].is_a?(String)
#       super parse(*args)
#     elsif args.size==1 and args[0].is_a?(Hash)
#       @path_id=args[0][:path_id]
#       super args[0][:nlri_element]
#     else
#       raise
#     end
#   rescue => e
#     p e
#     p args
#     raise
#   end
#   attr_reader :path_id
#   def encode
#     [path_id, super].pack('Na*')
#   end
#   def to_s
#     "ID: #{path_id}, #{super}"
#   end
#   def parse(s)
#     @path_id = s.slice!(0,4).unpack('N')[0]
#     super s
#   end
# end
# 

