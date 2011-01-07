
require 'bgp/optional_parameters/capability'
require 'bgp/optional_parameters/dynamic'
require 'bgp/optional_parameters/graceful_restart'
require 'bgp/optional_parameters/mbgp'
require 'bgp/optional_parameters/optional_parameter'
require 'bgp/optional_parameters/orf'
require 'bgp/optional_parameters/route_refresh'
require 'bgp/optional_parameters/as4'

module BGP::OPT_PARM
  module DYN_CAP
    BGP::OPT_PARM::CAP.constants.each do |kl|
      const_set(kl, Class.new(::BGP::OPT_PARM::CAP.const_get(kl)))
    end
  end
end
