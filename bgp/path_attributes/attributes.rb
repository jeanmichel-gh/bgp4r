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


# module BGP
#   %w{ 
#     origin next_hop 
#     local_pref 
#     multi_exit_disc 
#     as_path 
#     communities 
#     aggregator 
#     atomic_aggregate 
#     originator_id 
#     cluster_list 
#     mp_reach 
#     mp_unreach 
#     extended_communities 
#     path_attribute
#   }.each do |attr|
#     autoload  attr.capitalize.to_sym,"bgp/path_attributes/#{attr}"
#   end
#   autoload :As4_path, 'bgp/path_attributes/as_path'
# end

