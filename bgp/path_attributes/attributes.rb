%w{ 
  origin 
  next_hop 
  local_pref 
  multi_exit_disc 
  as_path 
  communities 
  aggregator 
  atomic_aggregate 
  originator_id 
  cluster_list 
  mp_reach 
  mp_unreach 
  extended_communities 
  path_attribute
  aigp
  large_communities
  otc
  ipv6_extended_communities
  prefix_sid
  pmsi_tunnel
  tunnel_encap
  as4
  attr_set
}.each do |attr|
  require "bgp/path_attributes/#{attr}"
end
