
module BGP
  class Vpn
    attr_reader :prefix, :rd
    def initialize(*args)
      if args.size>0 and args[0].is_a?(String) and args[0].is_packed?
        parse(*args)
      else
        prefix, *rd = args
        self.prefix=(prefix)
        self.rd=rd
      end      
    end
    def prefix=(arg)
      if arg.is_a?(Prefix)
        @prefix=arg
      else
        @prefix=Prefix.new(arg)
      end
    end
    def rd=(args)
      args.flatten!
      if args.empty?
        @rd=Rd.new
      elsif args.size==1 and args[0].is_a?(BGP::Rd)
        @rd=args[0]
      else
        @rd=Rd.new(*args)
      end
    end
    # len_included arg is used by labeled encode()
    def encode_next_hop
      Rd.new.encode + @prefix.encode(false)
    end
    def encode(len_included=true)
      if len_included
        [bit_length, @rd.encode, @prefix.encode_with_len_without_path_id].pack('Ca*a*')
      else
        @rd.encode + @prefix.encode_without_len_without_path_id
      end
    end
    def encode_without_len_without_path_id
      encode(false)
    end
    def path_id
      @prefix.path_id
    rescue
    end
    def path_id=(val)
      @prefix.path_id=val
    end
    def bit_length
      @rd.bit_length + @prefix.mlen
    end
    def ipv4?
      @prefix.ipv4?
    end
    def afi
      @prefix.afi
    end  
    def ipv6?
      @prefix.ipv6?
    end
    def parse(s, afi=1)
      nbits = s.slice!(0,1).unpack('C')[0]
      rd,vpn = s.slice!(0,(7+nbits)/8).unpack("a8a*")
      @rd = Rd.new(rd.is_packed)
      @prefix= Prefix.new_ntop([nbits-64,vpn].pack('Ca*'), afi)
    end
    def nexthop
      @prefix.nexthop
    end
    def to_s
       #Label Stack=5806 (bottom) RD=3215:317720610, IPv4=10.45.142.64/32
      "#{@rd.to_s(false)}, #{@prefix.to_s_with_afi}"
    end
  end
end
