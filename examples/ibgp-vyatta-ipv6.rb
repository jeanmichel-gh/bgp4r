require 'bgp4r'

include BGP

Log.create
Log.level=Logger::INFO

neighbor = Neighbor.new \
:version=> 4, 
:my_as=> 100, 
:remote_addr => '169.253.253.102', 
:id=> '20.20.20.20', 
:holdtime=> 180

neighbor.capability_mbgp_ipv4_unicast  
neighbor.capability_mbgp_ipv6_unicast  

nexthop='fe80::20c:29ff:fcab:13b'

pa = Path_attribute.new(
 Origin.new(0),
 Multi_exit_disc.new(0),
 As_path.new(),
)

# 22 routes, 5 routes per update
subnet = Fiber.new do 
  ipaddr = IPAddr.new "2014:13:11::1/65"
  pack=5
  prefixes=[]
  22.times do |i|
    prefixes << (ipaddr ^ i)
    next unless (i%pack)==0
    Fiber.yield prefixes
    prefixes=[]
  end
  Fiber.yield prefixes unless prefixes.empty?
  nil
end

neighbor.start

while nets = subnet.resume
  neighbor.send_message Update.new pa.replace(Mp_reach.new(:afi=>2, :safi=>1, :nexthop=> nexthop, :nlris=> nets))
end

sleep(300)

__END__


I, [11:26#26571]  INFO -- : BGP::Neighbor RecvOpen old state OpenSent new state OpenConfirm
I, [11:26#26571]  INFO -- : BGP::Neighbor RecvKeepalive
D, [11:26#26571] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [11:26#26571]  INFO -- : BGP::Neighbor SendKeepalive
D, [11:26#26571] DEBUG -- : BGP::Neighbor Send Keepalive Message (4), length: 19, [001304]

D, [11:26#26571] DEBUG -- : BGP::Neighbor SendKeepAlive state is OpenConfirm
I, [11:26#26571]  INFO -- : BGP::Neighbor RecvKeepAlive old state OpenConfirm new state Established
I, [11:26#26571]  INFO -- : BGP::Neighbor RecvKeepalive
D, [11:26#26571] DEBUG -- : BGP::Neighbor Recv Keepalive Message (4), length: 19, [001304]

I, [11:26#26571]  INFO -- : BGP::Neighbor version: 4, id: 20.20.20.20, as: 100, holdtime: 180, peer addr: 169.253.253.102, local addr:  started
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:26#26571]  INFO -- : BGP::Neighbor SendUpdate
I, [11:27#26571]  INFO -- : BGP::Neighbor RecvUpdate
I, [12:26#26571]  INFO -- : BGP::Neighbor SendKeepalive
I, [12:26#26571]  INFO -- : BGP::Neighbor RecvKeepalive


root@vyatta:~# show ipv6 route 
Codes: K - kernel route, C - connected, S - static, R - RIPng, O - OSPFv3,
       I - ISIS, B - BGP, * - FIB route.

C>* ::1/128 is directly connected, lo
B>* 2014:13:11::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:0:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:1::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:1:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:2::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:2:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:3::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:3:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:4::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:4:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:5::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:5:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:6::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:6:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:7::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:7:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:8::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:8:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:9::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:9:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:a::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
B>* 2014:13:11:a:8000::/65 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:01:01
C * fe80::/64 is directly connected, eth9
C>* fe80::/64 is directly connected, eth6
root@vyatta:~# 


vyatta@vyatta:~$  show interfaces 
Codes: S - State, L - Link, u - Up, D - Down, A - Admin Down
Interface    IP Address                        S/L  Description                 
---------    ----------                        ---  -----------                 
eth6         192.168.244.153/24                u/u                              
eth9         169.253.253.102/24                u/u                              
lo           127.0.0.1/8                       u/u                              
::1/128                          

vyatta@vyatta:~$ show configuration 
interfaces {
  ethernet eth6 {
    duplex auto
    hw-id 00:0c:29:6b:52:a9
    smp_affinity auto
    speed auto
  }
  ethernet eth9 {
    address dhcp
    duplex auto
    hw-id 00:0c:29:6b:52:9f
    smp_affinity auto
    speed auto
  }
  loopback lo {
  }
}
protocols {
  bgp 100 {
    neighbor 169.253.253.1 {
      address-family {
        ipv6-unicast {
        }
      }
      remote-as 100
    }
    parameters {
      router-id 1.2.3.4
    }
  }
}
