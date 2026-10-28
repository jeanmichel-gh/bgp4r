#--
# Copyright 2011, 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 

require 'bgp/common'
require 'bgp/iana'

require 'bgp/nlris/nsap'

module BGP

class Prefix
  include BGP
  
  SUPPORTED_AFIS = '1 or :ipv4 (IPv4), 2 or :ipv6 (IPv6), 3 or :nsap (NSAP)'

  def self.unknown_afi(afi)
    ArgumentError.new("unknown AFI #{afi.inspect}, supported AFIs are #{SUPPORTED_AFIS}")
  end

  def self.new_ntop_extended(arg, afi=1)
    raise unknown_afi(afi) unless (1..3) === afi || [:nsap, :ipv4, :ipv6].include?(afi)
    path_id = arg.slice!(0,4).unpack('N')[0]
    new_ntop(arg,afi,path_id)
  end
  
  class << self
    def new_ntop(arg, afi=1, path_id=nil)
      tail = nil
      case afi
      when IANA::AFI::IPv4, :ipv4
        s = arg.dup
        # RFC 4271 section 4.3 gives a prefix one length octet and only the
        # octets the length needs, so pad to the four the unpack wants. Four
        # zeros, not three: a length of 0, the default route, carries no
        # prefix octets at all, and three left nlri one element short.
        s +=([0]*4).pack('C*')
        plen, *nlri = s.unpack('CC4')
        tail = kept_tail(arg, plen, 4)
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
      when IANA::AFI::IPv6, :ipv6
        s = arg.dup
        s +=([0]*16).pack('C*')
        plen, *nlri = s.unpack('Cn8')
        tail = kept_tail(arg, plen, 16)
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
      when IANA::AFI::NSAP, :nsap
        s = arg.dup
        plen, o1, r = s.unpack('CH2H*')
        # RFC 4271 section 4.3: a tuple is its length octet plus the
        # (length+7)/8 octets the prefix and its trailing bits take, which
        # is what encode writes. Consume them, as the two branches above
        # do. Without this the caller's String came back untouched, so
        # anything reading one prefix after another read these for ever.
        arg.slice!(0,1+(plen+7)/8)
        pfx = [o1, r.scan(/..../).collect { |x| r.slice!(0,4)}, r].flatten.join('.').chomp('.')  + "/" + plen .to_s
      else
        raise unknown_afi(afi)
      end
      prefix = path_id ? new(path_id, pfx) : new(pfx)
      prefix.tail = tail if tail
      prefix
    end

    private

    # The prefix octets past the ones the address family holds, zero
    # filled to the (length+7)/8 the Length field asks for (RFC 4271
    # section 4.3). nil when the length fits, which is every prefix an
    # RFC allows, so an ordinary prefix carries nothing extra.
    def kept_tail(arg, plen, fits)
      want = (plen+7)/8
      return nil if want <= fits
      t = arg.byteslice(1+fits, want-fits) || String.new
      t + ([0]*(want-fits-t.size)).pack('C*')
    end
  end

  def initialize(*args)
    @path_id, @tail, @mlen = nil, nil, nil
    if args.size>1 and args[0].is_a?(Integer)
      @path_id, pfx, _ = args
    elsif args.size==1 and args[0].is_a?(Hash)
      @path_id = args[0][:path_id]
      @tail = [args[0][:tail]].pack('H*') if args[0][:tail]
      pfx = args[0][:prefix]
    else
      pfx, _ = args
    end
    if pfx =~ /^49\./
      @pfx = Nsap.new_nsap(pfx)
    else
      @pfx = new_ipaddr(pfx)
    end
  end
  [:iso, :ipv4, :ipv6].each do |afi|
    # @pfx is an IPAddr (no iso?) or an Nsap (no ipv4?/ipv6?).
    define_method("#{afi}?") do
      @pfx.respond_to?("#{afi}?") ? @pfx.send("#{afi}?") : false
    end
  end
  
  attr_reader :path_id

  # The prefix octets a Length field too wide for its address family
  # left over. nil for every prefix an RFC allows. See new_ipaddr.
  attr_reader :tail

  def path_id=(val)
    @path_id=val
  end

  def tail=(val)
    @tail=val
  end

  # False when the Length field is wider than the address family holds.
  # RFC 7606 section 5.3 calls that a syntactically incorrect NLRI field,
  # and RFC 4271 section 6.3 answers one with the Invalid Network Field
  # subcode. Parsing reports the fault here and keeps the octets rather
  # than raising. Nothing in bgp4r acts on it: the nlris layer takes no
  # receive policy and has no errors list, the way Path_attribute does.
  def syntactically_correct?
    @mlen.nil?
  end

  def extended?
    !@path_id.nil?
  end

  def afi
    @afi ||= if self.ipv4? 
      1
    elsif self.ipv6? 
      2
    elsif self.iso?
      3
    end
  end
  
  def to_s
    if extended?
      ["ID=#{@path_id}", pfx_to_s].join(', ')
    else
      pfx_to_s
    end
  end
  
  def to_s_with_afi
    if extended?
      ["ID=#{@path_id}", [IANA.afi?(afi), pfx_to_s].join('=')].join(', ')
    else
      [IANA.afi?(afi), pfx_to_s].join('=')
    end
  end
  
  def to_hash
    h = {:prefix=> pfx_to_s}
    h[:path_id] = @path_id if extended?
    # A kept tail travels with the hash, so what to_hash returns still
    # round trips through new byte for byte. No tail, no key, so an
    # ordinary prefix hashes as it always has.
    h[:tail] = @tail.unpack1('H*') if @tail
    h
  end
  
  def nexthop
    to_s.split('/')[0]
  end
  
  def encode(*args)
    __encode__(*args)
  end
  
  def encode_next_hop(*args)
    __encode__(false,false)
  end
  
  def encode_without_len_without_path_id
    __encode__(false,false)
  end
  
  def encode_with_len_without_path_id
    __encode__(true,false)
  end
  
  
  def include_len?
    ipv4? || ipv6?
  end
  
  # The length the Length field carries, which is the one the prefix was
  # given even when its family cannot hold it (RFC 4271 section 4.3).
  def mlen
    @mlen || @pfx.mlen
  end
  alias :bit_length :mlen
  
  def nbytes
    (mlen+7)/8
  end
  def pfx_to_s
    [@pfx,mlen.to_s].join('/')
  end
  
  private

  # RFC 4271 section 4.3 makes the Length field the length in bits of the
  # prefix and puts no ceiling on it, so a received length can be wider
  # than its address family. RFC 7606 section 5.3 calls such a field
  # syntactically incorrect, but receiving is where that is reported, not
  # raised, so keep the length here and hand IPAddr the widest mask its
  # family holds. Building is never checked either: a length no RFC
  # allows has to be sendable.
  def new_ipaddr(pfx)
    IPAddr.new(pfx)
  rescue IPAddr::InvalidPrefixError
    addr, mlen = pfx.to_s.split('/')
    @mlen = mlen.to_i
    IPAddr.new(addr)
  end

  def __encode__(len=true, include_path_id=true)
    octets = @tail ? @pfx.hton + @tail : @pfx.hton
    s = if len
      [mlen, octets].pack("Ca#{nbytes}")
    else
      [octets].pack("a#{nbytes}")
    end
    if extended? and include_path_id
      [@path_id, s].pack('Na*')
    else
      s
    end
  end
  
end

#s = '00000064200a000000'
#pfx = Prefix.new_ntop([s].pack('H*'), 2)

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

