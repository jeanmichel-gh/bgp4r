require 'bgp/nlris/prefix'

module BGP
  unless const_defined?(:Inet_unicast)
    [:unicast, :multicast].each do |n|
      inet_klass = Class.new(Prefix) do
        define_method(:safi) do
          @safi ||=IANA::SAFI.const_get("#{n.to_s.upcase}_NLRI")
        end
      end
      const_set("Inet_#{n}", inet_klass)
    end
  end
end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0