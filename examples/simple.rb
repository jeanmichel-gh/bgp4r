#--
#
# Copyright 2008, 2009 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#++

require 'bgp4r'
include BGP

# Start loggin
Log.create
Log.level=Logger::DEBUG

# Create a neighbor and set optional capabilities.
neighbor = Neighbor.new \
  :version=> 4, 
  :my_as=> 100, 
  :remote_addr => '40.0.0.2', 
  :local_addr => '40.0.0.1', 
  :id=> '1.1.1.1', :holdtime=> 180

neighbor.capability :as4_byte
neighbor.capability :route_refresh
neighbor.capability :route_refresh, 128
neighbor.capability :mbgp, :ipv4, :unicast
neighbor.capability :mbgp, :ipv4, :multicast

# A call back to handle received messages we are interested in.
def self.update(msg)
  case msg.class.to_s
  when /Notification/
    Log.warn "Going down !"
  # Ignore uninterested ones.
  # when /Open/
  # when /Keepalive/
  when /Update/
    Log.info "RecvUpdate\n#{m}"
  end
end

neighbor.add_observer(self)

# Start peering (will block til the session is established)
neighbor.start :auto_retry

# An BGP Update object
an_update = Update.new(
  Path_attribute.new(
    Origin.new(2),
    Next_hop.new('40.0.0.1'),
    Multi_exit_disc.new(100),
    Local_pref.new(100),
    As_path.new(100, 80, 60),
    Communities.new('1311:1 311:59 2805:64')
  ),
  Nlri.new('77.0.0.0/17', '78.0.0.0/18', '79.0.0.0/19')
)

# Ship it!
neighbor.send_message an_update

# Keep session up.
Thread.stop
