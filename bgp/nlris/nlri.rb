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
require 'bgp/nlris/prefix'
module BGP

  class Base_nlri
    
    attr_reader :nlris
    
    class << self
      def new_ntop(s, path_id=nil)
        nlri = new
        while s.size>0
          nlri.add Prefix.send((path_id ? :new_ntop_extended : :new_ntop ), s, 1)
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
    
    def empty?
      @nlris.empty?
    end

    def to_ary
      @nlris.collect { |n| n.to_s }
    end

  end

  unless const_defined?(:Nlri)
    Nlri      = Class.new(Base_nlri) do
      def to_hash
        {:nlris=>to_ary}
      end
    end
    Withdrawn = Class.new(Base_nlri) do
      def to_hash
        {:withdrawns=>to_ary}
      end
    end
  end
  class Nlri
    def self.factory(s, afi, safi, path_id=nil)
      if afi== 1 and safi==1
        Nlri.new_ntop(s.is_packed, path_id)
      else
        case safi
        when 1,2
          Prefix.new_ntop(s.is_packed, afi, path_id)
        when 4,128,129
          Labeled.new_ntop(s.is_packed, afi, safi, path_id)
        else
          #TODO class Error.....
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
