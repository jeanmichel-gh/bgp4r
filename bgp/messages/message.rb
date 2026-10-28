#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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

module ::BGP

  # http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-1

  class UnknownBgpMessage < RuntimeError
  end

  class Message

    # RFC 4271 section 4: "The maximum message size is 4096 octets. All
    # implementations are required to support this maximum message size."
    # Section 4.1 says it again of the header's Length field, which "MUST
    # always be at least 19 and no greater than 4096".
    #
    # This is a property of a BGP message, so it lives here and every
    # caller reads it from here. It used to be written out in
    # bgp/rib/update_builder.rb and bgp/misc/route_generator.rb with its
    # own constant in each, which is how one of them goes stale.
    #
    # RFC 8654 raises the limit to 65535 when both speakers negotiate the
    # BGP Extended Message capability, which bgp4r does not do. Whoever
    # adds that capability changes the limit per session rather than here:
    # UpdateBuilder already takes max_size for exactly that.
    unless const_defined? :MAX_SIZE
      MAX_SIZE = 4096
    end

    unless const_defined? :OPEN
      OPEN          = 1
      UPDATE        = 2
      NOTIFICATION  = 3
      KEEPALIVE     = 4
      ROUTE_REFRESH = 5
      CAPABILITY    = 6
    end

    def encode(message='')
      raise unless @msg_type.is_a?(Integer)
      len = message.size+19
      [[255]*16,len,@msg_type,message].flatten.pack('C16nCa*')
    end

    def parse(s)
      _, @msg_type, message = s[16..-1].unpack('nCa*')
      message.is_packed
    end
    def self.factory(_s, session_info=nil)
      s = [_s].pack('a*')
      s.slice(18,1).unpack('C')[0]
      case s.slice(18,1).unpack('C')[0]
      when OPEN
        Open.new(s)
      when UPDATE
        Update.new(s, session_info)
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
        # RFC 4271 section 6.1: Bad Message Type.
        raise UnknownBgpMessage, "unknown BGP message type #{s.slice(18,1).unpack('C')[0]}"
      end
    end
    def self.keepalive
      @keepalive ||= Keepalive.new.encode
    end
    def self.route_refresh(afi,safi)
      Route_refresh.new(afi,safi).encode
    end    
    %w{update keepalive open notification capability route_refresh }.each do |m|
      define_method("is_a_#{m}?") do
        is_a?(BGP.const_get(m.capitalize))
      end      
      eval "alias :is_an_#{m}? :is_a_#{m}?" if (m =~ /^[aeiou]/)
    end
    def has_no_path_attribute?
      path_attribute.nil?
    end
    def has_a_path_attribute?
      ! has_no_path_attribute?
    end
  end

end

load "../../test/unit/messages/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0

