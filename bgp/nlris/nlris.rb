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
  evpn_route
  evpn
  mcast_vpn_route
  mcast_vpn
  rt_constrain
}.each { |n| require "bgp/nlris/#{n}" }
