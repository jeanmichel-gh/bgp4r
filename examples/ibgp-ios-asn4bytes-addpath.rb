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
