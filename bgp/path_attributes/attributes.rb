%w{ 
  origin next_hop 
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
}.each do |attr|
  require "bgp/path_attributes/#{attr}"
end
