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

module BGP

  # http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-1

  class UnknownBgpMessage < RuntimeError
  end

  class Message

    unless const_defined? :OPEN
      OPEN          = 1
      UPDATE        = 2
      NOTIFICATION  = 3
      KEEPALIVE     = 4
      ROUTE_REFRESH = 5
      CAPABILITY    = 6
    end

    def encode(message='')
      len = message.size+19
      [[255]*16,len,@msg_type,message].flatten.pack('C16nCa*')
    end

    def parse(s)
      len, @msg_type, message = s[16..-1].unpack('nCa*')
      message.is_packed
    end
    def self.factory(_s, as4byte=false)
      s = [_s].pack('a*')
      s.slice(18,1).unpack('C')[0]
      case s.slice(18,1).unpack('C')[0]
      when OPEN
        Open.new(s)
      when UPDATE
        Update.new(s, as4byte)
      when KEEPALIVE
        Keepalive.new
      when NOTIFICATION
        Notification.new(s)
      when ROUTE_REFRESH
        if s.size > 23  
          Orf_route_refresh.new(s)
        else
          Route_refresh.new(s)
        end
      when CAPABILITY
        Capability.new(s)
      else
        puts "don't know what kind of bgp messgage this is #{s.slice(18,1).unpack('C')}"
      end
    end
    def self.keepalive
      Keepalive.new.encode
    end
    def self.route_refresh(afi,safi)
      Route_refresh.new(afi,safi).encode
    end
  end

end

load "../../test/messages/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

