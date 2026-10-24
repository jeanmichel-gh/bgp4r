#require 'net/telnet'
require 'socket'
require 'bgp4r'

class LiveFeed
  HOST = '129.82.138.6'
  PORT = 50001
  CONNECT_TIMEOUT = 10
  OCTETS = /<OCTETS length=[^>]*>([^<]*)<\/OCTETS>/

  def self.open(**opts)
    new.open(**opts)
  end
  def open(host: HOST, port: PORT, timeout: CONNECT_TIMEOUT)
    @host = host
    @port = port
    @buf = ''.b
    @eof = false
    @lock = Mutex.new
    @cond = ConditionVariable.new
    @queue = Queue.new

    @feed = Socket.tcp @host, @port, connect_timeout: timeout

    @reader = Thread.new do
      loop do
        data = begin
          @feed.recv(5000).to_s
        rescue IOError, SystemCallError
          ''
        end
        @lock.synchronize do
          if data.empty?
            @eof = true
          else
            @buf << data
          end
          @cond.signal
        end
        break if data.empty?
      end
    end
    @th=Thread.new do
      loop do
        msg = @lock.synchronize do
          until (m = OCTETS.match(@buf)) || @eof
            @cond.wait(@lock)
          end
          @buf.slice!(0, m.end(0)) if m
          m
        end
        break unless msg
        @queue.enq [msg[1]].pack('H*')
      end
      @queue.close
    end
    self
  end
  def close
    @th.kill
    @reader.kill
    @feed.close
  end
  def read
    @queue.deq
  end
  alias msg read
  alias readmessage read
end


