require 'bgp/nlris/nlri'
module BGP
  class Prefix < Base_nlri::Nlri_element
    def initialize(*args)
      if args[0].is_a?(String) and args[0].packed?
        afi = args[1] ||=1
        case afi
        when :ip4,1 ; super(parse4(args[0]))
        when :ip6,2 ; super(parse6(args[0]))
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

# FIXME:
# load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0