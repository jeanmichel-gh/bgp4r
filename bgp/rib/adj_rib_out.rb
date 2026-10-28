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

require 'bgp/rib/route'

module BGP
  module Rib

    # What we have advertised to one peer (RFC 4271 section 3.2), keyed the
    # way the Adj-RIB-In is, by prefix and add-path Path Identifier.
    #
    #   out = AdjRibOut.new(peer)
    #   out.advertise('10.0.0.0/8', attributes)   # => :new, :changed or :same
    #   out.withdraw('10.0.0.0/8')                # => the attributes, or nil
    #
    # It records what went out so the sender can work out what to send next:
    # :same means the peer already has exactly these attributes and the
    # UPDATE can be left unsent, and withdraw answers nil for a prefix the
    # peer never had, so no withdrawal is sent for it either. Suppressing
    # those is the whole reason to keep this.
    #
    # Attributes are compared by their encoded octets, not by object
    # identity, because Export builds a new Path_attribute every time it
    # runs. The 4-octet AS form is used for the comparison so that the
    # answer does not depend on what a session negotiated.
    #
    # Like AdjRibIn, this holds data and takes no lock. Table owns the lock.
    class AdjRibOut
      attr_reader :peer

      def initialize(peer)
        @peer = peer
        @sent = {}   # prefix => { path_id => [path_attribute, encoded] }
        @size = 0
      end

      # Records that path_attribute was advertised for prefix. Returns :new
      # when the peer did not have this prefix, :changed when it had it with
      # other attributes, and :same when nothing about it changed.
      def advertise(prefix, path_attribute, path_id = nil)
        prefix = Route.normalize(prefix)
        id = path_id.nil? ? nil : Integer(path_id)
        bytes = path_attribute.encode(true)
        paths = (@sent[prefix] ||= {})
        was = paths[id]
        paths[id] = [path_attribute, bytes]
        if was.nil?
          @size += 1
          :new
        elsif was[1] == bytes
          :same
        else
          :changed
        end
      end

      # Forgets what we sent for prefix. Returns the attributes we had sent,
      # or nil when the peer never had it, in which case there is nothing to
      # withdraw.
      def withdraw(prefix, path_id = nil)
        prefix = Route.normalize(prefix)
        paths = @sent[prefix] or return nil
        gone = paths.delete(path_id.nil? ? nil : Integer(path_id))
        @sent.delete(prefix) if paths.empty?
        return nil unless gone
        @size -= 1
        gone[0]
      end

      # The attributes we last sent for prefix, or nil.
      def [](prefix, path_id = nil)
        paths = @sent[Route.normalize(prefix)]
        entry = paths && paths[path_id.nil? ? nil : Integer(path_id)]
        entry && entry[0]
      end

      # True when the peer already has exactly these attributes for prefix,
      # so the UPDATE need not be sent.
      def current?(prefix, path_attribute, path_id = nil)
        paths = @sent[Route.normalize(prefix)]
        entry = paths && paths[path_id.nil? ? nil : Integer(path_id)]
        !entry.nil? && entry[1] == path_attribute.encode(true)
      end

      # Every Path Identifier we have sent for prefix.
      def path_ids(prefix)
        (@sent[Route.normalize(prefix)] || {}).keys
      end

      # Forgets everything, as when the session goes down. Returns the
      # prefixes that were in it.
      def flush
        gone = prefixes
        @sent.clear
        @size = 0
        gone
      end

      def prefixes ; @sent.keys ; end
      def size ; @size ; end
      def empty? ; @size == 0 ; end

      # Yields each prefix, Path Identifier and the attributes sent for it.
      def each
        @sent.each do |prefix, paths|
          paths.each { |id, entry| yield prefix, id, entry[0] }
        end
      end

      def to_s ; "Adj-RIB-Out for #{@peer}: #{@size} route#{'s' unless @size == 1}" ; end
    end

  end
end
