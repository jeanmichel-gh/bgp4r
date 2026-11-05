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

      # The three sends by hand. `peer` picks one session; with none they
      # go to every session that is up, which is what `bgp4r-sim` does.
      SPECIMEN_KEYS = %w[peer name prefix prefixes next_hop].freeze
      FAULT_KEYS    = %w[peer case prefix prefixes next_hop].freeze
      REPLAY_KEYS   = %w[peer hex].freeze

      # The keys of the configuration's `mark`, which are the three
      # community keys an announce block takes, so the text is the same.
      MARK_KEYS = %w[communities extended_communities large_communities].freeze

      # The `mark` of a configuration, as a Hash with String keys, empty
      # when there is none. A key it does not read, or a community it
      # cannot parse, raises ArgumentError naming it, so a typo is caught
      # when the file is read and not on the first route made by hand.
      #
      # **What it is for**: a route made by hand, at the prompt or
      # through `route.originate`, carries these communities beside its
      # own, so a router that receives it can act on it. Nothing in the
      # IANA registries means "made by hand", so the value is the
      # operator's convention. An `originate:` block in the file does not
      # carry it, because nobody typed that route. docs/console.md
      # section 10 has the decision.
      def self.mark(config)
        m = config && config['mark']
        return {} if m.nil?
        raise ArgumentError, "mark takes #{MARK_KEYS.join(', ')}, got #{m.inspect}" unless m.is_a?(Hash)
        m = m.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
        unknown = m.keys - MARK_KEYS
        unless unknown.empty?
          raise ArgumentError, "mark: unknown key(s) #{unknown.join(', ')}: it takes #{MARK_KEYS.join(', ')}"
        end
        CommunityKeys.community_attributes(m)
        m
      rescue ArgumentError => e
        raise if e.message.start_with?('mark')
        raise ArgumentError, "mark: #{e.message}"
      end

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
      #
      # **The configuration's `mark` is added here**, to each of the three
      # community lists, so a route made through `bgp4r-cli` and one made
      # at the prompt carry it alike. `marked` in the answer says whether
      # it was. The mark is read from the running configuration on each
      # call, so a commit that changes it applies to the next route.
      def route_originate(params = {})
        p = strings(params, ORIGINATE_KEYS)
        rib = table!
        prefixes = prefixes_of(p)
        id = p['path_id'] && Integer(p['path_id'])
        mark = Control.mark(@speaker.config)
        mark.each { |k, v| p[k] = Array(p[k]) + Array(v) }
        pa = @speaker.originate_attribute(p)
        changes = rib.synchronize do
          prefixes.flat_map { |prefix| rib.originate(prefix, :path_attribute => pa, :path_id => id) }
        end
        { :originated => prefixes, :total => prefixes.size,
          :changes => changes.size, :rib => rib.loc_rib.size, :marked => !mark.empty? }
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

      # ---- sending by hand ----------------------------------------------
      #
      # Four methods that put a message on a session behind the
      # Adj-RIB-Out's back, and one that puts the peer back in line.
      # **None of them writes the Adj-RIB-Out**; each records what it
      # touched in `Speaker#hand`, which `show.adj_out` answers under
      # `hand` and `show.peers` counts. bgp/daemon/hand.rb has why, and
      # docs/console.md section 10 the decision.

      # A `BGP::Specimen` by name, a valid UPDATE, in the envelope
      # `bgp4r-sim`'s `specimen` key builds: our AS toward an external
      # peer and an empty AS_PATH toward an internal one, and a NEXT_HOP
      # with `prefixes` only. **The configuration's `mark` is added**,
      # into the specimen's own community attribute when it has one,
      # because this is a valid route made by hand.
      def peer_specimen(params = {})
        p = strings(params, SPECIMEN_KEYS)
        name = p['name'].to_s
        unless BGP::Specimen.names.include?(name.to_sym)
          raise ArgumentError, "name: #{name.empty? ? 'is required' : "unknown specimen #{name.inspect}"}; " \
                               "the catalog has #{BGP::Specimen.names.join(', ')}"
        end
        prefixes = optional_prefixes(p)
        mark = Control.mark(@speaker.config)
        sent = targets(p).collect do |peer|
          msg = BGP::Specimen.update(name.to_sym,
                                     :my_as    => (peer.ebgp? ? @speaker.my_as : nil),
                                     :next_hop => (prefixes.empty? ? nil : p.fetch('next_hop', peer.local_ip)),
                                     :prefixes => prefixes)
          add_mark(msg, mark)
          ship(peer, msg, "specimen #{name}")
        end
        { :specimen => name, :prefixes => prefixes, :marked => !mark.empty?, :sent => sent }
      end

      # One `BGP::Fault::CATALOG` case, the octets `bgp4r-sim` and
      # `lab/fault_matrix.rb` send for the same name. **Never marked**: the
      # message is the thing under test.
      def peer_fault(params = {})
        p = strings(params, FAULT_KEYS)
        name = p['case'].to_s
        unless BGP::Fault.names.include?(name.to_sym)
          raise ArgumentError, "case: #{name.empty? ? 'is required' : "unknown case #{name.inspect}"}; " \
                               "the catalog has #{BGP::Fault.names.join(', ')}"
        end
        prefixes = optional_prefixes(p)
        sent = targets(p).collect do |peer|
          msg = BGP::Fault.update(name.to_sym,
                                  :my_as    => (peer.ebgp? ? @speaker.my_as : nil),
                                  :next_hop => p.fetch('next_hop', peer.local_ip),
                                  :prefixes => prefixes)
          ship(peer, msg, "fault #{name}")
        end
        { :case => name, :prefixes => prefixes, :sent => sent }
      end

      # Octets on the wire, unchanged: nothing parsed, nothing checked.
      # What they touch is read back as a message, so a prefix an UPDATE
      # carries is listed; octets that do not read as a message list the
      # whole peer.
      def peer_replay(params = {})
        p = strings(params, REPLAY_KEYS)
        hex = p['hex'].to_s.gsub(/\s+/, '')
        unless hex =~ /\A(\h\h)+\z/
          raise ArgumentError, "hex: #{p['hex'].inspect} is not a non-empty, even number of hex digits"
        end
        octets = [hex].pack('H*')
        sent = targets(p).collect { |peer| ship(peer, octets, 'replay') }
        { :octets => octets.bytesize, :sent => sent }
      end

      # Puts one peer back in line after sending by hand: for each unicast
      # prefix on its list, the daemon's own answer, which is the route
      # when export advertises one and a withdrawal when it does not.
      # `Rib::Router#resend` does it on the feed's worker thread. With no
      # Router, which is a configuration with no `export:`, every one is a
      # withdrawal, since such a daemon advertises nothing.
      #
      # **A row it cannot answer is kept and named**, under `kept`: an
      # NLRI of a family the daemon holds no table for, and a whole peer
      # row from octets that did not read as a message. Both clear when the
      # session ends, so `clear PEER` is the way to settle them.
      def peer_resend(params = {})
        peer = peer_of(params, PEER_KEYS)
        live!(peer)
        prefixes = @speaker.hand.prefixes(peer.address)
        done = if prefixes.empty?
                 { :resent => [], :withdrawn => [] }
               elsif @speaker.router
                 @speaker.rib.resend(peer.address, prefixes) or
                   raise ArgumentError, "#{peer.address} has no session to resend on"
               else
                 withdraw_by_hand(peer, prefixes)
               end
        @speaker.hand.sent(peer.address, prefixes)
        out = { :peer => peer.address, :resent => done[:resent], :withdrawn => done[:withdrawn],
                :hand => @speaker.hand.count(peer.address) }
        kept = @speaker.hand.rows(peer.address)
        out[:kept] = kept unless kept.empty?
        out
      end

      # One message to one peer, recorded in the hand list, which is the
      # whole of what the three sends share. msg is an object or octets.
      # `bgp4rd --interact`'s `ship` calls this with whatever was typed.
      def ship(peer, msg, verb = 'ship')
        live!(peer)
        peer.send_message(msg)
        rows = @speaker.hand.record(peer.address, msg, verb, peer.session_info)
        { :peer => peer.address, :prefixes => rows.collect { |r| r[:prefix] } }
      rescue NoSession => e
        raise ArgumentError, e.message
      end

      private

      # The sessions a send by hand reaches: the one named, or every one
      # that is up. Refused when there is none, because an answer that
      # sent nothing is the silent wrong answer. A named one that is down
      # is refused by `ship`, which every send ends in.
      def targets(p)
        return [@speaker.peer!(p['peer'])] if p['peer']
        list = @speaker.established_peers
        if list.empty?
          raise ArgumentError, 'no established session: ' \
                               "#{@speaker.peers.collect { |x| "#{x.address} #{x.state.to_s.downcase}" }.join(', ')}"
        end
        list
      end

      def live!(peer)
        return peer if peer.established?
        raise ArgumentError, "#{peer.address} has no established session (state #{peer.state.to_s.downcase})"
      end

      # `prefix` or `prefixes`, as a list, which may be empty: a fault
      # case or a specimen goes without NLRI when none is given.
      def optional_prefixes(p)
        (Array(p['prefixes']) + (p['prefix'] ? [p['prefix']] : [])).collect(&:to_s)
      end

      # The mark's communities, added to the attribute of the same type
      # when the UPDATE has one and appended when it does not, so the
      # UPDATE never carries two of a type.
      def add_mark(msg, mark)
        CommunityKeys.community_attributes(mark).each do |m|
          have = msg.path_attribute[m.type]
          if have
            have.add(*Array(m.communities))
          else
            msg.path_attribute.append(m)
          end
        end
        msg
      end

      # Withdrawals of these prefixes on one session, for a daemon with no
      # Router. `UpdateBuilder` packs them, Withdrawn Routes for IPv4 and
      # MP_UNREACH_NLRI for IPv6, which is how the Router itself sends one.
      def withdraw_by_hand(peer, prefixes)
        items = prefixes.collect { |x| BGP::Rib::UpdateBuilder::Withdraw.new(x) }
        builder = BGP::Rib::UpdateBuilder.new(:session_info => peer.session_info)
        builder.build(:withdraw => items).each { |m| peer.send_message(m) }
        { :resent => [], :withdrawn => prefixes }
      rescue NoSession => e
        raise ArgumentError, e.message
      end

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
