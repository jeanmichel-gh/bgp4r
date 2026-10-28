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


require 'bgp/nlris/nlri'
require 'bgp/orfs/orf'

module BGP
  
  class Prefix_entry < Orf::Entry
    
    # RFC 5291 section 4: Action is the top two bits of the common part.
    ADD        = 0
    REMOVE     = 1
    REMOVE_ALL = 2

    def initialize(*args)
      if args[0].is_a?(String) and args[0].is_packed?
        _parse_(*args)
      elsif args.size==6
        @action, @match, @seqn, @min, @max, prefix = args
        @prefix = BGP::Prefix.new(prefix) 
      elsif args.size==4
        @min, @max = 0, 0
        @action, @match, @seqn, prefix = args
        @prefix = BGP::Prefix.new(prefix) 
      elsif args.size==1 and args[0].is_a?(Hash)
        set(args[0])
      else
        raise ArgumentError, "invalid argument: #{args.inspect}"
      end
    end
    
    # RFC 5291 section 4: Action is a two bit field, ADD (0), REMOVE (1) and
    # REMOVE-ALL (2). 3 has no meaning there but it fits the field and comes
    # off the wire, so it is kept. A value the two bits cannot hold is
    # refused, because encoding it would put a different one on the wire.
    def action=(val)
      case val
      when :add        ; @action=ADD
      when :remove     ; @action=REMOVE
      when :remove_all ; @action=REMOVE_ALL
      when Integer
        raise "invalid action: #{val.inspect}" unless (0..3) === val
        @action=val
      else
        raise "invalid action: #{val.inspect}"
      end
    end
    
    def action_to_i
      @action
    end

    def action_to_s
      case @action
      when 0 ; 'add'
      when 1 ; 'remove'
      when 2 ; 'remove all'
      else
        'unknown action'
      end
    end
    
    def match_to_i
      @match
    end

    def match_to_s
      case @match
      when 0 ; 'permit'
      when 1 ; 'deny'
      end
    end

    # RFC 5291 section 4: Match is one bit, PERMIT (0) or DENY (1), so 2 is
    # refused rather than truncated.
    def match=(val)
      case val
      when 0, :permit ; @match=0
      when 1, :deny   ; @match=1
      else
        raise "invalid match: #{val.inspect}"
      end
    end
    
    def set(h)
      # || and not ||=: the caller's hash is not ours to write defaults into.
      self.action = h[:action] || 0
      self.match = h[:match] || 0
      @seqn = h[:seqn] || 0
      @min = h[:min] || 0
      @max = h[:max] || 0
      @prefix = BGP::Prefix.new(h[:prefix]) if h[:prefix]
    end

    def encode
      # RFC 5291 section 4: an entry with no type specific part is the common
      # part alone, which is what a REMOVE-ALL entry is. RFC 5292 section 3
      # puts Sequence, Minlen, Maxlen and the prefix in the others.
      return [_first_octet_].pack('C') if @prefix.nil?
      [_first_octet_,@seqn, @min, @max, @prefix.encode(true)].pack('CNCCa*')
    end
    
    def to_hash
      h = {:action=> @action, :match=> @match}
      return h if @prefix.nil?
      h.merge({:seqn=> @seqn, :min=> @min, :max=> @max, :prefix=> @prefix.to_s})
    end

    def to_s
       return action_to_s if @prefix.nil?
       s = format("seq %3s %6s %s", @seqn, action_to_s, @prefix)
       s += " ge #{@min}" if @min>0
       s += " le #{@max}" if @max>0
       s +=  " #{match_to_s}"
       s
    end
      
    private
    
    def _first_octet_
      (@action<<6) | ((@match & 0x1) << 5)
    end
    
    def size
      # RFC 5291 section 4: a REMOVE-ALL entry is one octet, the common part.
      return 1 if @prefix.nil?
      @prefix.nbytes+7+1
    end
    
    def _parse_(s, afi=1)
      o1 = s.unpack('C')[0]
      @action = o1 >> 6
      @match = (o1 >> 5) & 1
      if @action==REMOVE_ALL
        # RFC 5291 section 4: a REMOVE-ALL entry has no type specific part.
        @seqn, @min, @max, @prefix = 0, 0, 0, nil
      else
        _, @seqn, @min, @max, prefix = s.unpack('CNCCa*')
        @prefix = BGP::Prefix.new_ntop(prefix.is_packed, afi)
      end
      s.slice!(0,size)
    end

    def self.add(*args) ; Prefix_entry.new(0,*args)  ; end
    def self.add_and_deny(*args) ; Prefix_entry.new(0,1,*args) ; end
    def self.add_and_permit(*args) ; Prefix_entry.new(0,0,*args) ; end
    def self.remove(*args) ; Prefix_entry.new(1,*args)  ; end
    def self.remove_and_deny(*args) ; Prefix_entry.new(1,1,*args) ; end
    def self.remove_and_permit(*args) ; Prefix_entry.new(1,0,*args) ; end
    # RFC 5291 section 4: a REMOVE-ALL entry is the common part alone, and
    # the Match field only means something for ADD and REMOVE, so there is
    # nothing else to pass.
    def self.remove_all ; Prefix_entry.new(:action=>REMOVE_ALL, :match=>0) ; end

  end
    
end

class BGP::Prefix_orf < BGP::Orf
    
  def initialize(*args)
    if args[0].is_a?(String) and args[0].is_packed?
      _parse_(*args)
    elsif args[0].is_a?(self.class) and args[0].respond_to?(:encode)
      _parse_(args[0].encode, *args[1..-1])
    elsif args.size==1 and args[0].is_a?(Hash)
      @type = args[0][:type] || BGP::ORF::PREFIX
      @entries = []
      [args[0][:entries]].flatten.compact.each do |e|
        add(e.is_a?(BGP::Prefix_entry) ? e : BGP::Prefix_entry.new(e))
      end
    else
      super(BGP::ORF::PREFIX, *args)
    end
  end
  
  def add(e)
    raise ArgumentError, "invalid argument: #{e.inspect}, expected a #{BGP::Prefix_entry}" unless e.is_a?(BGP::Prefix_entry)
    super(e)
  end

  def _parse_(s, afi=1)
    @entries=[]
    @type, _, entries = s.unpack('Cna*')
    while entries.size>0
      # RFC 5292 section 2: the prefix of an entry is read in the address
      # family of the ROUTE-REFRESH message that carries the ORF.
      @entries << BGP::Prefix_entry.new(entries.is_packed, afi)
    end
  end
  
  def to_hash
    {:type=> @type, :entries=> @entries.collect { |e| e.to_hash }}
  end

  # The vendor code point of the RFC 5291 section 7 range, 130. No RFC
  # describes it; it is the type octet bgp4r sends for a Cisco style prefix
  # ORF. Orf.factory reads it back as a prefix ORF, since only the type
  # octet differs from RFC 5292's 64.
  def cisco_prefix_entry_type
    @type=BGP::ORF::PREFIX_CISCO
  end

end

load "../../test/unit/orfs/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


  2. Address Prefix ORF-Type

     The Address Prefix ORF-Type allows one to express ORFs in terms of
     address prefixes. That is, it provides address prefix based route
     filtering, including prefix length or range based matching, as well
     as wild-card address prefix matching.

     Conceptually an Address Prefix ORF entry consists of the fields
     <Sequence, Match, Length, Prefix, Minlen, Maxlen>.

     The "Sequence" field specifies the relative ordering of the entry
     among all the Address Prefix ORF entries.

     The "Match" field specifies whether this entry is "PERMIT" (value 0),
     or "DENY" (value 1).

     The "Length" field indicates the length in bits of the address
     prefix. A length of zero indicates a prefix that matches all (as
     specified by the address family) addresses (with prefix itself of
     zero octets).

     The "Prefix" field contains an address prefix of an address family.

     The "Minlen" field indicates the minimum prefix length in bits that
     is required for "matching". The field is considered as un-specified
     with value 0.

     The "Maxlen" field indicates the maximum prefix length in bits that
     is required for "matching". The field is considered as un-specified
     with value 0.

     The fields "Sequence", "Length", "Minlen", and "Maxlen" are all
     unsigned integers.

     This document imposes the following requirement on the values of
     these fields:

             0 <= Length < Minlen <= Maxlen

     In addition, the "Maxlen" must be no more than the maximum length (in
     bits) of a host address for a given address family [BGP-MP].


  3. Address Prefix ORF Encoding

     The value of the ORF-Type for the Address Prefix ORF-Type is 64.

     An Address Prefix ORF entry is encoded as follows. The "Match" field
     of the entry is encoded in the "Match" field of the common part [BGP-
     ORF], and the remaining fields of the entry is encoded in the "Type
     specific part" as shown in Figure 1.


                 +--------------------------------+
                 |   Sequence (4 octets)          |
                 +--------------------------------+
                 |   Minlen   (1 octet)           |
                 +--------------------------------+
                 |   Maxlen   (1 octet)           |
                 +--------------------------------+
                 |   Length   (1 octet)           |
                 +--------------------------------+
                 |   Prefix   (variable length)   |
                 +--------------------------------+

                Figure 1: Address Prefix ORF Encoding


     Note that the Prefix field contains the address prefix followed by
     enough trailing bits to make the end of the field fall on an octet
     boundary.  The value of the trailing bits is irrelevant.

