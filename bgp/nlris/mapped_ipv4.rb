#--
# Copyright 2014 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 

require 'bgp/common'

module BGP
class Ipv4_mapped < IPAddr
  def initialize(ipaddr)
    super
    raise unless ipv4?
  end
  def nexthop
    to_s
  end
  def encode(*args)
    [0,0,0,0xffff,hton].pack('N2n2a*')
  end
  alias  encode_next_hop encode
end
end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
