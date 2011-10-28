require 'bgp/path_attributes/attribute'

module BGP

  class Aigp < Attr

    def initialize(*args)
      @flags, @type = OPTIONAL_NON_TRANSITIVE, ACCUMULATED_IGP_METRIC
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(self.class)
        parse(args[0].encode, *args[1..-1])
      elsif args.size==1 and args[0].is_a?(Integer)
        @aigp = args[0]
      elsif args.empty?
        @aigp=0
      else
        raise
      end
    end

    def to_i
      @aigp.to_i
    end
    
    def accumulated_igp_metric
      format("(0x%8.8x) %d", to_i, to_i)
    end
    alias metric accumulated_igp_metric
    
    def to_s(method=:default)
      super(accumulated_igp_metric, method)
    end

    def encode
      super([1, 11, @aigp >> 32, @aigp & 0xffffffff].pack('CnN2'))
    end

    def parse(s)
      @flags, @type, len, value=super(s)
      _, _, high, low = value.unpack('CnNN')
      @aigp = (high << 32) + low
    end

  end

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
