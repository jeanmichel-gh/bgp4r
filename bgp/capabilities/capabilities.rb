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

require 'bgp4r'
# require 'bgp/path_attributes/path_attribute'
require 'bgp/nlris/nlri'
require 'timeout'

module BGP

class UnknownBgpCapability < RuntimeError
end

class UnknownBgpMessage < RuntimeError
end

module OPT_PARM

  CAPABILITY = 2
  
  #TODO module CAP
  #TODO module CAP::ORF
  
  CAP_MBGP = 1
  CAP_ROUTE_REFRESH = 2
  CAP_ORF = 3
  CAP_AS4 = 65
  CAP_ROUTE_REFRESH_CISCO = 128
  CAP_ORF_CISCO = 130
  
  ORF_NLRI = 1
  ORF_COMMUNITIES = 2
  ORF_EXTENDED_COMMUNITIES = 3
  ORF_PREFIX_LIST = 129    

  ##########################################################
  # BGP OPEN OPTION PARAMETERS                             #
  ##########################################################

  class Optional_parameter

    def initialize(parm_type)
      @parm_type=parm_type
    end

    def encode(value)
      [@parm_type, value.size, value].pack('CCa*')
    end

    def parse(s)
      @parm_type, len = s.slice!(0,2).unpack('CC')
      s.slice!(0,len).is_packed
    end

    def self.factory(s)
      parm_type, len = s.unpack('CC')
      opt_parm = s.slice!(0,len+2).is_packed
      case parm_type
      when CAPABILITY
        Capability.factory(opt_parm)
      else
        raise RuntimeError, "Optional parameter type '#{parm_type}' not implemented"
      end
    end

  end
end

class Capability < OPT_PARM::Optional_parameter
  include OPT_PARM
  def initialize(code)
    super(OPT_PARM::CAPABILITY)
    @code=code
  end
  def encode(value='')
    super([@code,value.size, value].pack('CCa*'))
  end
  def parse(_s)
    s = super(_s)
    @code, len = s.slice!(0,2).unpack('CC')
    s.slice!(0,len).is_packed
  end
  def to_s
    "Option Capabilities Advertisement (#{@parm_type}): [#{to_shex}]"
  end
  def self.factory(s)
    code = s.slice(2,1).unpack('C')[0]
    case code
    when CAP_AS4
      As4_cap.new(s)
    when CAP_MBGP
      Mbgp_cap.new(s)
    when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
      Route_refresh_cap.new(code)
    when CAP_ORF,CAP_ORF_CISCO
      Orf_cap.new(s)
    else
      raise UnknownBgpCapability, "Capability (#{code}), length: #{s.size} not implemented: [#{s.unpack('H*')[0]}]" 
    end
  end
  def to_hash(h={})
    if h.empty?
      {:code=> @code}
    else
      {:code=> @code, :capability=> h}
    end
  end
end

class Mbgp_cap < Capability

  def self.ipv4_unicast
    Mbgp_cap.new(1,1)
  end
  
  def self.ipv4_multicast
    Mbgp_cap.new(1,2)      
  end
  
  def self.ipv6_unicast
    Mbgp_cap.new(2,2)      
  end
  
  def self.ipv6_multicast
    Mbgp_cap.new(2,2)      
  end

  def initialize(afi,safi=nil)
    if safi.nil? and afi.is_a?(String) and afi.is_packed?
      parse(afi)
    else
      super(OPT_PARM::CAP_MBGP)
      self.safi, self.afi = safi, afi
    end
  end
  
  def afi=(val)
    @afi = if val.is_a?(Fixnum)
      val
    elsif val == :ipv4
      1
    elsif val == :ipv6
      2
    end
  end
  
  def safi=(val)
    @safi = if val.is_a?(Fixnum)
      val
    elsif val == :unicast
      1
    elsif val == :multicast
      2
    end
  end

  def encode
    super([@afi,0,@safi].pack('nCC'))
  end

  def parse(s)
    @afi, ignore, @safi = super(s).unpack('nCC')
  end

  def to_s
    super + "\n    Multiprotocol Extensions (#{CAP_MBGP}), length: 4" +
    "\n      AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi})"
  end

  def to_hash
    super({:afi => @afi, :safi => @safi, })
  end
end

class As4_cap < Capability
  def initialize(s)
    if s.is_a?(String) and s.is_packed?
      parse(s)
    else
      super(OPT_PARM::CAP_AS4)
      @as=s
    end
  end
  
  def encode
    super([@as].pack('N'))
  end

  def parse(s)
    @as = super(s).unpack('N')[0]
  end

  def to_s
    "Capability(#{CAP_AS4}): 4-octet AS number: " + @as.to_s
  end

  def to_hash
    super({:as => @as})
  end
end

class Route_refresh_cap < Capability 
  def initialize(code=OPT_PARM::CAP_ROUTE_REFRESH)
    super(code)
  end

  def encode
    super()
  end

  def to_s
    super + "\n    Route Refresh #{@code==128 ? "(Cisco) " : ""}(#{@code}), length: 2"
  end

  def to_hash
    super()
  end
end

class Orf_cap < Capability

  class Entry
    
    def initialize(*args)
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args[0].is_a?(Hash) 
      else
        @afi, @safi, *@types = *args
      end
    end
    
    def encode
      [@afi, 0, @safi, @types.size,@types.collect { |e| e.pack('CC')}.join].pack('nCCCa*')
    end
    
    def parse(s)
      @afi, __, @safi, n = s.slice!(0,5).unpack('nCCC')
      @types=[]
      types = s.slice!(0, 2*n)
      while types.size>0
        @types<< types. slice!(0,2).unpack('CC')
      end
    end
    
    def to_s
      "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi}): #{@types.inspect}"
    end
  end

  def initialize(*args)
    @entries=[]
    if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    else
      super(OPT_PARM::CAP_ORF)
    end
  end

  def add(entry)
    @entries << entry
  end

  def encode
    super(@entries.collect { |e| e.encode }.join)
  end

  def parse(s)
    entries = super(s)
    while entries.size>0
      @entries << Entry.new(entries)
    end
  end

  def to_s
    super + "\n    Outbound Route Filtering (#{@code}), length: #{encode.size}" +
    (['']+@entries.collect { |e| e.to_s }).join("\n      ")
  end

end

end