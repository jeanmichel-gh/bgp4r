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
# CAPABILITIES below names every capability class, so they have to be
# loaded by the time this file is. The dependency was always here, in the
# body of capability, and was met only because a caller had required
# bgp4r.rb first.
require 'bgp/optional_parameters/capabilities'

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
    
    # Every capability bgp4r implements, under the names a script or a lab
    # topology can ask for. A new capability goes in here, not in a case
    # inside a method: the names used to live in two of them and in
    # lab/speaker.rb, and all three fell behind the library. By the time
    # this table replaced them, capability 9 (RFC 9234 Role), capability 70
    # (RFC 7313 Enhanced Route Refresh), ADD-PATH, ORF and Dynamic
    # Capability could not be named at all, though bgp4r builds and parses
    # each of them.
    #
    # The duplicated values are the spellings that already worked, kept so
    # no caller breaks. Each class takes whatever arguments follow the
    # name, so capability(:mbgp, :ipv4, :unicast) and capability(:role,
    # :customer) read the same way, and nothing here validates: a Role or
    # an ORF type no RFC defines still goes on the wire.
    CAPABILITIES = {
      :route_refresh          => OPT_PARM::CAP::Route_refresh,
      :rr                     => OPT_PARM::CAP::Route_refresh,
      :enhanced_route_refresh => OPT_PARM::CAP::Enhanced_route_refresh,
      :mbgp                   => OPT_PARM::CAP::Mbgp,
      :as4                    => OPT_PARM::CAP::As4,
      :as4_byte               => OPT_PARM::CAP::As4,
      :as4byte                => OPT_PARM::CAP::As4,
      :'4byte_as'             => OPT_PARM::CAP::As4,
      :four_byte_as           => OPT_PARM::CAP::As4,
      :four_octet_as          => OPT_PARM::CAP::As4,
      :graceful_restart       => OPT_PARM::CAP::Graceful_restart,
      :gr                     => OPT_PARM::CAP::Graceful_restart,
      :extended_nexthop       => OPT_PARM::CAP::Extended_nexthop,
      :extended_next_hop      => OPT_PARM::CAP::Extended_nexthop,
      :add_path               => OPT_PARM::CAP::Add_path,
      :role                   => OPT_PARM::CAP::Role,
      :orf                    => OPT_PARM::CAP::Orf,
      :dynamic                => OPT_PARM::CAP::Dynamic,
    }.freeze

    # Add a capability to the OPEN this neighbor sends. Three ways:
    #
    #   neighbor.capability :route_refresh
    #   neighbor.capability :mbgp, :ipv6, :unicast
    #   neighbor.capability :mbgp_ipv6_unicast
    #   neighbor.capability :role, :customer
    #   neighbor.capability BGP::OPT_PARM::CAP::Role.new(:customer)
    #
    # A String name works too, since a lab topology reads its names out of
    # YAML. CAPABILITIES has the names.
    def capability(*args)
      @opt_parms << if args[0].is_a?(Symbol) or args[0].is_a?(String)
        build_capability(args[0], args[1..-1])
      elsif args[0].is_a?(OPT_PARM::Capability)
        args[0]
      else
        raise ArgumentError, "Invalid argument"
      end
    end
    alias :add_cap :capability

    # A name no capability answers to. An ArgumentError, so a caller that
    # rescues ArgumentError still catches it, but a class of its own, so
    # method_missing can tell it from a capability class refusing the
    # arguments it was given: capability_role with no Role to send is a
    # missing argument, not a missing method.
    class UnknownCapability < ArgumentError ; end

    # One capability from a name and the arguments that follow it. Shared by
    # capability, by the capability_<name> form method_missing takes, and by
    # a lab topology, so all three know the same names.
    def build_capability(name, args=[])
      name = name.to_s
      klass = CAPABILITIES[name.to_sym]
      if klass == OPT_PARM::CAP::As4
        # The AS is ours, so a caller never passes it.
        OPT_PARM::CAP::As4.new(@my_as)
      elsif klass == OPT_PARM::CAP::Extended_nexthop and args.empty?
        # RFC 8950 section 4. With no family, IPv4 unicast with IPv6 next hops.
        OPT_PARM::CAP::Extended_nexthop.new(1, 1, 2)
      elsif klass
        klass.new(*args)
      elsif name =~ /\Ambgp_(.+)\z/
        mbgp_capability($1)
      else
        # One name per capability rather than all of them, so the aliases
        # do not crowd out the list.
        names = CAPABILITIES.group_by { |_, kl| kl }.collect { |_, pairs| pairs.first.first }
        raise UnknownCapability,
              "no capability is named #{name.inspect}. The names are " +
              "#{names.join(', ')}, and mbgp_<afi>_<safi>.", caller
      end
    end
    private :build_capability

    # mbgp_ipv6_unicast and the rest: the address family is in the name, and
    # Mbgp's own method_missing reads it through IANA.afi? and IANA.safi?.
    # The respond_to? test keeps a name like mbgp_factory out of send, which
    # the method_missing this replaced did not.
    def mbgp_capability(family)
      raise UnknownCapability, "no address family is named #{family.inspect}", caller if
        OPT_PARM::CAP::Mbgp.respond_to?(family)
      OPT_PARM::CAP::Mbgp.send(family)
    rescue NoMethodError
      raise UnknownCapability, "no address family is named #{family.inspect}", caller
    end
    private :mbgp_capability

    def method_missing(name, *args, &block)
      if name.to_s =~ /^(capability|add_capability)_(.+)$/
        # The name itself is the capability, so it goes through the one
        # table too. It used to go through a second, shorter list of four
        # regular expressions, matched as substrings, and
        # capability_enhanced_route_refresh contains "route_refresh": it
        # built capability 2 where 70 was asked for, 02020200 instead of
        # 02024600, and said nothing. A name that matches no capability
        # raises NoMethodError now, as it always did for a name the list
        # did not hold.
        begin
          @opt_parms << build_capability($2, args)
        rescue UnknownCapability
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
    
    # What the peer said in its OPEN (RFC 4271 section 4.2), or nil before
    # one arrived: its Autonomous System number, its BGP Identifier and its
    # Version. They are what names this peer to anything downstream, such as
    # a BGP::Rib::Table, which needs the AS to tell an internal peer from an
    # external one and the Identifier for the last tie break of the decision
    # process (RFC 4271 section 9.1.2.2 f). rcv_open sets them and nothing
    # clears them, so they still read after the session goes down.
    attr_reader :rmt_as, :rmt_bgp_id, :rmt_version

    # Our own side of the session, as configured: the local Autonomous
    # System number and the two addresses. They had no readers, so a script
    # that was handed a Neighbor could not ask what it was. my_as is the
    # other half of what names a peer, since a peer in our own AS is an
    # internal one (RFC 4271 section 1.1).
    attr_reader :my_as, :remote_addr, :local_addr

    # Runs block on every state change, with the new state and the old one.
    #
    #   neighbor.on_state_change { |now, was| puts "#{was} -> #{now}" }
    #
    # This is how something outside the FSM learns a session dropped. The
    # message observers cannot be used for it: :ev_conn_reset calls stop
    # without notifying anyone, and stop is also called directly, so the
    # only thing every path has in common is the state going to :Idle.
    #
    # The block runs on whichever thread changed the state, which for a
    # reset or a holdtime expiry is the event dispatch thread. Do not block
    # it: that thread handles the session. An exception from the block is
    # logged and swallowed, because a listener must not be able to kill the
    # FSM.
    def on_state_change(&block)
      (@state_listeners ||= []) << block
      self
    end

    def new_state(state, txt='')
      log_info "#{txt} old state #{@state} new state #{state}"
      was = nil
      @mutex.synchronize do
        was = @state
        @state = state
        @state_cv.broadcast
      end
      # Outside the mutex: a listener that reads the state, or waits on it,
      # would deadlock on a Mutex that is not reentrant.
      notify_state_change(state, was) unless was == state
    end

    def notify_state_change(now, was)
      return unless defined?(@state_listeners) and @state_listeners
      @state_listeners.each do |block|
        begin
          block.call(now, was)
        rescue => e
          log_warn "on_state_change listener raised #{e.class}: #{e.message}"
        end
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
