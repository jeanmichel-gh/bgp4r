require 'bgp/nlris/label'
module BGP
  class Labeled

    def self.new_ntop(s, afi, safi, path_id=nil)
      nlri = new(s, afi, safi)
      nlri.path_id=path_id if path_id
      nlri
    end

    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        @prefix, *labels = args
        @labels = Label_stack.new(*labels)
      end
    end
    #FIXME... a mixin path_id ????
    def path_id
      @prefix.path_id
    end
    def path_id=(val)
      @prefix.path_id=val
    end
    def bit_length
      @labels.bit_length+@prefix.bit_length
    end
    def encode
      s = [bit_length, @labels.encode, @prefix.encode_without_len_without_path_id].pack('Ca*a*')
      if path_id
        [path_id, s].pack('Na*')
      else
        s
      end
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
        p prefix.unpack('H*')
        @prefix = Prefix.new_ntop(prefix, afi)
      end
    end
  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0