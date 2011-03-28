#--
# Copyright 2010 Jean-Michel Esnault.
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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP
  
class Graceful_restart < BGP::OPT_PARM::Capability 
  
  def initialize(*args)
    if args.size>1
      @restart_state, @restart_time = args
      @tuples = []
      super(OPT_PARM::CAP_GR)
    else
      parse(*args)
    end
  end
  
  def add(afi,safi,flags)
    @tuples << [_afi(afi), _safi(safi), flags]
  end

  def parse(s)
    @tuples = []
    o1, families = super(s).unpack('na*')
    @restart_state = o1 >> 12
    @restart_time = o1 & 0xfff
    while families.size>0
      @tuples << families.slice!(0,4).unpack('nCC')
    end
  end


  def encode
    s = []
    s << [(@restart_state << 12) + @restart_time].pack('n')
    s << @tuples.collect { |af| af.pack('nCC') }
    super s.join
  end
  def to_s
    s = []
    s <<  "\n    Graceful Restart Extension (#{CAP_GR}), length: 4"
    s <<  "    Restart Flags: #{restart_flag}, Restart Time #{@restart_time}s"
    s = s.join("\n  ")
    super + (s + (['']+@tuples.collect { |af| address_family(*af)}).join("\n        "))
  end
  
  private
  
  def address_family(afi, safi, flags)
    "AFI #{IANA.afi(afi)} (#{afi}), SAFI #{IANA.safi(safi)} (#{safi}), #{address_family_flags(flags)}"
  end
  
  def restart_flag
    if @restart_state == 0
      '[none]'
    else
      "0x#{@restart_state}"
    end
  end
  
  def address_family_flags(flags)
    if flags & 1 == 0
      "Forwarding state not preserved (0x#{flags.to_s(16)})"
    elsif flags & 1 == 1
      "Forwarding state preserved (0x#{flags.to_s(16)})"
    end
  end
  
  def _afi(val)
    if val.is_a?(Fixnum)
      val
    elsif val == :ipv4
      1
    elsif val == :ipv6
      2
    end
  end
  
  def _safi(val)
    if val.is_a?(Fixnum)
      val
    elsif val == :unicast
      1
    elsif val == :multicast
      2
    end
  end
  
  
end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


