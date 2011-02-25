require 'bgp/nlris/prefix'

module BGP
  class Inet_unicast < Prefix
    def safi
      IANA::SAFI::UNICAST_NLRI
    end
  end

  class Inet_multicast < Prefix
    def safi
      IANA::SAFI::MULTICAST_NLRI
    end
  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0