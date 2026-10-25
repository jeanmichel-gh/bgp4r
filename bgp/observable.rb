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
  # A small Observable, with the same methods as Ruby's 'observer' library.
  #
  # Ruby 3.4 moved 'observer' out of the default gems, so requiring it
  # warns on 3.3 and fails under Bundler on 3.4 and later. bgp4r keeps
  # no runtime gem dependencies, so it carries its own copy instead.
  # Scripts that call add_observer on a Neighbor keep working.
  module Observable

    # Register observer. Its func method is called on each notification.
    def add_observer(observer, func=:update)
      unless observer.respond_to?(func)
        raise NoMethodError, "observer does not respond to `#{func}'"
      end
      @observer_peers ||= {}
      @observer_peers[observer] = func
    end

    def delete_observer(observer)
      @observer_peers.delete(observer) if defined?(@observer_peers) && @observer_peers
    end

    def delete_observers
      @observer_peers.clear if defined?(@observer_peers) && @observer_peers
    end

    def count_observers
      defined?(@observer_peers) && @observer_peers ? @observer_peers.size : 0
    end

    def changed(state=true)
      @observer_state = state
    end

    def changed?
      defined?(@observer_state) && @observer_state ? true : false
    end

    # Call every observer with args, but only after changed was called.
    # Resets the changed state, like the standard library.
    def notify_observers(*args)
      return unless changed?
      if defined?(@observer_peers) && @observer_peers
        # Iterate over a copy, so an observer may add or delete observers.
        @observer_peers.dup.each { |observer, func| observer.__send__(func, *args) }
      end
      @observer_state = false
    end

  end
end
