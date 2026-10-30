%w{ 
  nlri 
  prefix 
  inet 
  labeled 
  vpn 
  rd
  mapped_ipv4
  flow_spec_component
  flow_spec
}.each { |n| require "bgp/nlris/#{n}" }
