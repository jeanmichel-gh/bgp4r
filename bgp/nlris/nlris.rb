%w{ 
  nlri 
  prefix2 
  inet 
  labeled 
  vpn 
  rd 
}.each { |n| require "bgp/nlris/#{n}" }
