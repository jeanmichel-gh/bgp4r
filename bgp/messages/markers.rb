require 'bgp/messages/update'
module BGP
  def Update.end_of_rib_marker(*args)
    if args.empty?
      Update.new(Path_attribute.new()) if args.empty?
    elsif args[0].is_a?(Hash)
      Update.new(Path_attribute.new(Mp_unreach.new(*args)))
    end
  end
end

__END__

2.  Marker for End-of-RIB

   An UPDATE message with no reachable Network Layer Reachability
   Information (NLRI) and empty withdrawn NLRI is specified as the End-
   of-RIB marker that can be used by a BGP speaker to indicate to its
   peer the completion of the initial routing update after the session
   is established.  For the IPv4 unicast address family, the End-of-RIB
   marker is an UPDATE message with the minimum length [BGP-4].  For any
   other address family, it is an UPDATE message that contains only the
   MP_UNREACH_NLRI attribute [BGP-MP] with no withdrawn routes for that
   <AFI, SAFI>.

   Although the End-of-RIB marker is specified for the purpose of BGP
   graceful restart, it is noted that the generation of such a marker
   upon completion of the initial update would be useful for routing
   convergence in general, and thus the practice is recommended.

   In addition, it would be beneficial for routing convergence if a BGP
   speaker can indicate to its peer up-front that it will generate the
   End-of-RIB marker, regardless of its ability to preserve its
   forwarding state during BGP restart.  This can be accomplished using
   the Graceful Restart Capability described in the next section.


I, [29:38#22724]  INFO -- : TestBgp::N100 RecvUpdate
D, [29:38#22724] DEBUG -- : TestBgp::N100 Recv Update Message (2), 4 bytes AS, length: 23
  

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0017 0200 0000 00

