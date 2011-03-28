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
      
      def method_missing(name, *args, &block)
        if (/^(send|recv)_(ipv4|ipv6|inet|inet6)_(.+)\?$/ =~ name.to_s)
          case $2
          when 'ipv4', 'inet'   ; afi = IANA.afi?(:ipv4)
          when 'ipv6', 'inet6'  ; afi = IANA.afi?(:ipv6)
          else
            super
          end
          case $3
          when 'unicast'            ; safi = IANA.safi?(:unicast_nlri)
          when 'multicast'          ; safi = IANA.safi?(:multicast_nlri)
          when 'mpls_vpn_unicast'   ; safi = IANA.safi?(:mpls_vpn_unicast)
          when 'mpls_vpn_multicast' ; safi = IANA.safi?(:mpls_vpn_multicast)
          else
            super
          end
          def_method(name,$1, afi,safi)
        else
          super
        end
      end

    private

    def def_method(name, action, afi, safi)
      self.class.instance_eval do
        define_method("#{name}") do
          path_id? action, afi, safi
        end
      end
      __send__ name
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

load "../../test/unit/neighbor/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
