require 'bgp4r'
include BGP

def create_fiber(base_prefix, nprefix=22, npack=10)
  fiber = Fiber.new do 
    ipaddr = IPAddr.new(base_prefix)
    prefixes=[]
    nprefix.times do |i|
      prefixes << (ipaddr ^ i)
      next unless (i%npack)==0
      Fiber.yield prefixes
      prefixes=[]
    end
    Fiber.yield prefixes unless prefixes.empty?
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

ipv4_routes = create_fiber("13.11.0.0/26")

Log.create
Log.level=Logger::DEBUG

n = Neighbor.new :my_as=> 197014, :remote_addr => '192.168.131.11', :id=> '0.0.0.1'

n.capability_mbgp_ipv4_unicast  
n.capability_four_byte_as
n.start


while subnets = ipv4_routes.resume
  n.send_message Update.new pa.replace(Mp_reach.new(:afi=>1, :safi=>1, :nexthop=> nexthop4, :nlris=> subnets))
end


sleep(300)


__END__

Produces:


jme@ubuntu:/mnt/hgfs/jme/routing/bgp4r$ ifconfig tap0 | grep inet
          inet addr:192.168.131.20  Bcast:192.168.131.255  Mask:255.255.255.0

R11# show running config

!
router bgp 197014
 bgp router-id 2.2.2.2
 bgp log-neighbor-changes
 neighbor 192.168.131.20 remote-as 197014
 !
 address-family ipv4
  neighbor 192.168.131.20 activate
 exit-address-family
!

R11#show ip route bgp
Codes: L - local, C - connected, S - static, R - RIP, M - mobile, B - BGP
       D - EIGRP, EX - EIGRP external, O - OSPF, IA - OSPF inter area 
       N1 - OSPF NSSA external type 1, N2 - OSPF NSSA external type 2
       E1 - OSPF external type 1, E2 - OSPF external type 2
       i - IS-IS, su - IS-IS summary, L1 - IS-IS level-1, L2 - IS-IS level-2
       ia - IS-IS inter area, * - candidate default, U - per-user static route
       o - ODR, P - periodic downloaded static route, H - NHRP, l - LISP
       + - replicated route, % - next hop override

Gateway of last resort is not set

      13.0.0.0/26 is subnetted, 22 subnets
B        13.11.0.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.0.64 [200/0] via 192.168.131.20, 00:04:55
B        13.11.0.128 [200/0] via 192.168.131.20, 00:04:55
B        13.11.0.192 [200/0] via 192.168.131.20, 00:04:55
B        13.11.1.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.1.64 [200/0] via 192.168.131.20, 00:04:55
B        13.11.1.128 [200/0] via 192.168.131.20, 00:04:55
B        13.11.1.192 [200/0] via 192.168.131.20, 00:04:55
B        13.11.2.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.2.64 [200/0] via 192.168.131.20, 00:04:55
B        13.11.2.128 [200/0] via 192.168.131.20, 00:04:55
B        13.11.2.192 [200/0] via 192.168.131.20, 00:04:55
B        13.11.3.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.3.64 [200/0] via 192.168.131.20, 00:04:55
B        13.11.3.128 [200/0] via 192.168.131.20, 00:04:55
B        13.11.3.192 [200/0] via 192.168.131.20, 00:04:55
B        13.11.4.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.4.64 [200/0] via 192.168.131.20, 00:04:55
B        13.11.4.128 [200/0] via 192.168.131.20, 00:04:55
B        13.11.4.192 [200/0] via 192.168.131.20, 00:04:55
B        13.11.5.0 [200/0] via 192.168.131.20, 00:04:55
B        13.11.5.64 [200/0] via 192.168.131.20, 00:04:55
R11#

jme@ubuntu:/mnt/hgfs/jme/routing/bgp4r$ ruby -I.  examples/ibgp-ios-asn4bytes.rb 
I, [08:16#19199]  INFO -- : BGP::Neighbor Open Socket old state Idle new state Active
I, [08:16#19199]  INFO -- : BGP::Neighbor SendOpen
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Open Message (1), length: 45
  Version 4, my AS 23456, Holdtime 180s, ID 0.0.0.1
  Option Capabilities Advertisement (2): [0206010400010001]
    Multiprotocol Extensions (1), length: 4
      AFI IPv4 (1), SAFI Unicast (1)
  Option Capabilities Advertisement (2): [0206410400030196]
    Capability(65): 4-octet AS number: 197014
  
0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  002d 0104 5ba0 00b4 0000 0001 1002 0601
0x0002:  0400 0100 0102 0641 0400 0301 96


D, [08:16#19199] DEBUG -- : #<BGP::IO::Input:0x00000000ade6e8> #<Thread:0x00000000add888> started
D, [08:16#19199] DEBUG -- : #<BGP::IO::Output:0x00000000ade5f8> #<Thread:0x00000000add6d0> started
I, [08:16#19199]  INFO -- : BGP::Neighbor ev_send_open old state Active new state OpenSent
I, [08:16#19199]  INFO -- : BGP::Neighbor RecvOpen
D, [08:16#19199] DEBUG -- : BGP::Neighbor Recv Open Message (1), length: 57
  Version 4, my AS 23456, Holdtime 180s, ID 2.2.2.2
  Option Capabilities Advertisement (2): [0206010400010001]
    Multiprotocol Extensions (1), length: 4
      AFI IPv4 (1), SAFI Unicast (1)
  Option Capabilities Advertisement (2): [02028000]
    Route Refresh (Cisco) (128), length: 2
  Option Capabilities Advertisement (2): [02020200]
    Route Refresh (2), length: 2
  Option Capabilities Advertisement (2): [02024600]
  Option Capabilities Advertisement (2): [0206410400030196]
    Capability(65): 4-octet AS number: 197014
  
0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0039 0104 5ba0 00b4 0202 0202 1c02 0601
0x0002:  0400 0100 0102 0280 0002 0202 0002 0246
0x0003:  0002 0641 0400 0301 96


I, [08:16#19199]  INFO -- : BGP::Neighbor RecvOpen old state OpenSent new state OpenConfirm
I, [08:16#19199]  INFO -- : BGP::Neighbor RecvKeepalive
D, [08:16#19199] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [08:16#19199]  INFO -- : BGP::Neighbor SendKeepalive
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

D, [08:16#19199] DEBUG -- : BGP::Neighbor SendKeepAlive state is OpenConfirm
I, [08:16#19199]  INFO -- : BGP::Neighbor RecvKeepAlive old state OpenConfirm new state Established
I, [08:16#19199]  INFO -- : BGP::Neighbor version: 4, id: 0.0.0.1, as: 197014, holdtime: 180, peer addr: 192.168.131.11, local addr:  started
I, [08:16#19199]  INFO -- : BGP::Neighbor SendUpdate
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 65
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
  Mp Reach (14), length: 14, Flags [O]: 
    AFI IPv4 (1), SAFI Unicast (1)
    nexthop: 192.168.131.20
      13.11.0.0/26
   0x0000:  0001 0104 c0a8 8314 001a 0d0b 0000

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0041 0200 0000 2a40 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  800e 0e00 0101 04c0 a883 1400 1a0d 0b00
0x0004:  00


I, [08:16#19199]  INFO -- : BGP::Neighbor SendUpdate
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 110
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
  Mp Reach (14), length: 59, Flags [O]: 
    AFI IPv4 (1), SAFI Unicast (1)
    nexthop: 192.168.131.20
      13.11.0.64/26
      13.11.0.128/26
      13.11.0.192/26
      13.11.1.0/26
      13.11.1.64/26
      13.11.1.128/26
      13.11.1.192/26
      13.11.2.0/26
      13.11.2.64/26
      13.11.2.128/26
   0x0000:  0001 0104 c0a8 8314 001a 0d0b 0040 1a0d
   0x0001:  0b00 801a 0d0b 00c0 1a0d 0b01 001a 0d0b
   0x0002:  0140 1a0d 0b01 801a 0d0b 01c0 1a0d 0b02
   0x0003:  001a 0d0b 0240 1a0d 0b02 80

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  006e 0200 0000 5740 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  800e 3b00 0101 04c0 a883 1400 1a0d 0b00
0x0004:  401a 0d0b 0080 1a0d 0b00 c01a 0d0b 0100
0x0005:  1a0d 0b01 401a 0d0b 0180 1a0d 0b01 c01a
0x0006:  0d0b 0200 1a0d 0b02 401a 0d0b 0280


I, [08:16#19199]  INFO -- : BGP::Neighbor SendUpdate
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 110
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
  Mp Reach (14), length: 59, Flags [O]: 
    AFI IPv4 (1), SAFI Unicast (1)
    nexthop: 192.168.131.20
      13.11.2.192/26
      13.11.3.0/26
      13.11.3.64/26
      13.11.3.128/26
      13.11.3.192/26
      13.11.4.0/26
      13.11.4.64/26
      13.11.4.128/26
      13.11.4.192/26
      13.11.5.0/26
   0x0000:  0001 0104 c0a8 8314 001a 0d0b 02c0 1a0d
   0x0001:  0b03 001a 0d0b 0340 1a0d 0b03 801a 0d0b
   0x0002:  03c0 1a0d 0b04 001a 0d0b 0440 1a0d 0b04
   0x0003:  801a 0d0b 04c0 1a0d 0b05 00

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  006e 0200 0000 5740 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  800e 3b00 0101 04c0 a883 1400 1a0d 0b02
0x0004:  c01a 0d0b 0300 1a0d 0b03 401a 0d0b 0380
0x0005:  1a0d 0b03 c01a 0d0b 0400 1a0d 0b04 401a
0x0006:  0d0b 0480 1a0d 0b04 c01a 0d0b 0500


I, [08:16#19199]  INFO -- : BGP::Neighbor SendUpdate
D, [08:16#19199] DEBUG -- : BGP::Neighbor Send Update Message (2), length: 65
Path Attributes:
  Next Hop (3), length: 4, Flags [T]: 192.168.131.20
   0x0000:  c0a8 8314
  Origin (1), length: 1, Flags [T]: igp
   0x0000:  00
  As Path (2), length: 4, Flags [T]: 200
   0x0000:  0201 00c8
  Local Pref (5), length: 4, Flags [T]: (0x0064) 100
   0x0000:  0000 0064
  Mp Reach (14), length: 14, Flags [O]: 
    AFI IPv4 (1), SAFI Unicast (1)
    nexthop: 192.168.131.20
      13.11.5.64/26
   0x0000:  0001 0104 c0a8 8314 001a 0d0b 0540

0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0041 0200 0000 2a40 0304 c0a8 8314 4001
0x0002:  0100 4002 0402 0100 c840 0504 0000 0064
0x0003:  800e 0e00 0101 04c0 a883 1400 1a0d 0b05
0x0004:  40


I, [08:16#19199]  INFO -- : BGP::Neighbor RecvKeepalive
D, [08:16#19199] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [08:16#19199]  INFO -- : BGP::Neighbor RecvUpdate
D, [08:16#19199] DEBUG -- : BGP::Neighbor Recv Update Message (2), length: 23


0x0000:  ffff ffff ffff ffff ffff ffff ffff ffff
0x0001:  0017 0200 0000 00


I, [09:08#19199]  INFO -- : BGP::Neighbor RecvKeepalive
D, [09:08#19199] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [09:16#19199]  INFO -- : BGP::Neighbor SendKeepalive
D, [09:16#19199] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

I, [10:01#19199]  INFO -- : BGP::Neighbor RecvKeepalive
D, [10:01#19199] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]
