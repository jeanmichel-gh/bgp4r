
require 'bgp/common'
require 'bgp/iana'

require 'bgp/nlris/nsap'

class Prefix
  include BGP
  
  # TODO: 
  # renname factory ntop ???   ntop_extended ???
  def self.new_ntop_extended(arg, afi=1)
    # JME
    # puts 'IN NEW_TOP_EXT....'
    # puts 'IN NEW_TOP_EXT....'
    # puts 'IN NEW_TOP_EXT....'
    # puts 'IN NEW_TOP_EXT....'
    path_id = arg.slice!(0,4).unpack('N')[0]
    case afi
    when 1
      new_ntop(arg,afi,path_id)
    else
      raise
    end
  end
  
  class << self
    def new_ntop(arg, afi=1, path_id=nil)
      # p arg.unpack('H*'),afi, path_id
      case afi
      when IANA::AFI::IPv4
        #TODO: Testcase...
        s = arg.dup
        s +=([0]*3).pack('C*')
        plen, *nlri = s.unpack('CC4')
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
      when IANA::AFI::IPv6
        #TODO: Testcase...
        s = arg.dup
        s +=([0]*16).pack('C*')
        plen, *nlri = s.unpack('Cn8')
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
      when IANA::AFI::NSAP
        #TODO: Testcase...
        s = arg.dup
        plen, o1, r = s.unpack('CH2H*')
        pfx = [o1, r.scan(/..../).collect { |x| r.slice!(0,4)}, r].flatten.join('.').chomp('.')  + "/" + plen .to_s
      else
        raise
      end
      path_id ? new(path_id, pfx) : new(pfx)
    end
  end


  def initialize(*args)
    @path_id=nil
    # JME p args
    if args.size>1 and args[0].is_a?(Integer)
      @path_id, pfx, afi = args
    else
      pfx, afi = args
    end
    if pfx =~ /^49\./
      @pfx = Nsap.new_nsap(pfx)
    else
      @pfx = IPAddr.new(pfx)
    end
  end
  [:iso, :ipv4, :ipv6].each do |afi|
    define_method("#{afi}?") do
      begin
        @pfx.send "#{afi}?"
      rescue
      end
    end
  end
  
  attr_reader :path_id
  
  def path_id=(val)
    @path_id=val
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
  
  # attr_reader :mlen
  # alias bit_length mlen
  
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
  
  def nexthop
    to_s.split('/')[0]
  end
  
  def encode(*args)
    __encode__(*args)
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
  
  def mlen
    @pfx.mlen
  end
  alias :bit_length :mlen
  
  private 
  def nbytes
    nbyte = (mlen+7)/8
  end
  def pfx_to_s
    [@pfx,mlen.to_s].join('/')
  end
  
  private 
  
  # 
  #  all labeled safi need not include path_id
  #  
  def __encode__(len=true, include_path_id=true)
    s = if len
      [mlen, @pfx.hton].pack("Ca#{nbytes}")
    else
      [@pfx.hton].pack("a#{nbytes}")
    end
    if extended? and include_path_id
      [@path_id, s].pack('Na*')
    else
      s
    end
  end
  
end

# include BGP
# 
# 
# pfx =  Prefix.new('49.0001.0002.0003/12')
# p pfx
# p pfx.to_shex
# 


load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

__END__


TODO: Look at valid test and verify they all pass




require "test/unit"

# require "Prefix"

class TestPrefix < Test::Unit::TestCase
  def test_inet
    pfx =  Prefix.new_inet('10.0.0.0')
    assert_equal('10.0.0.0/32', pfx.to_s)
    assert_equal('200a000000', pfx.to_shex)
    pfx =  Prefix.new_inet('10.1.1.1/16')
    assert_equal('10.1.0.0/16', pfx.to_s)
    assert_equal('100a01', pfx.to_shex)
    pfx =  Prefix.new_inet('10.255.255.255/17')
    assert_equal('10.255.128.0/17', pfx.to_s)
    assert_equal('110aff80', pfx.to_shex)

  end
  def test_inet6
    pfx =  Prefix.new_inet6('2011:13:11::0/64')
    assert_equal('2011:13:11::/64', pfx.to_s)
    assert_equal('402011001300110000', pfx.to_shex)
    pfx =  Prefix.new_inet6('2011:13:11::0')
    assert_equal('2011:13:11::/128', pfx.to_s)
    assert_equal('8020110013001100000000000000000000', pfx.to_shex)
  end
  def test_nsap
    pfx =  Prefix.new_iso('49.0001.0002.0003')
    assert_equal('9849000100020003000000000000000000000000', pfx.to_shex )
    assert_equal('49.0001.0002.0003.0000.0000.0000.0000.0000.0000.00/152', pfx.to_s)
    pfx =  Prefix.new_iso('49.0001.0002.0003/32')
    p pfx
    assert_equal('2049000100', pfx.to_shex )
    assert_equal('49.0001.0000.0000.0000.0000.0000.0000.0000.0000.00/32', pfx.to_s)

    pfx =  Prefix.new_iso('49.0001.0002.0003/48')
    p pfx
    assert_equal('30490001000200', pfx.to_shex )
    assert_equal('49.0001.0002.0000.0000.0000.0000.0000.0000.0000.00/48', pfx.to_s)

    pfx =  Prefix.new_iso('49.0001.0002.0003/55')
    p pfx
    assert_equal('3749000100020002', pfx.to_shex )
    assert_equal('49.0001.0002.0002.0000.0000.0000.0000.0000.0000.00/55', pfx.to_s)

    pfx =  Prefix.new_iso('49.0001.0002.0003/56')
    p pfx
    assert_equal('3849000100020003', pfx.to_shex )
    assert_equal('49.0001.0002.0003.0000.0000.0000.0000.0000.0000.00/56', pfx.to_s)
  end
  
  def test_factory_inet
    pfx = Prefix.factory(Prefix.new('10.255.128.0/17').encode)
    assert_equal('10.255.128.0/17', pfx.to_s)
    assert_equal('110aff80', pfx.to_shex)
  end
  def test_factory_inet6
    pfx = Prefix.factory(Prefix.new('10.255.128.0/17').encode)
    assert_equal('10.255.128.0/17', pfx.to_s)
    assert_equal('110aff80', pfx.to_shex)
  end
  def test_factory_iso
  end
  
  # def test_iso_mlen_2_netmask
  #   assert_equal(0x80000000000000000000000000000000000000, Iso.new('49.0001.0002.0003/1').netmask)
  #   assert_equal(0xc0000000000000000000000000000000000000, Iso.new('49.0001.0002.0003/2').netmask)
  #   assert_equal(0xe0000000000000000000000000000000000000, Iso.new('49.0001.0002.0003/3').netmask)
  #   assert_equal(0xf0000000000000000000000000000000000000, Iso.new('49.0001.0002.0003/4').netmask)
  #   assert_equal(0xffffff00000000000000000000000000000000, Iso.new('49.0001.0002.0003/24').netmask)
  #   assert_equal(0xffffff80000000000000000000000000000000, Iso.new('49.0001.0002.0003/25').netmask)
  #   assert_equal(0xffffffff000000000000000000000000000000, Iso.new('49.0001.0002.0003/32').netmask)
  #   assert_equal(0xfffffffffffffffffffffffffffffffffffffe, Iso.new('49.0001.0002.0003/151').netmask)
  #   assert_equal(0xffffffffffffffffffffffffffffffffffffff, Iso.new('49.0001.0002.0003/152').netmask)
  # end
  
  # def test_iso_mask_to_c
  #   assert_equal([128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 
  #                 Iso.new('49.0001.0002.0003/1').netmask_to_c)
  #   assert_equal([255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  #                 Iso.new('49.0001.0002.0003/32').netmask_to_c)
  # end
  
  # def test_iso_mask
  #   assert_equal([73, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], Iso.new('49.0001.0002.0003/8').mask)
  #   assert_equal([73, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], Iso.new('49.0001.0002.0003/24').mask)
  #   assert_equal([73, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], Iso.new('49.0001.0002.0003/48').mask)
  #   
  # end
  
end


__END__


TODO: exercize these tests...


# ISO NLRI: Test random things about the address conversion
def test_iso_nlri_addr
  
  # Given no mask it will be /152 
  isoNwk = BGP::Base_nlri::Iso.new(
    '49.0001.80ff.f800.0000.0108.0001.0011.0011.0011.00')
  assert_match('49.0001.80ff.f800.0000.0108.0001.0011.0011.0011.00/152', 
    isoNwk.to_s)
    
  # Zeros are padded at the end
  isoNwk = BGP::Base_nlri::Iso.new('49')
  assert_match('49.0000.0000.0000.0000.0000.0000.0000.0000.0000.00/152', 
    isoNwk.to_s)
    
  # Given a mask the prefix will be anded with the mask 
  isoNwk = BGP::Base_nlri::Iso.new(
    '49.0001.80ff.f800.0000.0108.0001.0011.0011.0011.00/8')
  assert_match('49.0000.0000.0000.0000.0000.0000.0000.0000.0000.00/8', 
    isoNwk.to_s)
    
  # Check that lower and upper case is not relevant, but outputted as lower case 
  isoNwk = BGP::Base_nlri::Iso.new(
    '49.0001.aAbB.cCdD.EeFf.0008.0001.0011.0011.0011.00/152')
  assert_match('49.0001.aabb.ccdd.eeff.0008.0001.0011.0011.0011.00/152', 
    isoNwk.to_s)
    
  # Check that mask 152 (max) zero out the right bits
  assert_match('ff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.00/152',
    BGP::Base_nlri::Iso.new(
        'ff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/152').to_s)
  # Check that mask 151 (max-1) zero out the right bits
  assert_match('ff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.fffe.00/151',
    BGP::Base_nlri::Iso.new(
        'ff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/151').to_s)
end

# ISO NLRI: Test the BGP Update Prefix format   
def test_iso_nlri_updpfx
  # Given a mask the prefix will be anded with the mask 
  assert_match('0849',BGP::Base_nlri::Iso.new(
    '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/8').to_shex)
  assert_match('094980',BGP::Base_nlri::Iso.new(
    '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/9').to_shex)
  assert_match('0f49fe',BGP::Base_nlri::Iso.new(
    '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/15').to_shex)
  assert_match('1049ff',BGP::Base_nlri::Iso.new(
    '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/16').to_shex)
  assert_match('1149ff80',BGP::Base_nlri::Iso.new(
    '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/17').to_shex)
  assert_match('9749fffffffffffffffffffffffffffffffffffe',
      BGP::Base_nlri::Iso.new(
        '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/151').to_shex)
  assert_match('9849ffffffffffffffffffffffffffffffffffff',
      BGP::Base_nlri::Iso.new(
        '49.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ffff.ff/152').to_shex)
end

def test_ext_element
  assert_equal('ID: 100, 10.0.0.0/7', Base_nlri::Ext_Nlri_element.new(100, '10.0.0.0/7').to_s)
  assert_equal('00000064070a', Base_nlri::Ext_Nlri_element.new(100, '10.0.0.0/7').to_shex)
  assert_equal('00000064190a000000', Base_nlri::Ext_Nlri_element.new(100, '10.0.0.0/25').to_shex)
  sbin = Base_nlri::Ext_Nlri_element.new(100, '10.0.0.0/25').encode
  assert_equal('00000064190a000000', Base_nlri::Ext_Nlri_element.new(sbin).to_shex)
  sbin = ['000000650764000000660766000000670766000000680768000000690869'].pack('H*')
  Base_nlri::Ext_Nlri_element.new(sbin)
  assert_equal('000000660766000000670766000000680768000000690869', sbin.unpack('H*')[0])
  Base_nlri::Ext_Nlri_element.new(sbin)
  assert_equal('000000670766000000680768000000690869', sbin.unpack('H*')[0])
  Base_nlri::Ext_Nlri_element.new(sbin)
  assert_equal('000000680768000000690869', sbin.unpack('H*')[0])
  Base_nlri::Ext_Nlri_element.new(sbin)
  assert_equal('000000690869', sbin.unpack('H*')[0])
  Base_nlri::Ext_Nlri_element.new(sbin)
  assert_equal('', sbin.unpack('H*')[0])
  
  # sbin=['0f140010140011140000'].pack('H*')
  # Base_nlri::Nlri_element.new(sbin)
  # assert_equal('', sbin.unpack('H*')[0])
  
  
end


  # if packed 2nd arg is AFI, default = ipv4
  if args[0].is_a?(String) and args[0].packed?
    afi = args[1] ||=1
    case afi
    when :ip4,1 ; super(parse4(args[0]))
    when :ip6,2 ; super(parse6(args[0]))
    when :iso,3 ; 
    end
  elsif args[0].is_a?(Nlri::Ip4) or args[0].is_a?(Nlri::Ip6) or args[0].is_a?(Prefix)
    super(args[0].to_s)
  else
    super(*args)
  end
end
def afi
  if ipv4?
    IANA::AFI::IP
  elsif ipv6?
    IANA::AFI::IP6
  end
end
alias bit_length mlen

def nexthop
  to_s.split('/')[0]
end

end
end

__END__


prefix is a afi, prefix, len


# ISO
# INET
# INET6

module Nlri_element 

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
  # def parse(arg)
  #   s = arg.dup
  #   s +=([0]*3).pack('C*')
  #   plen, *nlri = s.unpack('CC4')
  #   arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
  #   ipaddr = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
  # end
  # alias :parse4 :parse
  # def parse6(arg)
  #   s = arg.dup
  #   s +=([0]*16).pack('C*')
  #   plen, *nlri = s.unpack('Cn8')
  #   arg.slice!(0,1+(plen+7)/8) # trim arg accordingly
  #   ipaddr = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
  # end
end

class Ip4 < 
  include Nrli_element
end




class Inet6
end


# 
# class Nsap
#   def self.new_ntoh(s)
#     sbin = s.dup
#     _, o1, r = s.unpack('CH2H*')
#     new [o1, r.scan(/..../).collect { |x| r.slice!(0,4)}, r].flatten.join('.').chomp('.')
#   end
# 
#   def initialize(arg)
#     nsap, @mlen = arg.split('/')
#     @nsap = ([arg.gsub(/\./,'')].pack('H*').unpack('C*')+[0]*19)[0...20]
#     apply_mask
#   end
#   def to_s
#     o1, r = hton.unpack('H2H*')
#     [o1, r.scan(/..../).collect { |x| r.slice!(0,4)},'00'].flatten.join('.')
#   end
#   def mlen
#     @mlen ||= 152
#     @mlen.to_i
#   end
#   def hton
#     @nsap.pack('C*')
#   end
#   private
#   
#   def netmask
#     0xffffffffffffffffffffffffffffffffffffff - (2**(152-mlen)) +1
#   end
# 
#   def netmask_to_c
#     @netmask_to_c ||= [netmask.to_s(16)].pack('H*').unpack('C*')
#   end
# 
#   def apply_mask
#     @nsap.each_with_index { |v,i| @nsap[i] = v & netmask_to_c[i] }
#   end
#   
# end

