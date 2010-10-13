require 'bgp/optional_parameters/capability'

%w{ mbgp orf route_refresh as4 graceful_restart dynamic }.each do |c|
    BGP::OPT_PARM::CAP.autoload  "#{c}".capitalize.to_sym,"bgp/optional_parameters/#{c}"
end

module BGP::OPT_PARM
  module DYN_CAP
    BGP::OPT_PARM::CAP.constants.each do |kl|
      const_set(kl, Class.new(::BGP::OPT_PARM::CAP.const_get(kl)))
    end
  end
end
