require 'net/telnet'
require 'bgp4r'

@buf = '' ; n=0
th = Thread.new do 
  feed = Net::Telnet.new('Host'=> '129.82.138.6', 'Port' => '50001', 'Timeout'=> 5, 'Telnetmode' => false)
  loop do
    @buf += feed.recv(1000)
  end
end

loop do
  pos = (@buf =~ /<OCTETS length=.*>([^<]*)<\/OCTETS>/)
  if pos
    puts "\n\##{n+=1}: **** #{$1} ****"
    u=  BGP::Message.factory([$1].pack('H*'))
    if u.is_a?(BGP::Update) and u.path_attribute
      pa = u.path_attribute
      pa.replace BGP::Next_hop.new('10.0.0.1')
      pa[:as_path].find_sequence.prepend(100)
      puts u 
    end
    @buf.slice!(0,pos+10)
    break if n>10
  end
end

__END__



--max-msg 10000
--nexthop-rewrite 10.0.0.1
--as-path-prepend 100


