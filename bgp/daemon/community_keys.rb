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

# The three community keys of an announce block, read in one place.
#
# They lived in `bgp/daemon/speaker.rb` until `bgp/gen` needed them too.
# A generator is pure and must not load a session loop, so the module
# moved to a file of its own that needs only the attribute classes. The
# constant path is unchanged, so nothing that names it moved.

require 'bgp4r'

module BGP
  module Daemon
    # The community keys a node file, a set line and an action body all
    # share, read and written in one place.
    module CommunityKeys
      module_function

      # The three community keys of an announce:, originate: or action
      # block, as path attributes. Each is a list of strings, so a node
      # file, a set line and a JSON body all carry them the same way:
      #
      #   communities:          ['65000:1', 'no_export']
      #   extended_communities: ['route_target:65000:7', 'route_origin:10.0.0.1:3']
      #   large_communities:    ['65000:1:1']
      #
      # An extended community is its to_hash key, then its values, joined
      # by colons: `{:route_target=>[65000, 7]}` is
      # `route_target:65000:7`. That is the library's own vocabulary
      # spelled flat, so every kind Extended_communities builds from a
      # hash is reachable with no table here, and it is a string because
      # a configuration set line cannot hold a list of mappings
      # (bgp/daemon/config.rb). A value that reads as an integer is one.
      def community_attributes(a)
        out = []
        out << BGP::Communities.new(Array(a['communities']).join(' ')) if a['communities']
        if a['extended_communities']
          list = Array(a['extended_communities']).collect { |t| extended_community_hash(t) }
          out << BGP::Extended_communities.new(:extended_communities => list)
        end
        out << BGP::Large_communities.new(Array(a['large_communities']).join(' ')) if a['large_communities']
        out
      end

      # 'route_target:65000:7' => {:route_target=>[65000, 7]}
      def extended_community_hash(text)
        key, *vals = text.to_s.split(':')
        raise ArgumentError, "an extended community is KIND:VALUE..., as route_target:65000:7, not #{text.inspect}" if
          key.to_s.empty? || vals.empty?
        { key.to_sym => vals.collect { |v| v =~ /\A\d+\z/ ? v.to_i : v } }
      end

      # {:route_target=>[65000, 7]} => 'route_target:65000:7', the inverse.
      def extended_community_text(h)
        h.collect { |k, v| ([k] + Array(v)).join(':') }.join(' ')
      end
    end
  end
end
