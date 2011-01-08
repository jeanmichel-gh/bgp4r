%w{ 
  nlri 
  prefix 
  inet 
  labeled 
  vpn 
  rd 
}.each { |n| require "bgp/nlris/#{n}" }
