%w{ 
  nlri 
  prefix 
  inet 
  labeled 
  vpn 
  rd
  mapped_ipv4
}.each { |n| require "bgp/nlris/#{n}" }
