
require 'bgp/common'
require 'bgp/iana'

require 'bgp/nlris/nsap'

module BGP

class Prefix
  include BGP
  
  def self.new_ntop_extended(arg, afi=1)
    path_id = arg.slice!(0,4).unpack('N')[0]
    case afi
    when 1
      new_ntop(arg,afi,path_id)
    else
      # AFI 2 and 3 are handled elsewhere
      raise
    end
  end
  
  class << self
    def new_ntop(arg, afi=1, path_id=nil)
      case afi
      when IANA::AFI::IPv4, :ipv4
        #TODO: Testcase...
        s = arg.dup
        s +=([0]*3).pack('C*')
        plen, *nlri = s.unpack('CC4')
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s }.join('.') + "/" + plen .to_s
      when IANA::AFI::IPv6, :ipv6
        #TODO: Testcase...
        s = arg.dup
        s +=([0]*16).pack('C*')
        plen, *nlri = s.unpack('Cn8')
        arg.slice!(0,1+(plen+7)/8)
        pfx = nlri.collect { |n| n.to_s(16) }.join(':') + "/" + plen .to_s
      when IANA::AFI::NSAP, :nsap
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

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

