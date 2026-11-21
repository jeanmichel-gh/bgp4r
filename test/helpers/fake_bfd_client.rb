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


module BGP
  module TestHelpers

    # BFD::Client from bfd4r, as much of it as bgp/daemon/bfd.rb uses,
    # with no bfdd4r behind it: `want`, `drop`, `state`, `poll`, `ios`
    # and `close`. A test queues the events `poll` answers with `push`,
    # and reads what was asked of bfdd4r in `calls`.
    #
    # **The events have BFD::Client::Event's shape and its two
    # predicates, copied rather than required**, so the unit suite runs
    # where bfd4r is not on the load path, as in the Docker test image.
    # test/functional/bfd_test.rb runs the real client against a real
    # bfdd4r, which is what holds this copy to the original.
    class FakeBfdClient
      Event = Struct.new(:type, :interface, :peer, :state, :from, :diag, :message, keyword_init: true) do
        def up? = type == :state && state == :up
        def failure? = type == :state && from == :up && state == :down
      end

      attr_reader :calls, :closed

      def initialize
        @calls = []
        @queue = []
        @states = {}
        @lock = Mutex.new
        @closed = nil
      end

      def want(interface:, peer:, local:, **timers)
        @lock.synchronize { @calls << [:want, interface, peer, local] }
        self
      end

      def drop(interface:, peer:)
        @lock.synchronize { @calls << [:drop, interface, peer] ; @states.delete([interface, peer]) }
        self
      end

      def state(interface:, peer:) = @lock.synchronize { @states[[interface, peer]] }

      def ios = []

      # Queues one event; a :state event also sets the state `state`
      # answers, as the real client's `tell` does.
      def push(**fields)
        e = Event.new(**fields)
        @lock.synchronize do
          @states[[e.interface, e.peer]] = e.state if e.type == :state
          @queue << e
        end
        e
      end

      def poll(_now) = @lock.synchronize { q = @queue ; @queue = [] ; q }

      def close(release: false)
        @lock.synchronize { @closed = { :release => release } }
        nil
      end
    end

  end
end
