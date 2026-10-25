module BGP
  module TestHelpers
    # Stops the test server and the client neighbor @c. Safe to call twice.
    # Only the errors a stop can raise on a session that is going away are
    # rescued: Neighbor#stop closes a socket the peer may have reset, and
    # joins IO threads that may have died on it. Anything else is a bug and
    # is raised.
    def stop_server
      # silence rake warnings....
      @c      ||=nil
      @server ||=nil
      @thread ||=nil
      @s      ||=nil
      [@s, @c].each do |n|
        begin
          n.stop if n
        rescue IOError, SystemCallError, ClosedQueueError
        end
      end
    ensure
      @server.close if @server
      @thread.kill if @thread
    end
    # Starts a test BGP speaker (AS 100) listening on 127.0.0.1 and returns
    # the port. With the default port 0 the system picks a free one, so
    # tests do not collide on fixed ports. Raises when it cannot listen.
    def start_server(port=0, cap=nil)
      begin
        @server = TCPServer.new('127.0.0.1', port)
      rescue SystemCallError => e
        raise "start_server: cannot listen on 127.0.0.1 port #{port}: #{e.message}"
      end
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
      @server.addr[1]
    end
  end
end
