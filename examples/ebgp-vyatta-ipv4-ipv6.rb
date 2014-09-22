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

nexthop4='22.22.22.254'
nexthop6='2014:33::fe'

pa = Path_attribute.new(
 Next_hop.new(nexthop4),
 Origin.new(0),
 Multi_exit_disc.new(0),
 As_path.new(200),
)

ipv4_routes = create_fiber("13.11.0.0/26")
ipv6_routes = create_fiber("2014:13:11::0/49")

Log.create
Log.level=Logger::INFO

n4 = Neighbor.new :my_as=> 200, :remote_addr => '22.22.22.1', :id=> '20.20.20.20'
n6 = Neighbor.new :my_as=> 200, :remote_addr => '2014:22::1', :id=> '20.20.20.20' 

[n4, n6].each do |n|
  n.capability_mbgp_ipv4_unicast  
  n.capability_mbgp_ipv6_unicast  
end

[n4,n6].each { |n| n.start }

while subnets = ipv4_routes.resume
  n6.send_message Update.new pa.replace(Mp_reach.new(:afi=>1, :safi=>1, :nexthop=> nexthop4, :nlris=> subnets))
end

while subnets = ipv6_routes.resume
  n4.send_message Update.new pa.replace(Mp_reach.new(:afi=>2, :safi=>1, :nexthop=> nexthop6, :nlris=> subnets))
end


sleep(300)

__END__

Produces:

vyatta@R1:~$ show ip bgp summary 
BGP router identifier 1.1.1.1, local AS number 100
BGP table version is 42
1 BGP AS-PATH entries
0 BGP community entries

Neighbor        V    AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd
22.22.22.254    4   200     131      93       42    0    0 00:00:07        0
2014:22::fe     4   200      71      50       42    0    0 00:00:07       22

Total number of neighbors 2
vyatta@R1:~$ 


[jme@localhost bgp4r]$ ruby -I. examples/ebgp-vyatta-ipv4-ipv6.rb 
I, [33:40#10776]  INFO -- : BGP::Neighbor Open Socket old state Idle new state Active
I, [33:40#10776]  INFO -- : BGP::Neighbor SendOpen
I, [33:40#10776]  INFO -- : BGP::Neighbor ev_send_open old state Active new state OpenSent
I, [33:40#10776]  INFO -- : BGP::Neighbor RecvOpen
I, [33:40#10776]  INFO -- : BGP::Neighbor RecvOpen old state OpenSent new state OpenConfirm
I, [33:40#10776]  INFO -- : BGP::Neighbor RecvKeepalive
I, [33:40#10776]  INFO -- : BGP::Neighbor SendKeepalive
I, [33:40#10776]  INFO -- : BGP::Neighbor RecvKeepAlive old state OpenConfirm new state Established
I, [33:41#10776]  INFO -- : BGP::Neighbor version: 4, id: 20.20.20.20, as: 200, holdtime: 180, peer addr: 22.22.22.1, local addr:  started
I, [33:41#10776]  INFO -- : BGP::Neighbor Open Socket old state Idle new state Active
I, [33:41#10776]  INFO -- : BGP::Neighbor SendOpen
I, [33:41#10776]  INFO -- : BGP::Neighbor ev_send_open old state Active new state OpenSent
I, [33:41#10776]  INFO -- : BGP::Neighbor RecvOpen
I, [33:41#10776]  INFO -- : BGP::Neighbor RecvOpen old state OpenSent new state OpenConfirm
I, [33:41#10776]  INFO -- : BGP::Neighbor RecvKeepalive
I, [33:41#10776]  INFO -- : BGP::Neighbor SendKeepalive
I, [33:41#10776]  INFO -- : BGP::Neighbor RecvKeepAlive old state OpenConfirm new state Established
I, [33:41#10776]  INFO -- : BGP::Neighbor version: 4, id: 20.20.20.20, as: 200, holdtime: 180, peer addr: 2014:22::1, local addr:  started
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [33:41#10776]  INFO -- : BGP::Neighbor SendUpdate
I, [34:10#10776]  INFO -- : BGP::Neighbor RecvKeepalive
I, [34:11#10776]  INFO -- : BGP::Neighbor RecvKeepalive


vyatta@R1:~$ show ip bgp
BGP table version is 14, local router ID is 1.1.1.1
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal, l - labeled
              S Stale
Origin codes: i - IGP, e - EGP, ? - incomplete

   Network          Next Hop            Metric LocPrf Weight Path
*> 13.11.0.0/26     22.22.22.254             0             0 200 i
*> 13.11.0.64/26    22.22.22.254             0             0 200 i
*> 13.11.0.128/26   22.22.22.254             0             0 200 i
*> 13.11.0.192/26   22.22.22.254             0             0 200 i
*> 13.11.1.0/26     22.22.22.254             0             0 200 i
*> 13.11.1.64/26    22.22.22.254             0             0 200 i
*> 13.11.1.128/26   22.22.22.254             0             0 200 i
*> 13.11.1.192/26   22.22.22.254             0             0 200 i
*> 13.11.2.0/26     22.22.22.254             0             0 200 i
*> 13.11.2.64/26    22.22.22.254             0             0 200 i
*> 13.11.2.128/26   22.22.22.254             0             0 200 i
*> 13.11.2.192/26   22.22.22.254             0             0 200 i
*> 13.11.3.0/26     22.22.22.254             0             0 200 i
*> 13.11.3.64/26    22.22.22.254             0             0 200 i
*> 13.11.3.128/26   22.22.22.254             0             0 200 i
*> 13.11.3.192/26   22.22.22.254             0             0 200 i
*> 13.11.4.0/26     22.22.22.254             0             0 200 i
*> 13.11.4.64/26    22.22.22.254             0             0 200 i
*> 13.11.4.128/26   22.22.22.254             0             0 200 i
*> 13.11.4.192/26   22.22.22.254             0             0 200 i
*> 13.11.5.0/26     22.22.22.254             0             0 200 i
*> 13.11.5.64/26    22.22.22.254             0             0 200 i

Total number of prefixes 22
vyatta@R1:~$

vyatta@R1:~$ show ipv6 bgp           
BGP table version is 8, local router ID is 1.1.1.1
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal, l - labeled
              S Stale
Origin codes: i - IGP, e - EGP, ? - incomplete

   Network          Next Hop            Metric LocPrf Weight Path
*> 2014:13:11::/49  2014:33::fe               0             0 200 i
*> 2014:13:11:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:12::/49  2014:33::fe               0             0 200 i
*> 2014:13:12:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:13::/49  2014:33::fe               0             0 200 i
*> 2014:13:13:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:14::/49  2014:33::fe               0             0 200 i
*> 2014:13:14:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:15::/49  2014:33::fe               0             0 200 i
*> 2014:13:15:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:16::/49  2014:33::fe               0             0 200 i
*> 2014:13:16:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:17::/49  2014:33::fe               0             0 200 i
*> 2014:13:17:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:18::/49  2014:33::fe               0             0 200 i
*> 2014:13:18:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:19::/49  2014:33::fe               0             0 200 i
*> 2014:13:19:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:1a::/49  2014:33::fe               0             0 200 i
*> 2014:13:1a:8000::/49
                    2014:33::fe               0             0 200 i
*> 2014:13:1b::/49  2014:33::fe               0             0 200 i
*> 2014:13:1b:8000::/49
                    2014:33::fe               0             0 200 i

Total number of prefixes 22
vyatta@R1:~$ 


=======================================================

[jme@localhost bgp4r]$ ifconfig p7p1 | grep inet
        inet 22.22.22.254  netmask 255.255.255.0  broadcast 22.22.22.255
        inet6 fe80::a00:27ff:fef4:4594  prefixlen 64  scopeid 0x20<link>
        inet6 2014:22::fe  prefixlen 64  scopeid 0x0<global>
        

=======================================================

vyatta@R1:~$ show configuration 
interfaces {
    ethernet eth0 {
        address dhcp
        duplex auto
        hw-id 08:00:27:eb:d8:59
        smp_affinity auto
        speed auto
    }
    ethernet eth1 {
        address 22.22.22.1/24
        address 2014:22::1/48
        duplex auto
        hw-id 08:00:27:a2:42:17
        smp_affinity auto
        speed auto
    }
    loopback lo {
        address 10.0.0.11/32
    }
}

protocols {
  bgp 100 {
      neighbor 22.22.22.254 {
          address-family {
              ipv6-unicast {
              }
          }
          remote-as 200
      }
      neighbor 2014:22::fe {
          remote-as 200
      }
      parameters {
          router-id 1.1.1.1
      }
  }
}

=======================================================

vyatta@R1:~$ show version 
Version:      VSE6.6R6S1
Description:  Brocade Vyatta 5410 vRouter 6.6 R6S1
Copyright:    2006-2014 Vyatta, Inc.
Built by:     autobuild@vyatta.com
Built on:     Fri Jul 11 18:57:24 UTC 2014
Build ID:     1407111901-b191d5c
System type:  Intel 64bit
Boot via:     image
Hypervisor:   VirtualBox
HW model:     VirtualBox
HW S/N:       0
HW UUID:      D4AE187C-C189-4D7D-ABEE-4F7EF8FF5C64
Uptime:       18:17:31 up  2:41,  2 users,  load average: 0.00, 0.01, 0.05

