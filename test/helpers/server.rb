module BGP
  module TestHelpers
    def stop_server
      # silence rake warnings....
      @c      ||=nil
      @server ||=nil
      @thread ||=nil
      @s      ||=nil
      @s.stop if @s
      @c.stop if @c
      @server.close if @server
      @thread.kill if @thread
    rescue
    end
    def start_server(port, cap=nil)
      @server = TCPServer.new(port)
      @s = Neighbor.new(4, 100, 180, '0.0.0.1', '127.0.0.1', '127.0.0.1')
      @s.add_cap cap if cap
      @thread = Thread.new(@s, @server) do |peer, sock| 
        begin
          while (session = sock.accept())
            @s.start_session(session)
          end
        rescue IOError
        end
      end
    rescue
    end
  end
end