#--
# Copyright 2011 Jean-Michel Esnault.
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
  
  def self.new_nsap(s)
    pfx,len = s.split('/')
    len ||= 152
    new [pfx, (len.to_i > 152 ? 152 : len)].join('/')
  end
  def self.new_ntoh(s)
    sbin = s.dup
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
    s = [o1, r.scan(/..../).collect { |x| r.slice!(0,4)},r].flatten.join('.')
    # mlen < 160 ? [s, mlen].join('/') : s
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
  
  def netmask
    0xffffffffffffffffffffffffffffffffffffffff - (2**(160-mlen)) +1
  end
  def netmask_to_c
    @netmask_to_c ||= [netmask.to_s(16)].pack('H*').unpack('C*')
  end
  def apply_mask
    @nsap.each_with_index { |v,i| @nsap[i] = v & netmask_to_c[i] }
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
