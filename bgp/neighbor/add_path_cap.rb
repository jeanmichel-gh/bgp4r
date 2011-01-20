#--
# Copyright 2011 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 

module BGP
  
  class Neighbor
    
    class Base_Capabilities
      
      def initialize(speaker_open, peer_open)
        @speaker = speaker_open # speaker_open.find(OPT_PARM::CAP::Add_path)
        @peer    = peer_open    # peer_open.find(OPT_PARM::CAP::Add_path)
      end
      attr_reader :speaker, :peer
      
      def as4byte?
        (! @speaker.has?(OPT_PARM::CAP::As4).nil? and  ! @peer.has?(OPT_PARM::CAP::As4).nil?)
      end
      
      def path_id_recv? afi, safi
        path_id? :recv, afi, safi
      end
      
      def path_id_send? afi, safi
        path_id? :send, afi, safi
      end
      
      def path_id? action, afi, safi
        case action
        when :recv, 'recv'
          _path_id?(speaker_add_path_cap, peer_add_path_cap, :recv, afi, safi)
        when :send, 'send'
          _path_id?(speaker_add_path_cap, peer_add_path_cap, :send, afi, safi)
        else
          raise ArgumentError, "Invalid argument #{action}, #{afi}, #{safi} #{action.inspect}"
        end 
      end
      
      private

      def _path_id?(speaker, peer, sr, afi, safi)
        return false unless speaker and peer
        case sr
        when :recv, 'recv'
          speaker.has?(:recv, afi, safi) && peer.has?(:send, afi, safi)
        when :send, 'send'
          speaker.has?(:send, afi, safi) && peer.has?(:recv, afi, safi)
        else
          raise
        end
      end

      def speaker_add_path_cap
        @speaker.find(OPT_PARM::CAP::Add_path)
      end
      def peer_add_path_cap
        @peer.find(OPT_PARM::CAP::Add_path)
      end
      
      def afi_to_i(afi)
        case afi.to_sym
        when :ipv4,  :inet   ; IANA::AFI::IP
        when :ipv6,  :inet6  ; IANA::AFI::IP6
        else
          raise
        end
      end
      
      def safi_to_i(safi)
        case safi.to_sym
        when :unicast            ; IANA::SAFI::UNICAST_NLRI
        when :multicast          ; IANA::SAFI::MULTICAST_NLRI
        when :labeled            ; IANA::SAFI::LABEL_NLRI
        when :mcast_vpn          ; IANA::SAFI::MCAST_VPN
        when :mpls_vpn_unicast   ; IANA::MPLS_VPN_UNICAST
        when :mpls_vpn_multicast ; IANA::MPLS_VPN_Multicast
        else
          raise
        end
      end
      
      def method_missing(name, *args, &block)
        if (/^(send|recv)_(inet|inet6|labeled)_(unicast|multicast)/ =~ name.to_s)
          path_id? $1, afi_to_i($2), safi_to_i($3)
        else
          super
        end
      end 
    end
    
    class Capabilities < Base_Capabilities
      def initialize(*args)
        @memory = {}
        super
      end
      def as4byte?
        if @memory.has_key?(:as4byte)
          @memory[:as4byte]
        else
          @memory[:as4byte]=super
        end
      end
      def path_id?(*args)
        if @memory.has_key?([:path_id, *args])
          @memory[[:path_id, *args]]
        else
          @memory[[:path_id, *args]]=super
        end
      end
    end
  end
  
end
