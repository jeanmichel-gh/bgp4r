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

require 'bgp/messages/notification'

module BGP
  module Sim

    # bgp4r-sim as the speaker that restarts: the `gr_` and `llgr_`
    # entries of `BGP::Fault::BEHAVIOURS`, and the `BGP::Fault::LLGR`
    # OPEN cases; docs/design/bgp-operations.md sections 3 and 4, pull
    # requests 3c and 4c. Included in Injector.
    #
    # The sim's peer has to list a GR capability of its own, with its
    # families, in `capabilities`:
    #
    #   capabilities: [as4_byte, {graceful_restart: [4, 120, [1, 1, 128]]}]
    #
    # Each behaviour reads that capability and changes it for the next
    # session only (`Peer#next_session`): the Restart State bit (R) set,
    # and each family's F bit as the case says. The N bit stays as
    # configured. Going down is a TCP close with no NOTIFICATION, which
    # is what a restart looks like to the peer, or a NOTIFICATION first
    # when the case sends one. The sim stays down for `away` seconds (1
    # unless given), then comes back: its routes go again, and then
    # End-of-RIB, unless the case says otherwise.
    #
    # A sim that dials comes back at once. A passive one waits for the
    # peer to dial it again, on the peer's timer.
    #
    # `drop` names prefixes the sim announced (the `announce` action)
    # that it does not send again: what a restarted speaker no longer
    # has, which End-of-RIB or a timer should purge. A node file's own
    # `announce` blocks always go again.
    #
    # The action answers at once, as `session.flap` does; the behaviour
    # runs on a thread. A scenario waits on a condition.
    module GracefulRestartBehaviour

      # RFC 4724 section 3: the Restart State bit, the top one of the
      # four Restart Flags. RFC 8538 section 2: N, the next one down. And
      # the Forwarding State bit, the top one of a family's flags.
      R_BIT = 0x8
      N_BIT = 0x4
      F_BIT = 0x80
      NAMES = %w[graceful_restart gr].freeze
      LLGR_NAMES = %w[long_lived_graceful_restart llgr].freeze

      # How long a behaviour waits for the session to come back.
      BACK_WITHIN = 60

      # The GR capability a peer's config lists, as [flags, restart
      # time, [[afi, safi, flags], ...]], or nil when it lists none.
      def self.capability(config)
        Array(config['capabilities']).each do |c|
          next unless c.is_a?(Hash) && NAMES.include?(c.keys.first.to_s)
          args = Array(c.values.first)
          families = args[2..].to_a.collect { |f| f = Array(f) ; [Integer(f[0]), Integer(f[1]), Integer(f[2] || 0)] }
          return [Integer(args[0] || 0), Integer(args[1] || 0), families]
        end
        nil
      end

      # The LLGR capability a peer's config lists, as [[afi, safi, flags,
      # llst], ...], or nil when it lists none. One tuple, or a list of
      # them:
      #
      #   {llgr: [1, 1, 128, 60]}
      #   {llgr: [[1, 1, 128, 60], [2, 1, 128, 60]]}
      def self.llgr(config)
        Array(config['capabilities']).each do |c|
          next unless c.is_a?(Hash) && LLGR_NAMES.include?(c.keys.first.to_s)
          args = Array(c.values.first)
          args = [args] unless args.first.is_a?(Array)
          return args.collect { |t| [Integer(t[0]), Integer(t[1]), Integer(t[2] || 0), Integer(t[3] || 0)] }
        end
        nil
      end

      # The config's capabilities, with the GR one given in its place, or
      # none when flags is nil; and the LLGR one too when llgr gives its
      # tuples.
      def self.capabilities(config, flags, time, families, llgr: nil)
        names = llgr ? NAMES + LLGR_NAMES : NAMES
        caps = Array(config.fetch('capabilities', ['as4_byte'])).reject { |c|
          names.include?((c.is_a?(Hash) ? c.keys.first : c).to_s)
        }
        caps += [{ 'graceful_restart' => [flags, time, *families] }] if flags
        caps += [{ 'long_lived_graceful_restart' => llgr }] if llgr
        caps
      end

      # A Hard Reset, RFC 8538 section 3.1: Cease subcode 9, its data the
      # inner code and subcode, here Administrative Shutdown (6/2).
      HARD_RESET = [6, 9, [6, 2].pack('CC')].freeze
      # Other Configuration Change, which RFC 8538 section 5.1 lists as
      # graceful.
      GRACEFUL_CEASE = [6, 6].freeze

      private

      def gr_behaviour(name, block)
        needs = BGP::Fault.behaviour_catalog.find { |b| b[:name].to_s == name }[:needs]
        away = seconds(block, 'away', 1)
        afi = integer(block, 'afi', 1)
        safi = integer(block, 'safi', 1)
        drop = Array(block['drop']).collect(&:to_s)
        marked = Array(block['prefixes']).collect(&:to_s)
        if name == 'llgr_no_llgr_route'
          raise Injector::Refused, "behaviour #{name}: prefixes names the routes to mark NO_LLGR" if marked.empty?
        elsif block.key?('prefixes')
          raise Injector::Refused, "behaviour #{name} takes no prefixes; only llgr_no_llgr_route does"
        end
        peers = targets(block)
        plans = peers.collect do |peer|
          gr = GracefulRestartBehaviour.capability(peer.config)
          unless gr
            raise Injector::Refused, "behaviour #{name}: #{peer.address} lists no graceful_restart capability, " \
                           'so it cannot restart gracefully; add one to its capabilities, ' \
                           'such as {graceful_restart: [0, 120, [1, 1, 128]]}'
          end
          n = (gr[0] & N_BIT) != 0
          if needs == :llgr && !GracefulRestartBehaviour.llgr(peer.config)
            raise Injector::Refused, "behaviour #{name}: #{peer.address} lists no long_lived_graceful_restart capability; " \
                           'add one to its capabilities, such as {llgr: [1, 1, 128, 60]}'
          elsif needs == :n && !n
            raise Injector::Refused, "behaviour #{name}: needs the N bit (#{N_BIT}) in #{peer.address}'s graceful_restart capability"
          elsif needs == :no_n && n
            raise Injector::Refused, "behaviour #{name}: needs no N bit in #{peer.address}'s graceful_restart capability"
          end
          [peer, gr]
        end
        no_llgr(marked) unless marked.empty?
        forget(drop) unless drop.empty?
        plans.each do |peer, gr|
          thread = Thread.new { run_gr(name, peer, gr, away, [afi, safi]) }
          @lock.synchronize { @threads << thread }
        end
        addresses = peers.collect(&:address)
        extra = marked.empty? ? {} : { :prefixes => marked }
        publish(Injector::FAULT, "behaviour #{name}", :behaviour => name, :peers => addresses, :away => away,
                                                     :drop => drop, **extra)
        { :action => 'behaviour', :behaviour => name, :peers => addresses, :away => away,
          :drop => drop, **extra, :running => true }
      end

      # RFC 9494 section 3.3: the prefixes announced again with NO_LLGR
      # beside the communities they had, before the behaviour drops the
      # session. Neighbor#stop writes what is queued before it closes.
      def no_llgr(prefixes)
        known = @lock.synchronize { @announced.dup }
        missing = prefixes.reject { |p| known.key?(p) }
        unless missing.empty?
          raise Injector::Refused, "behaviour llgr_no_llgr_route: #{missing.join(', ')} was not announced from here; announce it first"
        end
        prefixes.group_by { |p| known[p] }.each do |was, pfxs|
          communities = (Array(was['communities']) + ['no_llgr']).uniq
          attribute('prefixes' => pfxs, 'communities' => communities)
        end
      end

      # One behaviour on one peer, on its own thread.
      def run_gr(name, peer, gr, away, family)
        flags, time, families = gr
        restarting = flags | R_BIT
        f_set = families.collect { |a, s, f| [a, s, f | F_BIT] }
        # RFC 9494 section 4.2: back with the F bit set in each LLGR
        # family too, or the helper drops what it kept.
        llgr = GracefulRestartBehaviour.llgr(peer.config)&.collect { |a, s, f, l| [a, s, f | F_BIT, l] }
        back = lambda do |fl, fams, eor: true, quiet: false|
          old = peer.neighbor
          peer.next_session('capabilities' => GracefulRestartBehaviour.capabilities(peer.config, fl, time, fams, llgr: llgr),
                            'end_of_rib' => eor, 'quiet' => quiet)
          sleep away
          peer.admin_start
          gr_wait_back(peer, old, name)
        end
        case name
        when 'gr_restart'
          gr_down(peer) ; back.(restarting, f_set)
        when 'gr_restart_no_f'
          gr_down(peer) ; back.(restarting, families.collect { |a, s, f| [a, s, f & ~F_BIT] })
        when 'gr_restart_family_missing'
          gr_down(peer) ; back.(restarting, f_set.reject { |a, s, _| [a, s] == family })
        when 'gr_never_back', 'llgr_never_back'
          gr_down(peer)
        when 'llgr_long_restart', 'llgr_no_llgr_route'
          gr_down(peer) ; back.(restarting, f_set)
        when 'gr_no_eor'
          gr_down(peer) ; back.(restarting, f_set, eor: false)
        when 'gr_new_connection'
          old = peer.neighbor
          peer.next_session('capabilities' => GracefulRestartBehaviour.capabilities(peer.config, restarting, time, f_set),
                            'end_of_rib' => true)
          peer.redial
          gr_wait_back(peer, old, name)
        when 'gr_consecutive', 'gr_consecutive_n'
          # The first time back sends nothing, so what is stale stays
          # stale for the second drop to find; it stays up `away`.
          gr_down(peer) ; back.(restarting, f_set, eor: false, quiet: true)
          sleep away
          gr_down(peer) ; back.(restarting, f_set)
        when 'gr_graceful_cease'
          gr_down(peer, BGP::Notification.new(*GRACEFUL_CEASE)) ; back.(restarting, f_set)
        when 'gr_hard_reset'
          gr_down(peer, BGP::Notification.new(*HARD_RESET)) ; back.(flags, f_set)
        when 'gr_notification_no_n'
          gr_down(peer, BGP::Notification.new(*GRACEFUL_CEASE)) ; back.(flags, f_set)
        end
        publish(:log, "behaviour #{name} done on #{peer.address}", :behaviour => name, :peer => peer.address)
      rescue StandardError => e
        log(:warn, "bgp4r-sim: behaviour #{name} on #{peer.address}: #{e.class}: #{e.message}")
      end

      # One `BGP::Fault::LLGR` case: the session brought up again with
      # the case's OPEN, for that one session. The sim sends a Hard
      # Reset first when it lists N, a Cease 6/2 when not, so the
      # receiver flushes and does not help (RFC 8538 section 3.2, RFC
      # 4724 section 4): what it does with the new OPEN starts clean.
      # The sim's routes go again on the new session.
      def llgr_fault(name, block)
        extra = block.keys & %w[prefixes next_hop afi safi]
        raise Injector::Refused, "fault: #{name} is an OPEN case and takes no #{extra.join(' or ')}" unless extra.empty?
        peers = targets(block)
        plans = peers.collect do |peer|
          gr = GracefulRestartBehaviour.capability(peer.config)
          llgr = GracefulRestartBehaviour.llgr(peer.config)
          unless gr && llgr
            raise Injector::Refused, "fault: #{name}: #{peer.address} lists no #{gr ? 'long_lived_graceful_restart' : 'graceful_restart'} " \
                           'capability; add one to its capabilities, such as ' \
                           "#{gr ? '{llgr: [1, 1, 128, 60]}' : '{graceful_restart: [0, 120, [1, 1, 128]]}'}"
          end
          keep_gr, tuples = BGP::Fault.llgr(name, llgr)
          [peer, keep_gr ? gr : nil, tuples]
        end
        plans.each do |peer, gr, tuples|
          thread = Thread.new { run_llgr_fault(name, peer, gr, tuples) }
          @lock.synchronize { @threads << thread }
        end
        addresses = peers.collect(&:address)
        publish(Injector::FAULT, "injected fault #{name}", :case => name, :peers => addresses)
        { :action => 'fault', :case => name, :peers => addresses, :running => true }
      end

      def run_llgr_fault(name, peer, gr, tuples)
        flags, time, families = gr || GracefulRestartBehaviour.capability(peer.config)
        old = peer.neighbor
        peer.next_session('capabilities' => GracefulRestartBehaviour.capabilities(peer.config, gr && flags, time,
                                                                                  families, llgr: tuples))
        reset = (flags & N_BIT) != 0 ? HARD_RESET : [6, 2]
        gr_down(peer, BGP::Notification.new(*reset))
        peer.admin_start
        gr_wait_back(peer, old, name)
        publish(:log, "fault #{name} done on #{peer.address}", :case => name, :peer => peer.address)
      rescue StandardError => e
        log(:warn, "bgp4r-sim: fault #{name} on #{peer.address}: #{e.class}: #{e.message}")
      end

      # Down, with msg sent first when there is one. admin_stop closes the
      # connection with no NOTIFICATION of its own, and holds the session
      # down until admin_start. A session gone before msg could be sent
      # ends the behaviour, logged.
      def gr_down(peer, msg = nil)
        peer.send_message(msg) if msg
        peer.admin_stop
      end

      # Until a session other than old is Established.
      def gr_wait_back(peer, old, name)
        deadline = Time.now + BACK_WITHIN
        until peer.neighbor && !peer.neighbor.equal?(old) && peer.established?
          raise "#{name}: #{peer.address} did not come back within #{BACK_WITHIN}s" if Time.now > deadline
          sleep 0.05
        end
      end
    end
  end
end
