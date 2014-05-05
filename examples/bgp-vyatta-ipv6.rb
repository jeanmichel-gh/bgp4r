require 'bgp4r'

include BGP

Log.create
Log.level=Logger::DEBUG

neighbor = Neighbor.new \
    :version=> 4, 
    :my_as=> 100, 
    :remote_addr => '169.253.253.128', 
    :id=> '20.20.20.20', 
    :holdtime=> 180

  neighbor.capability_mbgp_ipv4_unicast  
  neighbor.capability_mbgp_ipv6_unicast  

 nexthop='fe80::20c:29ff:fcab:13b'
 
 pa = Path_attribute.new(
   Origin.new(0),
   Multi_exit_disc.new(0),
   As_path.new(),
   Mp_reach.new(:afi=>2, :safi=>1, :nexthop=> nexthop,
                :nlris=> ['2014:50:4::/64', '2014:51:4::/64', '2014:52:4::/64'])
 )

 neighbor.start

 Log.level=Logger::INFO

 neighbor.send_message Update.new(pa)

 sleep (300)

__END__

vyatta@vyatta:~$ show ipv6 route
Codes: K - kernel route, C - connected, S - static, R - RIPng, O - OSPFv3,
       I - ISIS, B - BGP, * - FIB route.

C>* ::1/128 is directly connected, lo
B>* 2014:50:4::/64 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:00:20
B>* 2014:51:4::/64 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:00:20
B>* 2014:52:4::/64 [200/0] via fe80::20c:29ff:fcab:13b, eth9, 00:00:20
C * fe80::/64 is directly connected, eth6
C>* fe80::/64 is directly connected, eth9


vyatta@vyatta:~$  show interfaces 
Codes: S - State, L - Link, u - Up, D - Down, A - Admin Down
Interface    IP Address                        S/L  Description                 
---------    ----------                        ---  -----------                 
eth6         192.168.244.153/24                u/u                              
eth9         169.253.253.128/24                u/u                              
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
