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
  
class Add_path < BGP::OPT_PARM::Capability 
  
  def initialize(*args)
    @tuples = []
    if args.size>1
      super(OPT_PARM::CAP_ADD_PATH)
    elsif args.size==1 and args[0].is_a?(String)
      parse(*args)
    else
      super(OPT_PARM::CAP_ADD_PATH)
    end
  end
  
  def add(sr, afi,safi)
    @tuples << [ _afi(afi), _safi(safi), _send_recv(sr)]
  end

  def parse(s)
    @tuples = []
    families = super(s)
    while families.size>0
      @tuples << families.slice!(0,4).unpack('nCC')
    end
  end

  def encode
    s = []
    s << @tuples.collect { |af| af.pack('nCC') }
    super s.join
  end

  def to_s
    s = []
    s <<  "\n    Add-path Extension (#{CAP_ADD_PATH}), length: 4"
    s = s.join("\n  ")
    super + (s + (['']+@tuples.collect { |af| address_family_to_s(*af)}).join("\n        "))
  end
  
  private
  
  def address_family_to_s(afi, safi, sr)
    "AFI #{IANA.afi(afi)} (#{afi}), SAFI #{IANA.safi(safi)} (#{safi}), #{send_recv_to_s(sr)}"
  end
    
  def _send_recv(val)
    case val
    when :send, 1                                          ; 1
    when :recv, :receive, 2                                ; 2
    when :send_and_recv, :send_recv, :send_and_receive, 3  ; 3
    else
      val
    end
  end
  
  def send_recv_to_s(val)
    case val
    when 1 : 'SEND (1)'
    when 2 : 'RECV (2)'
    when 3 ; 'SEND_AND_RECV (3)'
    else
      'bogus'
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

load "../../test/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


