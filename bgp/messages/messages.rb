module BGP

  begin
    unless const_defined? :VERSION
      BGP.const_set('VERSION', Gem.loaded_specs['bgp4r'].version.to_s)
    end
  rescue
  end
  
  %w{ update keepalive open notification capabity}.each do |m|
    autoload "#{m}".capitalize.to_sym, "bgp/messages/#{m}"    
  end
  autoload :Route_refresh,     'bgp/messages/route_refresh'
  autoload :Orf_route_refresh, 'bgp/messages/route_refresh'
  autoload :Prefix_orf,        'bgp/orfs/prefix_orf'
  
end



require 'bgp/messages/markers'