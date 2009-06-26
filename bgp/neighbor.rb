#--
# Copyright 2008, 2009 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
# 
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'socket'
require 'thread'
require 'observer'

module BGP

  class Neighbor
    include Observable

    def initialize(*args)
      @opt_parms = []
      if args.size==1 and args[0].is_a?(Hash)
        @version = args[0][:version] if args[0][:version]
        @my_as = args[0][:my_as] if args[0][:my_as]
        @holdtime = args[0][:holdtime] if args[0][:holdtime]
        @id = args[0][:id] if args[0][:id]
        @remote_addr = args[0][:remote_addr] if args[0][:remote_addr]
        @local_addr = args[0][:local_addr] if args[0][:local_addr]
      else
        @version, @my_as, @holdtime, @id, @remote_addr, @local_addr  = args
      end
      @as4byte=false
      @state = :Idle
      @threads=ThreadGroup.new
      @mutex = Mutex.new
      @eventQ = Queue.new
      event_dispatch
    end
    
    #  neighbor.capability :as4_byte
    #  neighbor.capability :route_refresh
    #  neighbor.capability :route_refresh, 128
    #  neighbor.capability :mbgp, :ipv4, :unicast
    #  neighbor.capability :mbgp, :ipv4, :multicast
    def capability(*args)
      @opt_parms << if args[0].is_a?(Symbol)
        case args[0]
        when :route_refresh ; Route_refresh_cap.new(*args[1..-1])
        when :mbgp          ; Mbgp_cap.new(*args[1..-1])
        when :as4_byte      ; As4_cap.new(@my_as)
        end        
      elsif args[0].is_a?(Capability) and args.size==1
        args[0]
      else
        raise ArgumentError, "Invalid argument"
      end
    end

    def state
      @state.to_s
    end

    def retry_thread(action=:start)
      case action
      when :start
        @restart_thread = Thread.new do
          Thread.current['name']='restart'
          loop do
            enable if @state == :Idle
            sleep(5)
          end
        end

      when :stop
        if defined? @restart_thread and @restart_thread.alive?
          @restart_thread.kill ; @restart_thread.join
        end
      end
    end

    def event_dispatch
      Thread.new(@eventQ) do |eventQ|
        loop do
          ev, type, m = eventQ.deq
          case ev
          when :ev_msg
            msg = BGP::Message.factory(m)
            Log.info "Recv#{msg.class.to_s.split('::')[-1]}"
            Log.debug "Recv #{msg}\n"            
            changed and notify_observers(msg)
            if msg.is_a?(Update)
              rcv_update(msg)
            elsif msg.is_a?(Notification)
              rcv_notification(msg)
            elsif msg.is_a?(Open)
              rcv_open(msg)
            elsif msg.is_a?(Route_refresh)
              rcv_route_refresh(msg)
            elsif msg.is_a?(Orf_route_refresh)
              rcv_route_refresh(msg)
            elsif msg.is_a?(Keepalive)
              rcv_keepalive
            else
              Log.error "unexpected message type #{type}"
            end
          when :ev_conn_reset
            Log.warn "#{type}"
            disable
          when :ev_holdtime_expire
            Log.warn "Holdtime expire: #{type}"
            disable
          else
            Log.error "unexpected event #{ev}"
          end
        end
      end
    end

    def clean
      @threads.list.each { |x| 
        x.exit; x.join
        Log.info "#{x['name']}: stopped at #{Time.now.strftime("%I:%M:%S%P")}"
      }
    end


    def _open_msg_
      @open = BGP::Open.new(@version, @my_as, @holdtime, @id, *@opt_parms)
    end
    private :_open_msg_

    def enable(auto_retry=:no_auto_retry, wait= :wait)
      return if @state == :Established
      disable unless @state == :Idle
      
      init_socket
      init_io
      @open = _open_msg_
            
      [@in, @out].each { |io| 
        io.start 
        @threads.add io.thread
      }
      
      def in  ; @in.thread  ; end
      def out ; @out.thread ; end
      
      send_open :ev_send_open
      
      retry_thread if auto_retry == :auto_retry
      
      if wait == :wait
        loop do
          sleep(0.3)
          break if @state == :Established
        end
        Log.info "#{self} started"
      end
      
    rescue => e
      Log.error "#{e}"
      disable
    end
    alias start enable
        
    def disable
      @socket.close  if defined?(@socket) and not @socket.closed?
      clean
      new_state :Idle, "Disable"
    end
    alias stop disable

    def send_message(m)
      unless m.is_a?(String)
        Log.info "Send#{m.class.to_s.split('::')[-1]}"
        Log.debug "Send #{m.is_a?(Update) ? m.to_s(@as4byte) : m }\n"
      end
      if m.is_a?(Update)
        @out.enq m.encode(@as4byte)
      else
        @out.enq m
      end
    end

    def init_socket
      @socket = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, Socket::IPPROTO_TCP)
      remote = Socket.pack_sockaddr_in(179, @remote_addr) 
      local = Socket.pack_sockaddr_in(0, @local_addr) unless @local_addr.nil?
      remote_sock_addr = Socket.pack_sockaddr_in(179, @remote_addr) 
      local_sock_addr = Socket.pack_sockaddr_in(0, @local_addr) unless @local_addr.nil? 
      @socket.bind(local_sock_addr) unless @local_addr.nil?
      @socket.connect(remote_sock_addr)
    end
      
    def init_io
      @in = BGP::IO::Input.new(@socket, @holdtime, self)
      @out = BGP::IO::Output.new(@socket, @holdtime, self)
      new_state(:Active, "Open Socket")
    end
        
    def update(*args)
      @eventQ.enq(args)
    end
    
    def new_state(state, txt='')
      Log.info "#{txt} old state #{@state} new state #{state}"
      @state = state
    end

    def _send_open_(open)
      send_message open
    end
    private :_send_open_

    def send_open(ev)
      case @state
      when :OpenRecv
        _send_open_ @open ; new_state :OpenConfirm, ev
      when :Active
        _send_open_ @open     ; new_state :OpenSent, ev
      else
        Log.warn "#{self.class}: attempt to send OPEN msg while in #{@state}"
      end    
    end
  
    def rcv_open(o)
      @rmt_version = o.version
      @rmt_as = o.local_as
      @rmt_bgp_id = o.bgp_id

      if @holdtime > o.holdtime
        @out.holdtime = @in.holdtime = o.holdtime
      end

      case @state
      when :OpenSent
        send_message(BGP::Message.keepalive)
        new_state :OpenConfirm, "RecvOpen"
      when :Active
        send_open "RecvOpen"
        new_state :OpenConfirm, "RecvOpen"
      else
        Log.warn "#{self.class}: received open message while in state #{@state}"
      end    
      @as4byte = @open.has?(As4_cap) and o.has?(As4_cap)
    end
    
    def rcv_keepalive
      if @state == :OpenConfirm
        send_message(BGP::Keepalive.new)
        Log.debug "SendKeepAlive"
        new_state(:Established, 'RecvKeepAlive')
        @keepalive_thread = Thread.new(@holdtime/3) do |h|
          Thread.current['name'] = "BGP Keepalive interval:(#{h})"
          loop do
            sleep(h)
            send_message(BGP::Keepalive.new)
          end
        end
        @threads.add(@keepalive_thread)
      end
    end

    def rcv_notification(m)
      Log.info "#{m}"
      disable
    end
    
    def to_s
      "version: #{@version}, id: #{@id}, as: #{@my_as}, holdtime: #{@holdtime}, peer addr: #{@remote_addr}, local addr: #{@local_addr}"
    end

  end

end

load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
