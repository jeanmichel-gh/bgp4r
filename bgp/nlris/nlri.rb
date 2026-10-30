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
require 'bgp/iana'
require 'bgp/nlris/prefix'
# Nlri.factory names Flow_spec, so it has to be loaded. No cycle: nothing
# under flow_spec.rb reaches back to this file.
require 'bgp/nlris/flow_spec'
module BGP

  class Base_nlri
    
    attr_reader :nlris
    
    class << self
      def new_ntop(s, path_id=nil, afi=IANA::AFI::IPv4)
        new.parse(s, path_id, afi)
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
          # "ID=100, 10.0.0.0/8" is how to_ary writes a prefix with an
          # add-path Path Identifier (RFC 7911 section 3). Read it back so
          # to_hash round trips through new.
          if arg =~ /\AID=(\d+), (.+)\z/
            @nlris << Prefix.new($1.to_i, $2)
          else
            @nlris << Prefix.new(arg)
          end
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

    # RFC 4271 section 4.3: the Withdrawn Routes field and the Network Layer
    # Reachability Information field are each a list of 2-tuples of the form
    # <length, prefix>, packed one after the other with nothing between them.
    # Length is the prefix length in bits, and Prefix carries the prefix
    # followed by the minimum number of trailing bits that make the field end
    # on an octet boundary, so a tuple is 1+(length+7)/8 octets. A length of
    # zero is a prefix matching every address, and takes its one length octet
    # and no prefix octet.
    #
    # Prefix.new_ntop reads one such tuple and removes its octets from the
    # String, so read tuples until none are left. The old code handed the
    # whole String to add, which gave it to Prefix.new and then IPAddr.new,
    # and that raised on anything but a zero length field.
    #
    # The address family is IPv4 because RFC 4271 section 3 defines "IP
    # address" as an IP version 4 address, and section 4.3 lists IP address
    # prefixes. Other families travel in MP_REACH_NLRI and MP_UNREACH_NLRI
    # (RFC 4760) and do not come here: Nlri.factory sends them to Prefix or
    # to Labeled. afi stays a parameter with that default because the
    # collection holds any family when it is built from values, and reading
    # back the bytes it then encodes needs the family named.
    def parse(s, path_id=nil, afi=IANA::AFI::IPv4)
      @nlris ||=[]
      s = s.dup
      until s.empty?
        left = s.size
        add Prefix.send((path_id ? :new_ntop_extended : :new_ntop ), s, afi)
        # A backstop. Every family Prefix.new_ntop reads consumes at least
        # its length octet, so nothing reaches this today, but afi is a
        # parameter and an infinite loop on received octets is worse than
        # giving up on the rest of a field.
        break unless s.size < left
      end
      self
    end

    # RFC 7606 section 5.3: the field is syntactically incorrect when a
    # prefix in it is. Reported, not raised; see
    # Prefix#syntactically_correct?.
    def syntactically_correct?
      @nlris.all? { |n| n.syntactically_correct? }
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
    # withdrawn: see Labeled.new_ntop. It only reaches the labeled SAFIs,
    # because they are the only ones whose NLRI carries a label for RFC
    # 8277 section 2.4 to replace.
    def self.factory(s, afi, safi, path_id=nil, withdrawn=false)
      if afi== 1 and safi==1
        Nlri.new_ntop(s.is_packed, path_id)
      else
        case safi
        when 1,2
          Prefix.new_ntop(s.is_packed, afi, path_id)
        when 4,128,129
          Labeled.new_ntop(s.is_packed, afi, safi, path_id, withdrawn)
        when 133,134
          # RFC 8955 section 4 and section 8. The octets handed here are
          # one whole 2-tuple, length field included, because
          # MpReachCommon::ClassMethods#nlri_size asked the family how
          # long it was. withdrawn means nothing to this family: there
          # is no label for RFC 8277 section 2.4 to replace.
          Flow_spec.new_ntop(s.is_packed, afi, safi, path_id)
        else
          # **This raise is load bearing: do not return an object
          # instead.** Path_attribute#decode_attribute rescues
          # StandardError and files an Attr::Gap, so the attribute comes
          # back as an Attr::Raw that encodes byte for byte and nothing
          # lands in #errors. Answering an object would delete the Gap
          # and make bgp4r claim it understood a family it does not.
          # See #116 and Conventions in CLAUDE.md.
          #
          # The #TODO that used to sit here asked for a typed exception
          # in place of this bare RuntimeError, which would still raise
          # and would name itself in the Gap. Still worth doing.
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

NOTE, 2026: everything below is RFC 3107, which RFC 8277 obsoletes. It is
kept because it is the text the labeled NLRI code was written from, not
because it is current. Read RFC 8277 instead. What changed that matters
here:

  - The 3 bits between the label value and the Bottom of Stack bit were
    the EXP field in RFC 3032; RFC 5462 renamed them Traffic Class, and
    RFC 8277 section 2.2 calls the field Rsrv, to be set to zero on
    transmission and ignored on reception. bgp4r calls it exp.
  - RFC 8277 section 2.2 says the S bit MUST be 1 on transmission and
    MUST be ignored on reception. Section 2.3 has it 0 on every label of
    a multi-label stack but the last.
  - The 0x800000 in the last paragraph below is no longer a label. RFC
    8277 section 2.4 replaces the Label field of a withdrawal with a
    Compatibility field, whose "value of this field is of no
    significance": it SHOULD be set to 0x800000 on transmission, for
    backward compatibility with the text below, and MUST be ignored on
    reception. Some implementations send 0x000000. bgp4r still reads it
    as a label; see "Known issues to work on" in CLAUDE.md.

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
