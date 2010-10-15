#--
# Copyright 2008, 2009 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++


require 'bgp/optional_parameters/optional_parameter'

module BGP::OPT_PARM

  class Capability < Optional_parameter
    include BGP

    unless const_defined? :Unknown
      Unknown = Class.new(self) do
        def initialize(s)
          if s.is_a?(String) and s.is_packed?
            parse(s)
          else
            raise ArgumentError
          end
        end
        def encode
          super @value
        end
        def parse(s)
          @value = super(s)
        end
      end
    end
    
    include BGP::OPT_PARM
    def initialize(code)
      super(OPT_PARM::CAPABILITY)
      @code=code
    end
    def encode(value='')
      if self.class.to_s =~ /BGP::OPT_PARM::DYN_CAP/
        [@code,value.size, value].pack("Cna*")
      else
        super([@code,value.size, value].pack("CCa*"))
      end
    end
    
    def parse(_s)
      s = _s
      if self.class.to_s =~ /BGP::OPT_PARM::DYN_CAP/
        @code, len = _s.slice!(0,3).unpack('Cn')
      else
        s = super(_s)
        @code, len = s.slice!(0,2).unpack('CC')
      end
      s.slice!(0,len).is_packed
    end
    def to_s
      "Option Capabilities Advertisement (#{@parm_type}): [#{to_shex}]"
    end
    def to_hash(h={})
      if h.empty?
        {:code=> @code}
      else
        {:code=> @code, :capability=> h}
      end
    end
    
    def method_missing()
      if name == :to_s_brief
        "#{self.class.to_s.split('::').last}"
      else
        super
      end
    end
    
  end
end

module BGP
  module OPT_PARM
    module CAP
    end
  end
end

# require 'bgp4r'

module BGP::OPT_PARM
  def Capability.factory(s)
    code = s.slice(2,1).unpack('C')[0]
    case code
    when CAP_AS4
      CAP::As4.new(s)
    when CAP_MBGP
      CAP::Mbgp.new(s)
    when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
      CAP::Route_refresh.new(code)
    when CAP_ORF,CAP_ORF_CISCO
      CAP::Orf.new(s)
    when CAP_GR
      CAP::Graceful_restart.new(s)
    when CAP_ADD_PATH
      CAP::Add_path.new(s)
    when CAP_DYNAMIC
      CAP::Dynamic.new(s)
    else
      Capability::Unknown.new(s)
    end
  end
end

module BGP::OPT_PARM
    def Capability.dynamic_factory(s)
      code = s.slice(0,1).unpack('C')[0]
      case code
      when CAP_AS4
        DYN_CAP::As4.new(s)
      when CAP_MBGP
        DYN_CAP::Mbgp.new(s)
      when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
        DYN_CAP::Route_refresh.new(code)
      when CAP_ORF,CAP_ORF_CISCO
        DYN_CAP::Orf.new(s)
      when CAP_GR
        DYN_CAP::Graceful_restart.new(s)
      when CAP_ADD_PATH
        CAP::Add_path.new(s)
      else
        Capability::Unknown.new(s)
      end
    end
end

load "../../test/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
