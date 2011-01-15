#--
# Copyright 2011 Jean-Michel Esnault.
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

module BGP
  class Neighbor
    class Capabilities
      def initialize(speaker_open, peer_open)
        @speaker = speaker_open.find(OPT_PARM::CAP::Add_path)
        @peer    = peer_open.find(OPT_PARM::CAP::Add_path) 
      end
      attr_reader :speaker, :peer
      def has_path_id? action, afi, sfi
        case action
        when :recv
          BGP::OPT_PARM::CAP.has_path_id?(speaker, peer, :recv, afi, safi)
        when :send
          BGP::OPT_PARM::CAP.has_path_id?(speaker, peer, :send, afi, safi)
        else
          raise ArgumentError, "Invalid argument #{action}, #{afi}, #{safi}"
        end
      end
      def method_missing(name, *args, &block)
        if /^(send|recv)_(inet|inet6|labeled)_(unicast|multicast)/ =~ name
          puts "#{$1} : #{$2} $3"
        else
          super
        end
      end 
    end
  end
end

if __FILE__ == $0
  
require "test/unit"
require 'bgp4r'

#
# require "bgp/optional_parameters/capabilities"
# require "bgp/messages/open"
# # require "bgp/neighbor/add_path_cap"
# @cap[:as4byte]= as4byte?(open, o)
# negociated_capabilities
# supported_capabilities
#
#
class TestBgpNeighborAddPathCap < Test::Unit::TestCase
  include BGP::Neighbor
  def setup
  end
  def test_new
    speaker_open = Open.new(4,100, 200, '10.0.0.1')
    speaker_open << OPT_PARM::CAP::As4.new(100)
    speaker_open << OPT_PARM::CAP::Route_refresh.new
    speaker_open << OPT_PARM::CAP::Add_path.new( :recv, 1, 1)
    peer_open = Open.new(4,100, 200, '10.0.0.1')
    peer_open << OPT_PARM::CAP::As4.new(100)
    peer_open << OPT_PARM::CAP::Route_refresh.new
    peer_open << OPT_PARM::CAP::Add_path.new( :send, 1, 1)
    puts open
    
    Add_path_capabilities.new speaker_open, peer_open
    
  end
  def test_send_afi_1_safi_2
    neighbor.add_path.send_inet_multicast?
    neighbor.add_path.send_inet6_multicast?
    neighbor.add_path.send_labeled_multicast?
    neighbor.add_path.send_labeled_unicast?
    neighbor.add_path.recv_inet_multicast?
    neighbor.add_path.recv_inet6_multicast?
    neighbor.add_path.recv_labeled_multicast?
    neighbor.add_path.recv_labeled_unicast?
  end
end
end
