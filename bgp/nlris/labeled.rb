require 'bgp/nlris/label'
module BGP
  class Labeled
    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        @prefix, *labels = args
        @labels = Label_stack.new(*labels)
      end
    end
    def bit_length
      @labels.bit_length+@prefix.bit_length
    end
    def encode
      [bit_length, @labels.encode, @prefix.encode(false)].pack('Ca*a*')
    end
    def to_s
      "#{@labels} #{@prefix}"
    end
    def afi
      @prefix.afi
    end  
    def parse(s, afi=1, safi=1)
      bitlen = s.slice!(0,1).unpack('C')[0]
      @labels = Label_stack.new(s)
      mlen = bitlen - (24*@labels.size)
      prefix = [mlen,s.slice!(0,(mlen+7)/8)].pack("Ca*")
      case safi
      when 128,129
        @prefix = Vpn.new(prefix)
      else
        @prefix = Prefix.new(prefix, afi)
      end
    end
  end
end

load "../../test/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0