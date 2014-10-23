require 'bgp4r'
include BGP

def create_fiber(base_prefix, path_id, nprefix=22, npack=10)
  fiber = Fiber.new do 
    ipaddr = IPAddr.new(base_prefix)
     nlris = Nlri.new
    nprefix.times do |i|
      nlris  << [path_id, (ipaddr ^ i)]
      next unless (i%npack)==0
      Fiber.yield nlris
      nlris = Nlri.new
    end
    Fiber.yield nlris unless nlris.empty?
    nil
  end
  fiber
end

nexthop4='192.168.131.20'

pa = Path_attribute.new(
 Next_hop.new(nexthop4),
 Origin.new(0),
 As_path.new(200),
 Local_pref.new(100),
)

routes_with_pathid_100 = create_fiber("13.11.0.0/26",0x100)
routes_with_pathid_200 = create_fiber("13.11.0.0/26",0x200)

Log.create
Log.level=Logger::DEBUG

n = Neighbor.new :my_as=> 197014, :remote_addr => '192.168.131.11', :id=> '0.0.0.1'

n.capability_mbgp_ipv4_unicast  
n.capability_four_byte_as
n.add_cap OPT_PARM::CAP::Add_path.new( :send_and_receive, 1, 1)
n.start

while nlris = routes_with_pathid_100.resume
  n.send_message Update.new pa, nlris
end
while nlris = routes_with_pathid_200.resume
  n.send_message Update.new pa, nlris
end

sleep(300)


__END__

Produces:


!
router bgp 197014
 bgp router-id 2.2.2.2
 bgp log-neighbor-changes
 neighbor 192.168.131.20 remote-as 197014
 !
 address-family ipv4
  bgp additional-paths send receive
  neighbor 192.168.131.20 activate
 exit-address-family
!


R11#show ip bgp
BGP table version is 115, local router ID is 2.2.2.2
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal, 
              r RIB-failure, S Stale, m multipath, b backup-path, f RT-Filter, 
              x best-external, a additional-path, c RIB-compressed, 
Origin codes: i - IGP, e - EGP, ? - incomplete
RPKI validation codes: V valid, I invalid, N Not found

     Network          Next Hop            Metric LocPrf Weight Path
 * i 13.11.0.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.0.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.0.128/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.0.192/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.1.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.1.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.1.128/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.1.192/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.2.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.2.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.2.128/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.2.192/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.3.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.3.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.3.128/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.3.192/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.4.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.4.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.4.128/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.4.192/26   192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.5.0/26     192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
 * i 13.11.5.64/26    192.168.131.20                100      0 200 i
 *>i                  192.168.131.20                100      0 200 i
R11#show ip bgp 13.11.0.64
BGP routing table entry for 13.11.0.64/26, version 95
Paths: (2 available, best #2, table default)
  Not advertised to any peer
  Refresh Epoch 1
  200
    192.168.131.20 from 192.168.131.20 (0.0.0.1)
      Origin IGP, localpref 100, valid, internal
      rx pathid: 0x200, tx pathid: 0
  Refresh Epoch 1
  200
    192.168.131.20 from 192.168.131.20 (0.0.0.1)
      Origin IGP, localpref 100, valid, internal, best
      rx pathid: 0x100, tx pathid: 0x0
R11#



jme@ubuntu:/mnt/hgfs/jme/routing/bgp4r$ ruby -I. examples/ibgp-ios-asn4bytes-addpath.rb 
I, [42:45#2328]  INFO -- : BGP::Neighbor Open Socket old state Idle new state Active
I, [42:45#2328]  INFO -- : BGP::Neighbor SendOpen
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Open Message (1), length: 53
  Version 4, my AS 23456, Holdtime 180s, ID 0.0.0.1
  Option Capabilities Advertisement (2): [0206010400010001]
    Multiprotocol Extensions (1), length: 4
      AFI IPv4 (1), SAFI Unicast (1)
  Option Capabilities Advertisement (2): [0206410400030196]
    Capability(65): 4-octet AS number: 197014
  Option Capabilities Advertisement (2): [0206450400010103]
    Add-path Extension (69), length: 8
        AFI IPv4 (1), SAFI Unicast (1), SEND_AND_RECV (3)
  
0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0035 0104 5ba0 00b4 0000 0001 1802 0601
0x0002:  0400 0100 0102 0641 0400 0301 9602 0645
0x0003:  0400 0101 03


D, [42:45#2328] DEBUG -- : #<BGP::IO::Output:0x00000001e9ac90> #<Thread:0x00000001e99b10> started
D, [42:45#2328] DEBUG -- : #<BGP::IO::Input:0x00000001e9ad30> #<Thread:0x00000001e99c50> started
I, [42:45#2328]  INFO -- : BGP::Neighbor ev_send_open old state Active new state OpenSent
I, [42:45#2328]  INFO -- : BGP::Neighbor RecvOpen
D, [42:45#2328] DEBUG -- : BGP::Neighbor Recv Open Message (1), length: 65
  Version 4, my AS 23456, Holdtime 180s, ID 2.2.2.2
  Option Capabilities Advertisement (2): [0206010400010001]
    Multiprotocol Extensions (1), length: 4
      AFI IPv4 (1), SAFI Unicast (1)
  Option Capabilities Advertisement (2): [02028000]
    Route Refresh (Cisco) (128), length: 2
  Option Capabilities Advertisement (2): [02020200]
    Route Refresh (2), length: 2
  Option Capabilities Advertisement (2): [02024600]
  Option Capabilities Advertisement (2): [0206450400010103]
    Add-path Extension (69), length: 8
        AFI IPv4 (1), SAFI Unicast (1), SEND_AND_RECV (3)
  Option Capabilities Advertisement (2): [0206410400030196]
    Capability(65): 4-octet AS number: 197014
  
0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0041 0104 5ba0 00b4 0202 0202 2402 0601
0x0002:  0400 0100 0102 0280 0002 0202 0002 0246
0x0003:  0002 0645 0400 0101 0302 0641 0400 0301
0x0004:  96


I, [42:45#2328]  INFO -- : BGP::Neighbor RecvOpen old state OpenSent new state OpenConfirm
I, [42:45#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [42:45#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [42:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

D, [42:45#2328] DEBUG -- : BGP::Neighbor SendKeepAlive state is OpenConfirm
I, [42:45#2328]  INFO -- : BGP::Neighbor RecvKeepAlive old state OpenConfirm new state Established
I, [42:45#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [42:45#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [42:45#2328]  INFO -- : BGP::Neighbor RecvUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Recv Update Message (2), length: 23


0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0017 0200 0000 00


I, [42:45#2328]  INFO -- : BGP::Neighbor version: 4, id: 0.0.0.1, as: 197014, holdtime: 180, peer addr: 192.168.131.11, local addr:  started
I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 57
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=256, 13.11.0.0/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0039 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0100 1a0d 0b00 00


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 138
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=256, 13.11.0.64/26
ID=256, 13.11.0.128/26
ID=256, 13.11.0.192/26
ID=256, 13.11.1.0/26
ID=256, 13.11.1.64/26
ID=256, 13.11.1.128/26
ID=256, 13.11.1.192/26
ID=256, 13.11.2.0/26
ID=256, 13.11.2.64/26
ID=256, 13.11.2.128/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  008a 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0100 1a0d 0b00 4000 0001 001a 0d0b
0x0004:  0080 0000 0100 1a0d 0b00 c000 0001 001a
0x0005:  0d0b 0100 0000 0100 1a0d 0b01 4000 0001
0x0006:  001a 0d0b 0180 0000 0100 1a0d 0b01 c000
0x0007:  0001 001a 0d0b 0200 0000 0100 1a0d 0b02
0x0008:  4000 0001 001a 0d0b 0280


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 138
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=256, 13.11.2.192/26
ID=256, 13.11.3.0/26
ID=256, 13.11.3.64/26
ID=256, 13.11.3.128/26
ID=256, 13.11.3.192/26
ID=256, 13.11.4.0/26
ID=256, 13.11.4.64/26
ID=256, 13.11.4.128/26
ID=256, 13.11.4.192/26
ID=256, 13.11.5.0/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  008a 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0100 1a0d 0b02 c000 0001 001a 0d0b
0x0004:  0300 0000 0100 1a0d 0b03 4000 0001 001a
0x0005:  0d0b 0380 0000 0100 1a0d 0b03 c000 0001
0x0006:  001a 0d0b 0400 0000 0100 1a0d 0b04 4000
0x0007:  0001 001a 0d0b 0480 0000 0100 1a0d 0b04
0x0008:  c000 0001 001a 0d0b 0500


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 57
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=256, 13.11.5.64/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0039 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0100 1a0d 0b05 40


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 57
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=512, 13.11.0.0/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0039 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0200 1a0d 0b00 00


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 138
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=512, 13.11.0.64/26
ID=512, 13.11.0.128/26
ID=512, 13.11.0.192/26
ID=512, 13.11.1.0/26
ID=512, 13.11.1.64/26
ID=512, 13.11.1.128/26
ID=512, 13.11.1.192/26
ID=512, 13.11.2.0/26
ID=512, 13.11.2.64/26
ID=512, 13.11.2.128/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  008a 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0200 1a0d 0b00 4000 0002 001a 0d0b
0x0004:  0080 0000 0200 1a0d 0b00 c000 0002 001a
0x0005:  0d0b 0100 0000 0200 1a0d 0b01 4000 0002
0x0006:  001a 0d0b 0180 0000 0200 1a0d 0b01 c000
0x0007:  0002 001a 0d0b 0200 0000 0200 1a0d 0b02
0x0008:  4000 0002 001a 0d0b 0280


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 138
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=512, 13.11.2.192/26
ID=512, 13.11.3.0/26
ID=512, 13.11.3.64/26
ID=512, 13.11.3.128/26
ID=512, 13.11.3.192/26
ID=512, 13.11.4.0/26
ID=512, 13.11.4.64/26
ID=512, 13.11.4.128/26
ID=512, 13.11.4.192/26
ID=512, 13.11.5.0/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  008a 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0200 1a0d 0b02 c000 0002 001a 0d0b
0x0004:  0300 0000 0200 1a0d 0b03 4000 0002 001a
0x0005:  0d0b 0380 0000 0200 1a0d 0b03 c000 0002
0x0006:  001a 0d0b 0400 0000 0200 1a0d 0b04 4000
0x0007:  0002 001a 0d0b 0480 0000 0200 1a0d 0b04
0x0008:  c000 0002 001a 0d0b 0500


I, [42:45#2328]  INFO -- : BGP::Neighbor SendUpdate
D, [42:45#2328] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 57
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
Network Layer Reachability Information:
ID=512, 13.11.5.64/26

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0039 0200 0000 1940 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  0000 0200 1a0d 0b05 40


I, [43:34#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [43:34#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [43:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [43:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

I, [44:33#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [44:33#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [44:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [44:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

I, [45:26#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [45:26#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [45:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [45:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

I, [46:14#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [46:14#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [46:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [46:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

I, [47:08#2328]  INFO -- : BGP::Neighbor RecvKeepalive
D, [47:08#2328] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [47:45#2328]  INFO -- : BGP::Neighbor SendKeepalive
D, [47:45#2328] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

D, [47:45#2328] DEBUG -- : Exiting BGP IO Ouput
jme@ubuntu:/mnt/hgfs/jme/routing/bgp4r$ 
