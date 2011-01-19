module BGP
  module TestHelpers
    def stop_server
      @s.stop if @s
      @c.stop if @c
      @server.close if @server
      @thread.kill if @thread
    end
    def start_server(port, cap=nil)
      @server = TCPServer.new(port)
      @thread = Thread.new do 
        while (session = @server.accept())
          @s = Neighbor.new(4, 100, 180, '0.0.0.1', '127.0.0.1', '127.0.0.1')
          @s.add_cap cap if cap
          @s.start_session(session)
        end
      end
    end
  end
end