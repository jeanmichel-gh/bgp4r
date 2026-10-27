#--
# Copyright 2008, 2009, 2014, 2026 Jean-Michel Esnault.
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
require 'bgp/observable'
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
        set args[0]
      else
        @version, @my_as, @holdtime, @id, @remote_addr, @local_addr  = args
      end
      @state = :Idle
      @session_info=nil
      @threads=ThreadGroup.new
      @mutex = Mutex.new
      @state_cv = ConditionVariable.new
      @eventQ = Queue.new
      @event_thread = event_dispatch
    end
    
    def set(_h)
      h = { :version=>4, :holdtime=>180 }.merge(_h)
      [:version, :my_as, :holdtime, :id, :remote_addr, :local_addr].each do |name|
        instance_variable_set("@#{name}", h[name]) if h.has_key?(name)
      end
      self.send_queue_limit = h[:send_queue_limit] if h.has_key?(:send_queue_limit)
      self.auto_as4 = h[:auto_as4] if h.has_key?(:auto_as4)
      self.policy = h[:policy] if h.has_key?(:policy)
    end

    # The receive policy for path attributes: :lenient (the default),
    # :strict or :raw. See Path_attribute::POLICIES.
    #
    # With :strict, a received UPDATE with a malformed attribute is not
    # passed on. Observers get the Malformed_attribute error instead. When
    # its RFC 7606 action is a session reset, the NOTIFICATION it names is
    # sent and the session stops (RFC 7606 section 3).
    def policy
      @policy || :lenient
    end

    def policy=(val)
      unless Path_attribute::POLICIES.include?(val)
        raise ArgumentError, "unknown receive policy #{val.inspect}, use #{Path_attribute::POLICIES.inspect}"
      end
      @policy = val
      @session_info.policy = val if @session_info.respond_to?(:policy=)
    end

    # On a session where the peer has no 4-octet AS capability, apply
    # Path_attribute#as4_fixup to each UPDATE sent (RFC 6793 section 4.2.2):
    # AS_TRANS in AS_PATH and AGGREGATOR, plus AS4_PATH and AS4_AGGREGATOR.
    # The default is true. With false, UPDATEs go out exactly as built,
    # and an AS number above 65535 is cut to its low 16 bits.
    def auto_as4
      defined?(@auto_as4) ? @auto_as4 : true
    end
    alias auto_as4? auto_as4

    def auto_as4=(val)
      @auto_as4 = val ? true : false
    end

    # How many messages may wait to be written to the socket. When the
    # queue is full, send_message waits. The default is 256.
    def send_queue_limit
      @send_queue_limit ||= BGP::IO::Output::DEFAULT_MAX
    end

    def send_queue_limit=(n)
      n = Integer(n)
      raise ArgumentError, "send_queue_limit must be at least 1, got #{n}" if n < 1
      @send_queue_limit = n
      @out.max = n if @out
    end

    # Messages waiting to be written to the socket right now.
    def send_queue_size
      @out ? @out.size : 0
    end
    
    [:Idle, :Established, :OpenRecv, :OpenConfirm, :Active, :OpenSent].each do |state|
      define_method("is_#{state.to_s.downcase}?") do
        @state == state
      end
    end
    
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
        when :extended_nexthop, :extended_next_hop
          # RFC 8950 section 4. With no family, IPv4 unicast with IPv6 next hops.
          fam = args[1..-1]
          OPT_PARM::CAP::Extended_nexthop.new(*(fam.empty? ? [1, 1, 2] : fam))
        else
          raise ArgumentError, "Invalid argument #{args.inspect}", caller
        end        
      elsif args[0].is_a?(OPT_PARM::Capability)
        args[0]
      else
        raise ArgumentError, "Invalid argument"
      end
    end
    alias :add_cap :capability
    
    def method_missing(name, *args, &block)
      if name.to_s =~ /^(capability|add_capability)_(.+)$/
        r = $2.dup
        @opt_parms << if r =~ /mbgp_(.+)/
          OPT_PARM::CAP::Mbgp.send $1
        elsif r =~ /(rr|route_refresh)/
          OPT_PARM::CAP::Route_refresh.new( *args)
        elsif r =~ /(4byte_as|as4byte|four_(byte|octet)_as)/
          OPT_PARM::CAP::As4.new(@my_as)
        elsif r =~ /(gr|graceful_restart)/
          OPT_PARM::CAP::Graceful_restart.new( *args)
        else
          super
        end
      else
        super
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
            start if @state == :Idle
            sleep(4)
          end
        end

      when :stop
        if defined? @restart_thread and @restart_thread.alive?
          @restart_thread.kill ; @restart_thread.join
        end
      end
    end

    # send_message could not queue the message because the session's output
    # queue is closed: stop or close happened. A RuntimeError, so callers
    # that rescue RuntimeError still catch it, but a class of its own, so
    # the event thread can tell it from a real error such as a send before
    # start.
    class SessionClosed < RuntimeError ; end

    # The thread that handles messages and events from the session.
    # It runs until close.
    def event_dispatch
      Thread.new(@eventQ) do |eventQ|
        Thread.current['name'] = 'BGP event dispatch'
        loop do
          event = eventQ.deq
          # A closed and empty queue returns nil: close was called.
          break if event.nil?
          begin
            dispatch_event(*event)
          rescue SessionClosed => e
            # stop won the race: it closed the output queue while this event
            # was being handled, so the reply the FSM wanted to send has
            # nowhere to go. Drop the event and keep the thread, which must
            # outlive stop so that start works again.
            log_info "#{e.message}, event dropped"
          end
        end
      end
    end

    # Handles one event from the queue. Called on the event thread only.
    def dispatch_event(ev, type=nil, m=nil)
      case ev
      when :ev_msg
        begin
          msg = BGP::Message.factory(m, @session_info)
        rescue UnknownBgpMessage => e
          Log.error e.message
          return
        rescue Malformed_attribute => e
          rcv_malformed(e)
          return
        end
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
        stop
      when :ev_holdtime_expire
        Log.warn "Holdtime expire: #{type}"
        stop
        changed and notify_observers(BGP::Notification.code_to_s(4))
      else
        Log.error "unexpected event #{ev}"
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
    
    def start_session(session)
      @socket=session
      return unless  @state == :Idle
      init_io
      send_open :ev_send_open
    end
    
    # The error that made the last start fail, or nil.
    attr_reader :last_error

    # Opens the session. Returns true when the :waitfor state was reached,
    # or with :no_blocking once the OPEN was queued. Returns false on any
    # error: the error is logged, kept in last_error, and the session is
    # stopped. With :raise => true the error is raised again after that.
    def start(arg={})
      @last_error = nil
      options = {:port=> 179, :auto_retry=> false, :no_blocking=>false, :waitfor=> :Established, :timeout=> 60, :raise=> false}.merge(arg)
      raise IOError, "#{self.class} is closed" if closed?
      return true if @state == :Established
      stop unless @state == :Idle
      if options[:session]
        @socket = options[:session]
      else
        @socket = TCPSocket.new(@remote_addr, options[:port], local_host=@local_addr)
      end
      init_io
      send_open :ev_send_open
      retry_thread if options[:auto_retry] == true
      unless options[:no_blocking] == true
        unless wait_for_state(options[:waitfor], options[:timeout])
          raise "timeout after #{options[:timeout]}s waiting for state #{options[:waitfor]}, state is #{@state}"
        end
        log_info "#{self} started"
      end
      true
    rescue => e
      @last_error = e
      Log.error "#{e}"
      stop
      raise if options && options[:raise]
      false
    end
        
    # Block until @state is state or timeout seconds pass. A nil timeout waits forever.
    # Returns true if the state was reached, false on timeout.
    def wait_for_state(state, timeout=nil)
      deadline = Time.now + timeout if timeout
      @mutex.synchronize do
        until @state == state
          if deadline
            remaining = deadline - Time.now
            return false if remaining <= 0
            @state_cv.wait(@mutex, remaining)
          else
            @state_cv.wait(@mutex)
          end
        end
        true
      end
    end

    def stop
      # Wake any caller waiting in send_message on a full queue.
      @out.close if defined?(@out) and @out
      @socket.close  if defined?(@socket) and not @socket.closed?
      clean
      @open=nil
      new_state :Idle, "Disable"
    end

    # Stops the session if needed and ends the event thread for good.
    # Call it when the Neighbor is no longer used. stop alone keeps the
    # thread, so start can be called again after stop, but not after close.
    def close
      retry_thread :stop
      stop if @state != :Idle or (@socket and not @socket.closed?)
      @eventQ.close
      @event_thread.join unless Thread.current == @event_thread
      nil
    end

    def closed?
      @eventQ.closed?
    end

    define_method(:in) do
      @in.thread
    end
    define_method(:out) do
      @out.thread
    end

    attr_reader :as4byte, :session_info, :socket
    
    def as4byte?
      @session_info.as4byte?
    end

    def send_message(m)
      raise if m.nil?
      unless @out
        txt = "Could not Send#{m.class.to_s.split('::')[-1]}: session not started, call start first"
        log_warn txt
        raise txt
      end
      unless m.is_a?(String)
        log_info "Send#{m.class.to_s.split('::')[-1]}"
        log_debug "Send #{m.is_a?(Update) ? m.to_s : m }\n"
      end
      if m.is_a?(Update)
         send_update m
      else
        @out.enq m
      end
    rescue ClosedQueueError
      txt = "Could not Send#{m.class.to_s.split('::')[-1]}: session closed"
      log_warn txt
      raise SessionClosed, txt
    end
    
    def init_io
      @in = BGP::IO::Input.new(@socket, holdtime, self)
      @out = BGP::IO::Output.new(@socket, @holdtime, self)
      @out.max = send_queue_limit
      new_state(:Active, "Open Socket")
      [@in, @out].each { |io| 
        io.start 
        @threads.add io.thread
      }
    end
    
    def update(*args)
      @eventQ.enq(args)
    rescue ClosedQueueError
      # close was called; nothing handles events any more.
    end
    
    def new_state(state, txt='')
      log_info "#{txt} old state #{@state} new state #{state}"
      @mutex.synchronize do
        @state = state
        @state_cv.broadcast
      end
    end
    
    def send_update(u)
      # No session info yet means the 2-octet default encoding.
      if auto_as4? and u.path_attribute and not (@session_info and @session_info.as4byte?)
        # A copy, so the caller's Update keeps its attributes.
        u = u.dup
        u.path_attribute = u.path_attribute.as4_fixup
      end
      @out.enq u.encode(@session_info)
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
      @session_info.policy = policy
      
      @rmt_version  = peer_open.version
      @rmt_as       = peer_open.local_as
      @rmt_bgp_id   = peer_open.bgp_id
      @out.holdtime = @in.holdtime = peer_open.holdtime if @holdtime > peer_open.holdtime
      
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
          begin
            loop do
              sleep(h)
              send_message(BGP::Keepalive.new)
            end
          rescue SessionClosed
            # stop closed the output queue between its close and the kill
            # that clean does. The session is going away: stop sending.
          end
        end
        @threads.add(@keepalive_thread)
      end
    end
    
    def rcv_notification(m)
      log_info "#{m}"
      changed and notify_observers(m)
      stop
    end
    
    def rcv_route_refresh(m)
    end

    # The :strict policy found a malformed attribute (RFC 7606).
    def rcv_malformed(e)
      log_warn "RecvUpdate malformed: #{e.message}"
      changed and notify_observers(e)
      if e.action == :session_reset and e.finding.notification
        # Written here, not queued: stop drops what the writer still has
        # queued. IO#write does not interleave with the writer thread's.
        begin
          log_info "SendNotification #{e.finding.notification}"
          @socket.write e.finding.notification.encode
        rescue IOError, SystemCallError
        end
        stop
      end
    end
    
    def rcv_update(m)
    end
    
    def to_s
      "version: #{version}, id: #{@id}, as: #{@my_as}, holdtime: #{@holdtime}, peer addr: #{@remote_addr}, local addr: #{@local_addr}"
    end
    
  end

end

load "../../test/unit/neighbor/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
