require 'net/telnet'
require 'bgp4r'


class LiveFeed
  def initialize
    @host = '129.82.138.6'
    @port = '50001'
    @timeout = 10
  end

  def open

    @buf = ''
    @queue = Queue.new

    th = Thread.new do 
      feed = Net::Telnet.new('Host'=> @host, 
                             'Port' => @port, 
                             'Timeout'=> 5, 
                             'Telnetmode' => false)
      loop do
        @buf += feed.recv(2000)
      end
    end
    Thread.new do
      loop do
        pos = (@buf =~ /<OCTETS length=.*>([^<]*)<\/OCTETS>/)
        if pos
          @queue.enq [$1].pack('H*')
          @buf.slice!(0,pos+10)
          sleep(0.1)
        end
      end
    end
  end
  
  def read
    @queue.deq
  end

  alias msg read
  alias readmessage read
    
end




