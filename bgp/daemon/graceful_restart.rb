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
        @kept = []          # the families held through the restart, [afi, safi]
        @restart_at = nil   # when the peer's Restart Time runs out
        @waiting = {}       # [afi, safi] => when its stale timer runs out
        @n = nil            # whether the last session exchanged the N bit
        @watcher = nil
      end

      def configured? ; !@peer.config['graceful_restart'].nil? ; end

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
        families = theirs ? theirs[:families].collect { |f| [f[:afi], f[:safi]] } : []
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
        families.each { |afi, safi| purge(afi, safi, 'consecutive restart, no N bit', quiet: true) } unless n
        time = theirs[:restart_time]
        @lock.synchronize do
          @kept = families
          @waiting = {}
          @restart_at = @clock.call + time
        end
        event("helper started after #{cause}: #{families.size} famil#{families.size == 1 ? 'y' : 'ies'} kept stale for the peer's Restart Time, #{time} s",
              :helper => { :families => families.collect { |a, s| { :afi => a, :safi => s } }, :restart_time => time,
                           :cause => cause.to_s, :notification => n })
        watch
        families
      end

      # The session is Established again. Families not listed with F set
      # in the new OPEN go now; the rest wait for End-of-RIB or the stale
      # timer.
      def up(session_info)
        n = GracefulRestart.exchanged?(session_info)
        kept = @lock.synchronize do
          @n = n
          k = @kept
          @restart_at = nil
          k
        end
        return if kept.empty?
        fams = GracefulRestart.families(session_info && session_info.peer)
        now_gone, wait = kept.partition { |f| !fams[f] }
        @lock.synchronize do
          @kept = []
          wait.each { |f| @waiting[f] = @clock.call + stale_time }
        end
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
        purge(*fam, 'End-of-RIB') if @lock.synchronize { @waiting.delete(fam) }
      end

      # Purges what ran out by now: every kept family once the Restart
      # Time is past with no session, and each waiting family past its
      # stale timer. Answers what it purged, as [afi, safi, why].
      def expire
        now = @clock.call
        due = @lock.synchronize do
          list = []
          if @restart_at && @restart_at <= now
            list += @kept.collect { |f| [*f, 'Restart Time'] }
            @kept = []
            @restart_at = nil
          end
          @waiting.select { |_, at| at <= now }.each_key { |f| @waiting.delete(f) ; list << [*f, 'stale_time'] }
          list
        end
        due.each { |afi, safi, why| purge(afi, safi, why) }
        due
      end

      # nil when nothing is held; 'restarting' while the peer is away;
      # 'helper' while a family waits for its End-of-RIB.
      def state
        @lock.synchronize { @restart_at ? 'restarting' : (@waiting.empty? ? nil : 'helper') }
      end

      # For the peer row: the state, the families held, the seconds left
      # on the timer that runs, and whether the N bit was exchanged on the
      # last session.
      def row
        now = @clock.call
        @lock.synchronize do
          r = if @restart_at
                { :state => 'restarting', :families => fam_rows(@kept), :seconds_left => [(@restart_at - now).ceil, 0].max }
              elsif !@waiting.empty?
                { :state => 'helper', :families => fam_rows(@waiting.keys), :seconds_left => [(@waiting.values.min - now).ceil, 0].max }
              else
                { :state => nil, :families => [], :seconds_left => nil }
              end
          r.merge(:notification => @n == true)
        end
      end

      private

      def clear
        @lock.synchronize { @kept = [] ; @waiting = {} ; @restart_at = nil }
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
                idle = @restart_at.nil? && @waiting.empty?
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
