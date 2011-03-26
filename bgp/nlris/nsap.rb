
require 'bgp/common'
require 'bgp/iana'

module BGP

class Nsap
  
  # FIXME: an Iso class    Nsap < Iso with limiting len to 156
  
  def self.new_nsap(s)
    pfx,len = s.split('/')
    len ||= 152
    # puts [pfx, (len.to_i > 152 ? 152 : len)].join('/')
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
  def hton(*args)
    case afi
    when 1
      ['47000601',super()].pack('H8a*')
    when 2
      ['350000',super()].pack('H6a*')
    end
  end
  alias :encode :hton
end
end

include BGP
# 
# s = '49.0001.0002.0003.0004.0005.0006/64'
# n = Nsap.new_nsap(s)
# p n
# p n.to_shex


load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
