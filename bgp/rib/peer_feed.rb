#--
# Copyright 2026 Jean-Michel Esnault.
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

require 'bgp/rib/peer_adapter'

module BGP
  module Rib

    # Carries what the sessions received into one table, on one thread.
    #
    # A PeerAdapter per neighbour translates on the neighbour's own event
    # dispatch thread and puts the result here. One worker thread takes it
    # off the queue and applies it. The table has its own lock, so this
    # thread is not what makes it safe; it is what keeps the decision
    # process off the thread that runs the session. A BGP speaker that
    # stalls its event thread stops answering KEEPALIVEs and loses the
    # session to a holdtime expiry (RFC 4271 section 4.4), and deciding a
    # full table is not work to do there.
    #
    #   rib = BGP::Rib.new(local_as: 65001, router_id: '1.1.1.1')
    #   rib.attach(neighbor)
    #   neighbor.start
    #   rib.drain              # wait for what has arrived to be applied
    #   rib.best('10.0.0.0/8')
    #
    # Normally reached through Table#attach rather than built directly.
    class PeerFeed

      # How long drain and stop wait, in seconds, when not given a timeout.
      DEFAULT_TIMEOUT = 5

      attr_reader :table

      def initialize(table)
        @table = table
        @adapters = {}        # neighbor => PeerAdapter
        @queue = Queue.new
        @lock = Mutex.new
        @worker = nil
        @errors = []
      end

      # Feeds table from neighbor. Returns the PeerAdapter, the same one on
      # a second call for the same neighbor. The worker starts on the first
      # attach, so a table nobody attached to costs no thread.
      def attach(neighbor)
        @lock.synchronize do
          @adapters[neighbor] ||= begin
            start_worker
            adapter = PeerAdapter.new(neighbor, self)
            # Router mode, if it is on, watches this session too.
            @table.router&.watch(adapter)
            adapter
          end
        end
      end

      # Stops feeding from neighbor and removes what it had sent, the way a
      # session going down would (RFC 4271 section 9.1.2). Returns the
      # adapter, or nil when that neighbor was not attached.
      def detach(neighbor)
        adapter = @lock.synchronize { @adapters.delete(neighbor) }
        return nil unless adapter
        adapter.detach
        peer = adapter.peer
        self << [:peer_down, peer] if peer
        adapter
      end

      def adapters ; @lock.synchronize { @adapters.values } ; end
      def neighbors ; @lock.synchronize { @adapters.keys } ; end

      # Queues one work item. Called from the neighbours' threads.
      def <<(work)
        @queue << work
        self
      end

      def pending ; @queue.size ; end

      # Waits until everything queued before this call has been applied.
      # Returns true, or false if timeout seconds passed first. Tests need
      # it, and so does anything that reads the table right after feeding
      # it, because the worker runs behind.
      def drain(timeout = DEFAULT_TIMEOUT)
        return true unless @lock.synchronize { @worker }
        done = Queue.new
        self << [:sync, done]
        !done.pop(:timeout => timeout).nil?
      end

      # Anything the worker rescued, so a test or a console can see what a
      # malformed UPDATE did. The worker never dies on one.
      def errors ; @lock.synchronize { @errors.dup } ; end

      # Detaches every neighbor and stops the worker. The table keeps what
      # it holds; detach is what removes a peer's routes.
      def stop(timeout = DEFAULT_TIMEOUT)
        neighbors.each { |n| @lock.synchronize { @adapters.delete(n) }&.detach }
        worker = @lock.synchronize { w = @worker ; @worker = nil ; w }
        return self unless worker
        @queue << nil
        worker.join(timeout) or worker.kill
        self
      end

      def running? ; !!@lock.synchronize { @worker } ; end

      private

      # Called holding @lock.
      def start_worker
        return if @worker
        @worker = Thread.new { work_loop }
        @worker['name'] = 'BGP RIB feed'
        @worker
      end

      def work_loop
        loop do
          work = @queue.deq
          break if work.nil?       # stop
          begin
            apply(work)
          rescue => e
            # One bad UPDATE must not take the table's only worker with it.
            @lock.synchronize { @errors << e }
            Log.error "#{self.class}: #{e.class}: #{e.message}"
          end
        end
      end

      def apply(work)
        case work.first
        when :ops
          work[1].each do |op|
            case op.first
            when :announce then @table.announce(op[1])
            when :withdraw then @table.withdraw(op[1], op[2], op[3])
            else raise ArgumentError, "unknown table operation #{op.first.inspect}"
            end
          end
        when :peer_down
          @table.peer_down(work[1])
        when :advertise
          @table.router&.run_changes(work[1])
        when :session_up
          @table.router&.session_up(work[1])
        when :session_down
          @table.router&.session_down(work[1])
        when :sync
          work[1] << true
        else
          raise ArgumentError, "unknown work item #{work.first.inspect}"
        end
      end
    end

  end
end
