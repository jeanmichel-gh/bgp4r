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
require 'bgp/io'
require 'bgp/neighbor/add_path_cap'

module BGP

  class Neighbor
    include Observable
    
    def log_info(txt)
      Log.info "#{self.class} #{txt}"
    end

    def log_warn(txt)
      Log.warn "#{self.class} #{txt}"
    end

    def log_debug(txt)
      Log.debug "#{self.class} #{txt}"
    end

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
      # @cap = Hash.new
      @state = :Idle
      @threads=ThreadGroup.new
      @mutex = Mutex.new
      @eventQ = Queue.new
      event_dispatch
    end
    
    [:Idle, :Established, :OpenRecv, :OpenConfirm, :Active, :OpenSent].each do |state|
      define_method("is_#{state.to_s.downcase}?") do
        @state == state
      end
    end
    
    # FIXME:
    #  neighbor.add_capability 
    #  neighbor.remove_capability 
    #  neighbor.capability :as4_byte | :as4 | :as4byte
    #  neighbor.capability :route_refresh, :rr
    #  neighbor.capability :route_refresh, 128
    #  neighbor.capability :mbgp, :ipv4, :unicast
    #  neighbor.capability :mbgp, :ipv4, :multicast
    
    def capability(*args)
      @opt_parms << if args[0].is_a?(Symbol)
        case args[0]
        when :route_refresh, :rr
          OPT_PARM::CAP::Route_refresh.new(*args[1..-1])
        when :mbgp
          OPT_PARM::CAP::Mbgp.new(*args[1..-1])
        when :as4_byte, :as4byte, :as4
          OPT_PARM::CAP::As4.new(@my_as)
        when :gr, :graceful_restart
          OPT_PARM::CAP::Graceful_restart.new(*args[1..-1])
        else
          raise ArgumentError, "Invalid argument #{args.inspect}", caller
        end        
      elsif args[0].is_a?(OPT_PARM::Capability)
        args[0]
      else
        raise ArgumentError, "Invalid argument"
      end
    end

    def state
      "#{@state}"
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
            msg = BGP::Message.factory(m, @session_info)
            log_info "Recv#{msg.class.to_s.split('::').last}"
            log_debug "Recv #{msg}\n"
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
            changed and notify_observers(msg)
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
        log_info "#{x['name']}: stopped at #{Time.now.strftime("%I:%M:%S%P")}"
      }
    end
    
    def open
      @open ||= BGP::Open.new(version, @my_as, holdtime, @id, *@opt_parms)
    end
    
    def version
      @version ||= 4
    end
    
    def holdtime
      @holdtime ||= 180
    end
    
    def enable(auto_retry=:no_auto_retry, wait= :wait)
      return if @state == :Established
      disable unless @state == :Idle
      
      init_socket
      init_io
            
      [@in, @out].each { |io| 
        io.start 
        @threads.add io.thread
      }
            
      send_open :ev_send_open
      
      retry_thread if auto_retry == :auto_retry
      
      if wait == :wait
        loop do
          sleep(0.3)
          break if @state == :Established
        end
        log_info "#{self} started"
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

    define_method(:in) do
      @in.thread
    end
    define_method(:out) do
      @out.thread
    end

    attr_reader :as4byte, :path_id
    
    def as4byte?
      @session_info.as4byte?
    end

    def send_message(m)
      raise if m.nil?
      return unless @out
      unless m.is_a?(String)
        log_info "Send#{m.class.to_s.split('::')[-1]}"
        log_debug "Send #{m.is_a?(Update) ? m.to_s : m }\n"
      end
      #FIXME: enqueue [m, @session_info]
      if m.is_a?(Update)
        @out.enq m.encode(@session_info)
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
      @in = BGP::IO::Input.new(@socket, holdtime, self)
      @out = BGP::IO::Output.new(@socket, @holdtime, self)
      new_state(:Active, "Open Socket")
    end
        
    def update(*args)
      @eventQ.enq(args)
    end
    
    def new_state(state, txt='')
      log_info "#{txt} old state #{@state} new state #{state}"
      @state = state
    end

    def send_open(ev)
      case @state
      when :OpenRecv
        send_message open  ; new_state :OpenConfirm, ev
      when :Active
        send_message open  ; new_state :OpenSent, ev
      else
        Log.warn "#{self.class}: attempt to send OPEN msg while in #{@state}"
      end
    end
  
    def rcv_open(peer_open)
      @session_info = Neighbor::Capabilities.new open, peer_open
      
      #FIXME: methods to session_info.rmt_version .remote_as, .remote_bgp_id ...
      @rmt_version = peer_open.version
      @rmt_as = peer_open.local_as
      @rmt_bgp_id = peer_open.bgp_id

      #FIXME: mv holdtime to session_info ?
      # session_info.holdtime
      if @holdtime > peer_open.holdtime
        @out.holdtime = @in.holdtime = peer_open.holdtime
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
      
    end
    
    def rcv_keepalive
      if @state == :OpenConfirm
        send_message(BGP::Keepalive.new)
        log_debug "SendKeepAlive state is #{@state}"
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
      log_info "#{m}"
      changed and notify_observers(m)
      disable
    end
    
    def rcv_route_refresh(m)
    end
    
    def rcv_update(m)
    end
    
    def to_s
      "version: #{version}, id: #{@id}, as: #{@my_as}, holdtime: #{@holdtime}, peer addr: #{@remote_addr}, local addr: #{@local_addr}"
    end
    
  end

end

load "../../test/neighbor/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
