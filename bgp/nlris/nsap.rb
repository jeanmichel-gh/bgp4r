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

module BGP

class Nsap
  
  # The bits of a 20 octet NSAP address, which is as much as this class
  # holds: @nsap is always exactly 20 octets and encode writes
  # (mlen+7)/8 of them. A Length field wider than this is kept by
  # Prefix, which carries the octets past the twenty in its @tail and
  # reports the Length it was given.
  MAX_MLEN = 160

  def self.new_nsap(s)
    pfx,len = s.split('/')
    # The ceiling used to be 152, which is 19 octets, so a /160 prefix
    # came back as a /152 and lost its twentieth octet. 160 is what the
    # rest of the class is built around: Nsap#mlen defaults to it and
    # prefix_mask_bits masks against it.
    len ||= 152
    new [pfx, (len.to_i > MAX_MLEN ? MAX_MLEN : len)].join('/')
  end
  def self.new_ntoh(s)
    o1, r = s.unpack('H2H*')
    new [o1, r.scan(/..../).collect { |x| r.slice!(0,4)}, r].flatten.join('.').chomp('.')
  end
  def initialize(arg='49')
    nsap, @mlen = arg.split('/')
    @nsap = ([nsap.gsub(/\./,'')].pack('H*').unpack('C*')+[0]*19)[0...20]
    apply_mask
  end
  def iso? ; true ; end
  def to_s
    o1, r = hton.unpack('H2H*')
    [o1, r.scan(/..../).collect { |x| r.slice!(0,4)},r].flatten.join('.')
  end
  def mlen
    @mlen ||= 160
    @mlen.to_i
  end
  def hton
    @nsap.pack("C*")
  end
  def encode(*args)
    @nsap.pack("C#{(mlen+7)/8}")
  end

  private
  
  # The prefix mask of a 160 bit (20 octet) NSAP address, as an Integer:
  # mlen one bits, then zeros. Not related to IPAddr#netmask.
  def prefix_mask_bits
    0xffffffffffffffffffffffffffffffffffffffff - (2**(160-mlen)) +1
  end
  # The same mask as 20 octets, to AND with @nsap.
  def prefix_mask_octets
    @prefix_mask_octets ||= [prefix_mask_bits.to_s(16)].pack('H*').unpack('C*')
  end
  def apply_mask
    @nsap.each_with_index { |v,i| @nsap[i] = v & prefix_mask_octets[i] }
  end
  
end

class Iso_ip_mapped < IPAddr
  def afi
    if ipv4? 
      1
    else
      2
    end
  end
  def nexthop
    to_s
  end
  def encode_next_hop(safi=nil)
    s = case afi
    when 1
      ['47000601',hton,0].pack('H8a*C')
    when 2
      ['350000',hton,0].pack('H6a*C')
    end
    s = ([0]*8).pack('C8') + s if (128..129) === safi
    s
  end
  alias encode encode_next_hop
end

unless const_defined?(:Nsap_unicast)
  [:unicast, :multicast].each do |n|
    inet_klass = Class.new(Nsap) do
      define_method(:safi) do
        @safi ||=IANA::SAFI.const_get("#{n.to_s.upcase}_NLRI")
      end
    end
    const_set("Nsap_#{n}", inet_klass)
  end
end


end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
