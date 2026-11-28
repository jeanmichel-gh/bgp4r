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

require 'bgp4r'

module BGP
  module Daemon

    # Graceful restart, the Receiving Speaker of RFC 4724 section 4.2:
    # bgp4rd helps a peer that restarts and never restarts gracefully
    # itself. docs/design/bgp-operations.md, section 3; its pull request
    # 3a, and RFC 8538, the N bit and the Hard Reset, 3b.
    #
    # **RFC 8538.** `notification: true` sets our N bit. Once both OPENs
    # carried it, section 4: on a NOTIFICATION other than a Hard Reset,
    # sent or received, "it MUST follow the rules for the Receiving
    # Speaker"; on a hold timer expiry it "MUST follow the rules for the
    # Receiving Speaker" too; a Hard Reset, Cease subcode 9, ends the
    # session as RFC 4271 does (section 3.2). Section 4.1 keeps routes
    # already stale at a consecutive restart: RFC 4724's rule that they
    # "MUST be deleted" holds only "If the "N" bit has not been exchanged
    # with the peer".
    #
    # A neighbor's `graceful_restart` turns it on. bgp4rd then advertises
    # the capability with R clear and no families, which RFC 4724
    # section 4 recommends to a speaker that cannot keep its own
    # forwarding state: it says "its intention of generating the
    # End-of-RIB marker" and "its support for a peer which wishes to
    # perform a graceful restart". It sends End-of-RIB.
    #
    # One per peer. What it does, by section 4.2:
    #
    # - **The session drops** with a TCP failure, from a peer whose last
    #   GR capability listed families: "it MUST retain the routes
    #   received from the peer for all the address families that were
    #   previously received in the Graceful Restart Capability and MUST
    #   mark them as stale". `down` answers those families; the tables
    #   keep them (`peer_down`'s keep). A NOTIFICATION sent or received,
    #   and the hold timer, which sends one, take the RFC 4271 path, as
    #   section 4 says: "the normal BGP procedures MUST be followed when
    #   the TCP session terminates due to the sending or receiving of a
    #   BGP NOTIFICATION message".
    # - **The restart timer**, the peer's own Restart Time: "If the
    #   session does not get re-established within the "Restart Time"
    #   that the peer advertised previously, the Receiving Speaker MUST
    #   delete all the stale routes".
    # - **The session comes back** (`up`): a family whose F bit is clear,
    #   or missing, or no capability at all, "MUST immediately remove all
    #   the stale routes"; the rest wait for "the End-of-RIB marker for
    #   an address family", then "MUST immediately remove any routes from
    #   the peer that are still marked as stale", or for the stale timer,
    #   `stale_time`, section 4.2's "(configurable) timer that imposes
    #   this upper bound".
    #
    # The timers run on an injected clock; a watcher thread, alive only
    # while one runs, checks them once a second (`expire`).
    #
    # **Long-lived graceful restart, RFC 9494**, the helper side, with a
    # neighbor's `long_lived_graceful_restart` (docs/design/bgp-operations.md
    # section 4, pull request 4a). For a family the peer listed with a
    # Long-Lived Stale Time, its routes are not deleted when the Restart
    # Time ends: "the LLGR period is said to have begun" (section 4.2).
    # They carry LLGR_STALE, a route with NO_LLGR goes, and they are least
    # preferred (Rib::Decision's llgr_stale) and not sent to a peer that
    # did not send the capability (Rib::Export). They go when the LLST
    # ends, or at the family's End-of-RIB on the new session, or at once
    # when that session's capability does not keep them. The global
    # table's families: unicast in the RIB (4a), and the VPN, EVPN, BGP-LS
    # and unreachability tables (4b).
    class GracefulRestart

      KIND = BGP::Events.register_kind(:gr)

      # The keys of a neighbor's `graceful_restart` block.
      KEYS = %w[restart_time stale_time notification].freeze

      # RFC 8538 section 2: "The second most significant bit [of the
      # Restart Flags] is defined in this document as the Graceful
      # Notification ("N") bit". The flags are four bits, R first.
      N_BIT = 0x4

      # RFC 8538 section 3, the Hard Reset: Cease, subcode 9.
      CEASE = 6
      HARD_RESET = 9

      # RFC 8538 section 5.1's advice, by Cease subcode: true for "Hard
      # Reset", false for "Graceful Cease", nil for "Provide user
      # control", which is Administrative Reset and goes graceful unless
      # asked. 10, BFD Down (RFC 9384), is after the table; it says the
      # forwarding path failed, not that the peer is gone, so graceful.
      HARD = { 1 => true, 2 => true, 3 => true, 4 => nil, 5 => false, 6 => false,
               7 => false, 8 => false, 9 => true, 10 => false }.freeze

      # The keys of a neighbor's `long_lived_graceful_restart` block.
      LLGR_KEYS = %w[families max_stale_time].freeze

      # The families the LLGR period is built for, by name.
      # IPv4 and IPv6 unicast are the default.
      LLGR_FAMILIES = { 'ipv4_unicast' => [1, 1], 'ipv6_unicast' => [2, 1],
                        'vpnv4_unicast' => [1, 128], 'vpnv6_unicast' => [2, 128],
                        'l2vpn_evpn' => [25, 70], 'bgp_ls' => [16_388, 71],
                        'ipv4_unreachability' => [1, 81], 'ipv6_unreachability' => [2, 81] }.freeze
      LLGR_DEFAULT = %w[ipv4_unicast ipv6_unicast].freeze

      # RFC 9494 section 3.1: the F bit, and the 24-bit LLST.
      F_BIT = BGP::OPT_PARM::CAP::Long_lived_graceful_restart::F_BIT
      MAX_LLST = BGP::OPT_PARM::CAP::Long_lived_graceful_restart::MAX_LLST

      # How long routes stay stale on a new session with no End-of-RIB,
      # in seconds: RFC 8538 section 4.1's "suggested default value [...]
      # is 180 seconds".
      STALE_TIME = 180

      # Raises ArgumentError unless value is nil, true, or a mapping of
      # KEYS: restart_time 0 to 4095, RFC 4724 section 3's 12 bits;
      # stale_time a whole number of seconds from 1; notification true or
      # false, RFC 8538's N bit.
      def self.check(value, address)
        return if value.nil? || value == true
        where = "neighbor #{address}: graceful_restart"
        raise ArgumentError, "#{where} is true or a mapping of #{KEYS.join(', ')}, not #{value.inspect}" unless value.is_a?(Hash)
        unless [nil, true, false].include?(value['notification'])
          raise ArgumentError, "#{where}: notification is true or false, not #{value['notification'].inspect}"
        end
        unknown = value.keys - KEYS
        raise ArgumentError, "#{where}: unknown key(s) #{unknown.join(', ')}: use #{KEYS.join(', ')}" unless unknown.empty?
        rt = value['restart_time']
        unless rt.nil? || (rt.is_a?(Integer) && (0..4095).include?(rt))
          raise ArgumentError, "#{where}: restart_time is 0 to 4095 seconds (RFC 4724 section 3), not #{rt.inspect}"
        end
        st = value['stale_time']
        unless st.nil? || (st.is_a?(Integer) && st >= 1)
          raise ArgumentError, "#{where}: stale_time is a whole number of seconds from 1, not #{st.inspect}"
        end
      end

      # Raises ArgumentError unless value is nil, true, or a mapping of
      # LLGR_KEYS: families named in LLGR_FAMILIES, max_stale_time 0 to
      # 2^24 - 1. RFC 9494 section 4.1: "If the LLGR Capability is
      # advertised, the Graceful Restart capability MUST also be
      # advertised", so it needs graceful_restart.
      def self.check_llgr(value, gr, address)
        return if value.nil?
        where = "neighbor #{address}: long_lived_graceful_restart"
        raise ArgumentError, "#{where} needs graceful_restart too (RFC 9494 section 4.1)" if gr.nil?
        return if value == true
        raise ArgumentError, "#{where} is true or a mapping of #{LLGR_KEYS.join(', ')}, not #{value.inspect}" unless value.is_a?(Hash)
        unknown = value.keys - LLGR_KEYS
        raise ArgumentError, "#{where}: unknown key(s) #{unknown.join(', ')}: use #{LLGR_KEYS.join(', ')}" unless unknown.empty?
        fams = value.fetch('families', LLGR_DEFAULT)
        bad = Array(fams).collect(&:to_s) - LLGR_FAMILIES.keys
        unless fams.is_a?(Array) && !fams.empty? && bad.empty?
          raise ArgumentError, "#{where}: families are of #{LLGR_FAMILIES.keys.join(', ')}, not #{(bad.empty? ? fams : bad).inspect}"
        end
        m = value['max_stale_time']
        unless m.nil? || (m.is_a?(Integer) && (0..MAX_LLST).include?(m))
          raise ArgumentError, "#{where}: max_stale_time is 0 to #{MAX_LLST} seconds (RFC 9494 section 3.1), not #{m.inspect}"
        end
      end

      # The families of a `long_lived_graceful_restart` value, [afi, safi].
      def self.llgr_families(value)
        names = value.is_a?(Hash) ? value.fetch('families', LLGR_DEFAULT) : LLGR_DEFAULT
        Array(names).collect { |n| LLGR_FAMILIES.fetch(n.to_s) }
      end

      # What bgp4rd advertises: each family with a Long-Lived Stale Time of
      # 0 and F clear. bgp4rd keeps no state across its own restart, so a
      # peer must not keep its routes; section 4.2, with both times 0,
      # "only those of the base BGP specification" apply.
      def self.llgr_capability(value)
        cap = BGP::OPT_PARM::CAP::Long_lived_graceful_restart.new
        llgr_families(value).each { |afi, safi| cap.add(afi, safi, 0, 0) }
        cap
      end

      # { [afi, safi] => [flags, llst] } from the last LLGR capability an
      # OPEN carried, or nil. nil too without a GR capability: section
      # 4.5, it "MUST be ignored".
      def self.received_llgr(open)
        return nil unless open && received(open)
        cap = Refresh.capabilities(open).select { |c| c.is_a?(BGP::OPT_PARM::CAP::Long_lived_graceful_restart) }.last
        cap && cap.tuples.to_h { |afi, safi, flags, llst| [[afi, safi], [flags, llst]] }
      end

      # What the decision and export ask, for the speaker: which routes
      # are least preferred, and which peers sent the capability.
      class Policy
        def initialize(speaker) ; @speaker = speaker ; end

        # RFC 9494 section 4.3: a route with LLGR_STALE from a neighbor
        # we advertised the capability to.
        def stale?(route)
          !route.local? && BGP::Rib::Llgr.stale?(route.path_attribute) && helping?(route.peer.address)
        end

        def helping?(address)
          p = peer(address)
          !p.nil? && !p.config['long_lived_graceful_restart'].nil?
        end

        # True when the peer's session carried the LLGR capability, with
        # GR (section 4.5).
        def capable?(address)
          info = peer(address)&.neighbor&.session_info
          !GracefulRestart.received_llgr(info && info.peer).nil?
        end

        private

        def peer(address) ; @speaker.peers.find { |p| p.address == address.to_s } ; end
      end

      # What bgp4rd advertises: R clear, N when `notification` is true,
      # the configured Restart Time (0 unless set), and no families.
      def self.capability(value)
        rt = value.is_a?(Hash) ? value.fetch('restart_time', 0) : 0
        BGP::OPT_PARM::CAP::Graceful_restart.new(notification?(value) ? N_BIT : 0, rt)
      end

      def self.notification?(value)
        value.is_a?(Hash) && value['notification'] == true
      end

      # True when both OPENs of a session carried the N bit: RFC 8538
      # section 4's "has received the "N" bit from its peer", from a
      # speaker that advertised it.
      def self.exchanged?(session_info)
        return false unless session_info
        [session_info.speaker, session_info.peer].all? do |open|
          cap = received(open)
          cap && (cap[:restart_state] & N_BIT) != 0
        end
      end

      # The Cease to send for subcode: on a session where the N bit was
      # exchanged, a Hard Reset carrying it (RFC 8538 section 3.1, "the
      # Hard Reset encapsulates another NOTIFICATION message in its data
      # portion") when hard is true, or when hard is nil and section
      # 5.1's table says so; otherwise the Cease itself. Without N there
      # is no Hard Reset to send: section 4, "A BGP speaker SHOULD NOT
      # send a Hard Reset to a peer from which it has not received the
      # "N" bit".
      def self.cease(subcode, session_info, hard = nil)
        hard = HARD[subcode] if hard.nil?
        if hard && subcode != HARD_RESET && exchanged?(session_info)
          BGP::Notification.new(CEASE, HARD_RESET, [CEASE, subcode].pack('CC'))
        else
          BGP::Notification.new(CEASE, subcode)
        end
      end

      # The last GR capability an OPEN carried, as its to_hash's
      # :capability, or nil. RFC 4724 section 3: the receiver "MUST
      # ignore all but the last instance".
      def self.received(open)
        return nil unless open
        cap = Refresh.capabilities(open).select { |c| c.is_a?(BGP::OPT_PARM::CAP::Graceful_restart) }.last
        cap && cap.to_hash[:capability]
      end

      # { [afi, safi] => true when the F bit is set } for the families an
      # OPEN's GR capability listed.
      def self.families(open)
        cap = received(open) or return {}
        cap[:families].to_h { |f| [[f[:afi], f[:safi]], (f[:flags] & 0x80) != 0] }
      end

      # clock answers seconds, monotonic; a test passes its own.
      def initialize(peer, speaker, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @peer, @speaker, @clock = peer, speaker, clock
        @lock = Mutex.new
        @restart_at = {}    # [afi, safi] => when its Restart Time runs out, while the peer is away
        @waiting = {}       # [afi, safi] => when its stale timer runs out
        # @llst, set by down: [afi, safi] => its Long-Lived Stale Time, from the last session
        @llgr_until = {}    # [afi, safi] => when its LLGR period ends
        @syncing = []       # LLGR families waiting for their End-of-RIB
        @n = nil            # whether the last session exchanged the N bit
        @watcher = nil
      end

      def configured? ; !@peer.config['graceful_restart'].nil? ; end

      def llgr_configured? ; configured? && !@peer.config['long_lived_graceful_restart'].nil? && !@peer.vrf ; end

      # Section 4.2: the received LLST "MAY be reduced by local configuration".
      def max_stale_time
        v = @peer.config['long_lived_graceful_restart']
        v.is_a?(Hash) ? v['max_stale_time'] : nil
      end

      def stale_time
        v = @peer.config['graceful_restart']
        (v.is_a?(Hash) && v['stale_time']) || STALE_TIME
      end

      # The session went from Established to anything else. Answers the
      # families the tables keep, [afi, safi], which is none unless this
      # peer is configured, the session's peer listed families in its GR
      # capability, and the drop is one the rules keep for: a TCP
      # failure, or with the N bit exchanged a NOTIFICATION other than a
      # Hard Reset or the hold timer.
      #
      # Without N, what was stale already goes first, through the tables
      # as an EoRR's purge does, so the tables then mark only what is
      # left: RFC 4724 section 4.2's consecutive restart rule.
      def down(session_info, cause)
        return [] unless configured?
        theirs = GracefulRestart.received(session_info && session_info.peer)
        gr_fams = theirs ? theirs[:families].collect { |f| [f[:afi], f[:safi]] } : []
        llst = llsts(session_info)
        in_llgr = @lock.synchronize { @llgr_until.keys }
        families = gr_fams | llst.keys | in_llgr
        n = GracefulRestart.exchanged?(session_info)
        @lock.synchronize { @n = n }
        unless !families.empty? && (cause == :tcp || (n && %i[notification hold_time].include?(cause)))
          if theirs && !families.empty?
            why = cause == :hard_reset ? 'a Hard Reset, as RFC 8538 section 3.2 asks' :
                    (n ? 'a stop of our own' : 'a NOTIFICATION, as RFC 4724 section 4 asks, with no N bit exchanged')
            event("session ended by #{cause || 'us'}: routes flushed after #{why}",
                  :flushed => { :cause => (cause || :local).to_s, :notification => n })
          end
          clear
          return []
        end
        # RFC 9494 section 4.2: "in the case of consecutive restarts, the
        # previously marked stale routes MUST NOT be deleted before the
        # timer for the Long-Lived Stale Time expires".
        (families - in_llgr).each { |afi, safi| purge(afi, safi, 'consecutive restart, no N bit', quiet: true) } unless n
        time = theirs ? theirs[:restart_time] : 0
        now = @clock.call
        @lock.synchronize do
          # Section 4.2: a family the GR capability does not list has a
          # Restart Time of zero; one already in its LLGR period keeps
          # its timer.
          @restart_at = (families - in_llgr).to_h { |f| [f, now + (gr_fams.include?(f) ? time : 0)] }
          @llst = llst
          @waiting = {}
        end
        event("helper started after #{cause}: #{families.size} famil#{families.size == 1 ? 'y' : 'ies'} kept stale for the peer's Restart Time, #{time} s",
              :helper => { :families => families.collect { |a, s| { :afi => a, :safi => s } }, :restart_time => time,
                           :cause => cause.to_s, :notification => n,
                           :long_lived => llst.collect { |(a, s), t| { :afi => a, :safi => s, :llst => t } } })
        watch
        families
      end

      # The session is Established again. Families not listed with F set
      # in the new OPEN go now; the rest wait for End-of-RIB or the stale
      # timer.
      def up(session_info)
        n = GracefulRestart.exchanged?(session_info)
        kept, long = @lock.synchronize do
          @n = n
          k = @restart_at.keys
          @restart_at = {}
          [k, @llgr_until.keys]
        end
        back_llgr(session_info, long) unless long.empty?
        return if kept.empty?
        fams = GracefulRestart.families(session_info && session_info.peer)
        now_gone, wait = kept.partition { |f| !fams[f] }
        @lock.synchronize { wait.each { |f| @waiting[f] = @clock.call + stale_time } }
        now_gone.each { |afi, safi| purge(afi, safi, fams.key?([afi, safi]) ? 'F bit clear' : 'family not in the new capability') }
        event("session back: #{wait.size} famil#{wait.size == 1 ? 'y waits' : 'ies wait'} for End-of-RIB, at most #{stale_time} s",
              :back => { :waiting => wait.collect { |a, s| { :afi => a, :safi => s } }, :stale_time => stale_time }) unless wait.empty?
        watch unless wait.empty?
      end

      # BGP::Neighbor calls this with every message: an End-of-RIB for a
      # family that waits removes what is still stale in it.
      def update(msg)
        return unless msg.is_a?(BGP::Update)
        fam = msg.end_of_rib or return
        waited = @lock.synchronize do
          # Section 4.2: the LLST timer "is neither stopped nor updated
          # until the EoR marker is received".
          long = @syncing.delete(fam) && @llgr_until.delete(fam)
          @waiting.delete(fam) || long
        end
        purge(*fam, 'End-of-RIB') if waited
      end

      # Purges what ran out by now: every kept family once the Restart
      # Time is past with no session, and each waiting family past its
      # stale timer. Answers what it purged, as [afi, safi, why].
      def expire
        now = @clock.call
        due = @lock.synchronize do
          list = []
          @restart_at.select { |_, at| at <= now }.each_key do |f|
            @restart_at.delete(f)
            # Section 4.2: "Once the Restart Time period ends [...] the
            # LLGR period is said to have begun".
            if @llst[f].to_i.positive?
              @llgr_until[f] = now + @llst[f]
              list << [*f, :llgr]
            else
              list << [*f, 'Restart Time']
            end
          end
          @llgr_until.select { |_, at| at <= now }.each_key do |f|
            @llgr_until.delete(f)
            list << [*f, 'Long-Lived Stale Time']
          end
          @waiting.select { |_, at| at <= now }.each_key { |f| @waiting.delete(f) ; list << [*f, 'stale_time'] }
          list
        end
        due.each { |afi, safi, why| why == :llgr ? long_lived(afi, safi) : purge(afi, safi, why) }
        due
      end

      # nil when nothing is held; 'restarting' while the peer is away in
      # its Restart Time; 'long_lived' while a family is in its LLGR
      # period; 'helper' while a family waits for its End-of-RIB.
      def state
        @lock.synchronize do
          if !@restart_at.empty? then 'restarting'
          elsif !@llgr_until.empty? then 'long_lived'
          elsif !@waiting.empty? then 'helper'
          end
        end
      end

      # For the peer row: the state, the families held, the seconds left
      # on the timer that runs, whether the N bit was exchanged on the
      # last session, and each family in its LLGR period with the seconds
      # its LLST has left.
      def row
        now = @clock.call
        left = ->(at) { [(at - now).ceil, 0].max }
        @lock.synchronize do
          r = if !@restart_at.empty?
                { :state => 'restarting', :families => fam_rows(@restart_at.keys), :seconds_left => left.(@restart_at.values.min) }
              elsif !@llgr_until.empty?
                { :state => 'long_lived', :families => fam_rows(@llgr_until.keys), :seconds_left => left.(@llgr_until.values.min) }
              elsif !@waiting.empty?
                { :state => 'helper', :families => fam_rows(@waiting.keys), :seconds_left => left.(@waiting.values.min) }
              else
                { :state => nil, :families => [], :seconds_left => nil }
              end
          r.merge(:notification => @n == true,
                  :long_lived => @llgr_until.collect { |(a, s), at| { :afi => a, :safi => s, :seconds_left => left.(at) } })
        end
      end

      private

      def clear
        @lock.synchronize { @restart_at = {} ; @waiting = {} ; @llst = {} ; @llgr_until = {} ; @syncing = [] }
      end

      # { [afi, safi] => seconds } for each family that gets an LLGR
      # period: listed by the peer with a non-zero LLST (section 4.2),
      # reduced to max_stale_time, one we advertised, and one the session
      # negotiated: section 4.2 speaks of "all AFIs/SAFIs supported by
      # the session", and a family it did not carry has no End-of-RIB to
      # end the period.
      def llsts(session_info)
        return {} unless llgr_configured?
        got = GracefulRestart.received_llgr(session_info && session_info.peer) or return {}
        ours = GracefulRestart.llgr_families(@peer.config['long_lived_graceful_restart'])
        cap = max_stale_time
        negotiated = EndOfRib.families(session_info)
        got.each_with_object({}) do |(f, (_, t)), h|
          t = [t, cap].min if cap
          h[f] = t if t.positive? && ours.include?(f) && negotiated.include?(f)
        end
      end

      # The LLGR period begins for one family.
      def long_lived(afi, safi)
        t = @lock.synchronize { @llst[[afi, safi]] }
        @speaker.stale_family(@peer, afi, safi, :llgr) do |n|
          marked, gone = Array(n)
          event("LLGR period for AFI #{afi} SAFI #{safi}: #{marked.to_i} route(s) LLGR_STALE, #{gone.to_i} with NO_LLGR removed, " \
                "for the Long-Lived Stale Time, #{t} s",
                :long_lived => { :afi => afi, :safi => safi, :marked => marked.to_i, :removed => gone.to_i, :llst => t })
        end
      end

      # The session is back with families in their LLGR period. Section
      # 4.2: the routes go at once when the new LLGR capability does not
      # list the family with F set, or is not there; the rest wait for
      # their End-of-RIB, the LLST still running.
      def back_llgr(session_info, families)
        got = llgr_configured? ? GracefulRestart.received_llgr(session_info && session_info.peer) : nil
        negotiated = EndOfRib.families(session_info)
        gone, wait = families.partition { |f| !(got && got[f] && (got[f][0] & F_BIT) != 0 && negotiated.include?(f)) }
        @lock.synchronize do
          gone.each { |f| @llgr_until.delete(f) }
          @syncing |= wait
        end
        gone.each do |afi, safi|
          why = if got.nil? then 'no LLGR capability on the new session'
                elsif !got.key?([afi, safi]) then 'family not in the new LLGR capability'
                elsif (got[[afi, safi]][0] & F_BIT).zero? then 'LLGR F bit clear'
                else 'family not negotiated on the new session'
                end
          purge(afi, safi, why)
        end
        return if wait.empty?
        event("session back: #{wait.size} long-lived famil#{wait.size == 1 ? 'y waits' : 'ies wait'} for End-of-RIB, the LLST running",
              :back => { :long_lived => wait.collect { |a, s| { :afi => a, :safi => s } } })
      end

      def fam_rows(list) ; list.collect { |a, s| { :afi => a, :safi => s } } ; end

      # quiet: publish only when something went.
      def purge(afi, safi, why, quiet: false)
        @speaker.stale_family(@peer, afi, safi, :purge) do |n|
          next if quiet && n.to_i.zero?
          event("#{why} for AFI #{afi} SAFI #{safi}: #{n.nil? ? 'no table holds this family, nothing' : n} stale removed",
                :purged => { :afi => afi, :safi => safi, :removed => n }, :reason => why)
        end
      end

      # It ends itself, under the lock, once no timer runs.
      def watch
        @lock.synchronize do
          return if @watcher
          @watcher = Thread.new do
            loop do
              sleep 1
              expire
              done = @lock.synchronize do
                idle = @restart_at.empty? && @waiting.empty? && @llgr_until.empty?
                @watcher = nil if idle
                idle
              end
              break if done
            end
          end
        end
      end

      def event(message, data)
        @speaker.events.publish(:kind => KIND, :peer => @peer.address, :message => message, :data => data)
      end
    end
  end
end
