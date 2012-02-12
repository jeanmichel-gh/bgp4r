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
  originator_id
  path_attribute
  aigp
}.each do |attr|
  require "bgp/path_attributes/#{attr}"
end
