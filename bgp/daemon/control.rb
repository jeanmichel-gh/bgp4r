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

require 'bgp/daemon/speaker'

module BGP
  module Daemon

    # What `bgp4rd` can be told to do: the `peer.` and `route.` methods of
    # docs/daemon.md's control API.
    #
    # **It is a file of its own and not more methods on `Views`, and the
    # reason is that file's own first sentence**: Views answers "what
    # bgp4rd answers, as plain data", and "nothing here validates and
    # nothing here decides". A method that tears a session down in the
    # middle of that would make the sentence false, and the split is what
    # lets a reader tell at a glance which half of the API a method is in.
    # docs/daemon.md's own reason for separate method names is the same
    # one one level up: "a read-only client is a list of methods and not a
    # trust decision".
    #
    # Every method here answers plain data, as a view does, so the socket
    # does the same thing with either.
    #
    # **Nothing here validates what goes on the wire**, which is
    # Conventions and is why the library exists: `route.originate` will
    # originate a prefix with an ORIGIN no RFC defines and an AS_PATH
    # nobody would send, and `peer.refresh` will send a ROUTE-REFRESH to a
    # peer that never advertised capability 2. What each method does
    # refuse is an input it cannot act on at all: an address nobody
    # configured, a session that is not up, a parameter name it does not
    # read. A body key that is silently ignored is a wrong answer and not
    # a missing one, which is the rule `Speaker#export_options` already
    # applies to a node file.
    class Control

      # The body keys of `route.originate`. They are the node file's
      # `originate:` keys, plus the two selectors, so the runtime
      # vocabulary is the configuration vocabulary and lab/README.md is
      # already the reference for both.
      ORIGINATE_KEYS = %w[prefix prefixes origin as_path med local_pref
                          communities extended_communities large_communities path_id].freeze

      # `route.withdraw` names what to take back and nothing else: the
      # attributes are not part of the key a route is held under, which is
      # the prefix and the Path Identifier (RFC 7911 section 3).
      WITHDRAW_KEYS = %w[prefix prefixes path_id].freeze

      # `peer.refresh`: RFC 2918 section 3's one <AFI, SAFI>, and RFC 7313
      # section 3.2's Message Subtype.
      REFRESH_KEYS = %w[peer afi safi subtype].freeze

      PEER_KEYS = %w[peer].freeze

      attr_reader :speaker

      def initialize(speaker)
        @speaker = speaker
      end

      # Resets one session. The configuration is untouched, so an active
      # peer dials again after its retry interval and a passive one waits
      # to be dialled: that is the difference from `peer.stop`.
      #
      # It sends no NOTIFICATION, which is a gap recorded rather than a
      # choice; `Peer#stop` has the mechanism.
      def peer_clear(params = {})
        peer = peer_of(params, PEER_KEYS)
        was = peer.state.to_s
        peer.clear
        { :peer => peer.address, :cleared => true, :was => was.downcase,
          :state => peer.state.to_s.downcase, :shutdown => peer.shutdown? }
      end

      # Administratively down: the session ends and does not come back
      # until `peer.start`. Idempotent, so a second one is not an error.
      def peer_stop(params = {})
        peer = peer_of(params, PEER_KEYS)
        was = peer.state.to_s
        peer.admin_stop
        { :peer => peer.address, :was => was.downcase,
          :state => peer.state.to_s.downcase, :shutdown => true }
      end

      # Administratively up again. Idempotent.
      def peer_start(params = {})
        peer = peer_of(params, PEER_KEYS)
        peer.admin_start
        { :peer => peer.address, :state => peer.state.to_s.downcase,
          :shutdown => false, :connect => peer.active? }
      end

      # A ROUTE-REFRESH for one <AFI, SAFI>. RFC 2918 section 3 is the
      # message and RFC 7313 section 3.2 the subtype; `Peer#refresh` has
      # the citations and does the work.
      #
      # `subtype` takes the RFC's numbers or the three names
      # `BGP::Route_refresh` answers to, `normal`, `borr` and `eorr`, and
      # any octet value encodes, so a router can be watched handling one
      # the RFC does not define.
      def peer_refresh(params = {})
        p = strings(params, REFRESH_KEYS)
        peer = peer_of(params, REFRESH_KEYS)
        msg = peer.refresh(integer(p, 'afi', 1), integer(p, 'safi', 1), subtype(p['subtype']))
        { :peer => peer.address, :afi => msg.afi, :safi => msg.safi,
          :subtype => msg.subtype || BGP::Route_refresh::NORMAL,
          :sent => true }
      end

      # Announces prefixes of ours, through `Table#originate`, so they go
      # in the Loc-RIB and out through the export rules rather than
      # straight onto one session.
      #
      # The attributes are built by `Speaker#originate_attribute`, the one
      # the `originate:` blocks of the configuration file go through, so a
      # prefix originated here and one originated at start-up carry the
      # same attributes from the same keys. Two of them are deliberately
      # not settable and that method says why: AS_PATH starts empty
      # because RFC 4271 section 5.1.2 wants it empty toward an internal
      # peer and our AS alone toward an external one, and NEXT_HOP is a
      # placeholder because section 5.1.3 makes it ours on each session.
      def route_originate(params = {})
        p = strings(params, ORIGINATE_KEYS)
        rib = table!
        prefixes = prefixes_of(p)
        id = p['path_id'] && Integer(p['path_id'])
        pa = @speaker.originate_attribute(p)
        changes = rib.synchronize do
          prefixes.flat_map { |prefix| rib.originate(prefix, :path_attribute => pa, :path_id => id) }
        end
        { :originated => prefixes, :total => prefixes.size,
          :changes => changes.size, :rib => rib.loc_rib.size }
      end

      # Takes prefixes of ours back, through `Table#withdraw(rib
      # .local_peer, prefix)`.
      #
      # `not_held` is the prefixes this speaker was not originating, and
      # it is answered rather than refused: withdrawing a route nobody has
      # is not an error (RFC 4271 section 3.1 and `AdjRibIn#withdraw` both
      # treat it as nothing to do), and a caller walking a list wants to
      # know which ones did nothing.
      #
      # **Membership is read before the withdrawal and not inferred from
      # what it returned**, because an empty change list is ambiguous: a
      # prefix another peer also advertises can be withdrawn by us and
      # leave the Loc-RIB unchanged, since that peer's route then wins.
      def route_withdraw(params = {})
        p = strings(params, WITHDRAW_KEYS)
        rib = table!
        prefixes = prefixes_of(p)
        id = p['path_id'] && Integer(p['path_id'])
        withdrawn, missing, changes = [], [], 0
        rib.synchronize do
          ours = rib.adj_rib_in(rib.local_peer)
          prefixes.each do |prefix|
            if ours[prefix, id].nil?
              missing << prefix
            else
              withdrawn << prefix
              changes += rib.withdraw(rib.local_peer, prefix, id).size
            end
          end
        end
        { :withdrawn => withdrawn, :not_held => missing, :total => withdrawn.size,
          :changes => changes, :rib => rib.loc_rib.size }
      end

      private

      # The Peer one of these methods acts on, refused by name when
      # nobody configured it. `Speaker#peer!` does the refusal, so a view
      # and a control method answer the same message.
      def peer_of(params, known)
        p = strings(params, known)
        address = p['peer']
        raise ArgumentError, 'peer is required: the address of one neighbor' if address.nil?
        @speaker.peer!(address)
      end

      # The table, or the reason there is none. `rib: false` is a
      # deliberate configuration, so this names it rather than answering
      # as though the origination worked.
      def table!
        @speaker.rib or
          raise ArgumentError,
                'this bgp4rd has no table, so it originates nothing: ' \
                'the configuration says rib: false'
      end

      # `prefix` or `prefixes`, as a list. One of them is required: a
      # method that acted on every prefix when told none would be the
      # worst possible default for a withdrawal.
      def prefixes_of(p)
        list = Array(p['prefixes']) + (p['prefix'] ? [p['prefix']] : [])
        list = list.collect { |x| x.to_s }
        raise ArgumentError, 'prefix or prefixes is required' if list.empty?
        list
      end

      # The parameters with String keys, refusing a name this method does
      # not read. A socket hands Strings and a test hands Symbols, so both
      # work, and `:med` and `'med'` are one key.
      def strings(params, known)
        h = {}
        (params || {}).each { |k, v| h[k.to_s] = v }
        unknown = h.keys - known
        unless unknown.empty?
          raise ArgumentError,
                "unknown parameter(s) #{unknown.join(', ')}: this takes #{known.join(', ')}"
        end
        h
      end

      def integer(p, name, default)
        v = p[name]
        return default if v.nil?
        Integer(v)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{name} must be an integer, got #{v.inspect}"
      end

      # RFC 7313 section 3.2's Message Subtype, as a number or as one of
      # the three names `Route_refresh#subtype=` answers to. nil leaves it
      # to `Route_refresh#encode`, which defaults it to NORMAL.
      def subtype(v)
        return nil if v.nil?
        return v.to_sym if v.is_a?(String) && !v.match?(/\A\d+\z/)
        return v if v.is_a?(Symbol)
        Integer(v)
      rescue ArgumentError, TypeError
        raise ArgumentError, "subtype must be a number or one of normal, borr, eorr, got #{v.inspect}"
      end

    end

  end
end
