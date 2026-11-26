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

    # Answering a route refresh, RFC 2918 section 4, and wrapping the
    # answer in BoRR and EoRR, RFC 7313 section 4. One per peer, watching
    # its session. docs/design/bgp-operations.md, section 2, is the design;
    # answering is its pull request 2a, receiving BoRR and EoRR 2b.
    #
    # RFC 2918 section 4: "If a BGP speaker receives from its peer a
    # ROUTE-REFRESH message with the <AFI, SAFI> that the speaker didn't
    # advertise to the peer at the session establishment time via
    # capability advertisement, the speaker shall ignore such a message.
    # Otherwise, the BGP speaker shall re-advertise to that peer the
    # Adj-RIB-Out of the <AFI, SAFI> carried in the message".
    #
    # **What turns answering on is our own OPEN**: the Route Refresh
    # capability (2, or its pre-standard 128) or the Enhanced one (70) in
    # the neighbor's `capabilities`. Once it went out, answering is a
    # "shall", so there is no key beside it. Without it a request is
    # ignored and logged, which is what bgp4rd did with every request
    # before.
    #
    # RFC 7313 section 4, when the peer advertised capability 70: "Before
    # the speaker starts a route refresh that is either initiated locally,
    # or in response to a "normal route refresh request" from the peer, the
    # speaker MUST send a BoRR message. After the speaker completes the
    # re-advertisement of the entire Adj-RIB-Out to the peer, it MUST send
    # an EoRR message."
    #
    # And on receipt, the same section: "When a BGP speaker receives a BoRR
    # message from a peer, it MUST mark all the routes with the given
    # [...] <AFI, SAFI> [...] from that peer as stale. [...] When a BGP
    # speaker receives an EoRR message from a peer, it MUST immediately
    # remove any routes from the peer that are still marked as stale for
    # that <AFI, SAFI>." It "MAY impose a locally configurable upper bound
    # on how long it would retain any stale routes": the neighbor's
    # `refresh_stale_time`. These "are applicable only if a BGP speaker
    # has received the "Enhanced Route Refresh Capability" from a peer", so
    # a BoRR or EoRR from a peer whose OPEN lacked 70 is ignored and
    # logged. The tables keep the mark (Speaker#stale_family).
    #
    # It counts every ROUTE-REFRESH message both ways by subtype, which is
    # what FRR counts, and the requests it answered and ignored, and
    # publishes a `refresh` event for each message, each answer, and each
    # mark and purge.
    class Refresh

      KIND = BGP::Events.register_kind(:refresh)

      # RFC 7313 section 3.2's subtypes by the names a reader sees.
      SUBTYPES = { 0 => 'normal', 1 => 'borr', 2 => 'eorr' }.freeze

      # How long routes stay stale after a BoRR with no EoRR, in seconds,
      # when the neighbor sets no `refresh_stale_time`: RFC 8538 section
      # 4.1's "suggested default value [...] is 180 seconds" for its stale
      # timer, reused (docs/design/bgp-operations.md, answer 6).
      STALE_TIME = 180

      # Raises ArgumentError unless value is nil or a whole number of
      # seconds from 1.
      def self.check(value, address)
        return if value.nil?
        return if value.is_a?(Integer) && value >= 1
        raise ArgumentError, "neighbor #{address}: refresh_stale_time must be a whole number of seconds from 1, not #{value.inspect}"
      end

      # clock answers seconds, monotonic; a test passes its own.
      def initialize(peer, speaker, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @peer = peer
        @speaker = speaker
        @clock = clock
        @lock = Mutex.new
        # One answer at a time per peer, so a second request waits for
        # the first EoRR rather than interleaving with it.
        @answering = Mutex.new
        @watcher = nil
        reset
      end

      # A new session: counts start again, as FRR's do. The tables drop a
      # closed session's routes, stale or not, so no family waits for an
      # EoRR any more.
      def reset
        @lock.synchronize do
          @counts = { 'received' => Hash.new(0), 'sent' => Hash.new(0), 'answered' => 0, 'ignored' => 0 }
          @deadlines = {} # [afi, safi] => when what is stale goes without an EoRR
        end
      end

      # The families marked stale by a BoRR and waiting for their EoRR, as
      # [afi, safi].
      def waiting
        @lock.synchronize { @deadlines.keys }
      end

      # The counts, as the peer row carries them.
      def counts
        @lock.synchronize do
          { 'received' => @counts['received'].dup, 'sent' => @counts['sent'].dup,
            'answered' => @counts['answered'], 'ignored' => @counts['ignored'] }
        end
      end

      # BGP::Neighbor calls this with every message it reads. A normal
      # request is answered on a thread of its own, since the answer waits
      # on the RIB's worker and this is the session's receive thread.
      def update(msg)
        case msg
        when BGP::Route_refresh
          count('received', msg.subtype)
          publish('receive', msg)
          afi, safi = msg.afi, msg.safi
          case msg.subtype || BGP::Route_refresh::NORMAL
          when BGP::Route_refresh::NORMAL then Thread.new { answer(afi, safi) }
          when BGP::Route_refresh::BORR then borr(afi, safi)
          when BGP::Route_refresh::EORR then eorr(afi, safi)
          else
            # RFC 7313 section 5: "it MUST ignore the received
            # ROUTE-REFRESH message. It SHOULD log an error".
            ignore(afi, safi, "subtype #{msg.subtype} is not 0, 1 or 2 (RFC 7313 section 5)", :error)
          end
        when BGP::Orf_route_refresh
          count('received', BGP::Route_refresh::NORMAL)
          log(:info, "bgp4r: #{@peer.address}: a ROUTE-REFRESH with ORF entries is not answered (RFC 5291 is not in bgp4rd)")
        end
      end

      # Sends one ROUTE-REFRESH on the peer's session, counted and
      # published. `Peer#refresh` and the answer both come here.
      def send_refresh(msg)
        n = @peer.neighbor
        raise NoSession, "no established session to #{@peer.address}" unless n && n.is_established?
        n.send_message(msg)
        count('sent', msg.subtype)
        publish('send', msg)
        msg
      rescue RuntimeError => e
        raise NoSession, "session to #{@peer.address} closed while sending: #{e.message}"
      end

      # The answer to one request: ignored, or BoRR when the peer is
      # enhanced, the family's Adj-RIB-Out again, and EoRR.
      def answer(afi, safi)
        @answering.synchronize do
          why = Refresh.refusal(@peer.session_info, afi, safi)
          if why
            @lock.synchronize { @counts['ignored'] += 1 }
            log(:info, "bgp4r: #{@peer.address}: route refresh for AFI #{afi} SAFI #{safi} ignored: #{why}")
            @speaker.events.publish(:kind => KIND, :peer => @peer.address,
                                    :message => "route refresh for AFI #{afi} SAFI #{safi} ignored: #{why}",
                                    :data => { :ignored => { :afi => afi, :safi => safi }, :reason => why })
            return
          end
          enhanced = Refresh.enhanced?(@peer.session_info)
          send_refresh(BGP::Route_refresh.new(afi, safi, BGP::Route_refresh::BORR)) if enhanced
          @speaker.resend_family(@peer, afi, safi)
          send_refresh(BGP::Route_refresh.new(afi, safi, BGP::Route_refresh::EORR)) if enhanced
          @lock.synchronize { @counts['answered'] += 1 }
          @speaker.events.publish(:kind => KIND, :peer => @peer.address,
                                  :message => "route refresh for AFI #{afi} SAFI #{safi} answered#{enhanced ? ', between BoRR and EoRR' : ''}",
                                  :data => { :answered => { :afi => afi, :safi => safi }, :enhanced => enhanced })
        end
      rescue NoSession => e
        log(:info, "bgp4r: #{@peer.address}: route refresh not answered: #{e.message}")
      rescue StandardError => e
        log(:error, "bgp4r: #{@peer.address}: route refresh: #{e.class}: #{e.message}")
      end

      # A BoRR: the peer's routes of that family are stale until its EoRR,
      # or until refresh_stale_time runs out. Runs on the session's receive
      # thread, so the mark lands between the UPDATEs before it and after
      # it. A second BoRR before the EoRR marks again and starts the time
      # again.
      def borr(afi, safi)
        return ignore(afi, safi, 'the peer did not advertise Enhanced Route Refresh (70)') unless Refresh.enhanced?(@peer.session_info)
        # Section 4: "A BGP speaker that has received the Graceful Restart
        # Capability from its neighbor MUST ignore any BoRRs for an <AFI,
        # SAFI> from the neighbor before the speaker receives the EoR for
        # the given <AFI, SAFI> from the neighbor. The BGP speaker SHOULD
        # log an error of the condition".
        if GracefulRestart.received(@peer.session_info && @peer.session_info.peer) && !end_of_rib_received?(afi, safi)
          return ignore(afi, safi, 'a BoRR before the End-of-RIB from a peer that advertised graceful restart (RFC 7313 section 4)', :error)
        end
        bound = @peer.config['refresh_stale_time'] || STALE_TIME
        @lock.synchronize { @deadlines[[afi, safi]] = @clock.call + bound }
        @speaker.stale_family(@peer, afi, safi, :mark) do |n|
          event("BoRR for AFI #{afi} SAFI #{safi}: #{stale_count(n)} marked stale, for at most #{bound} s",
                :stale => { :afi => afi, :safi => safi, :marked => n, :seconds => bound })
        end
        watch
      end

      # An EoRR: what is still stale of that family goes. An EoRR with no
      # BoRR before it is ignored and logged, as section 4 allows.
      def eorr(afi, safi)
        return ignore(afi, safi, 'the peer did not advertise Enhanced Route Refresh (70)') unless Refresh.enhanced?(@peer.session_info)
        return ignore(afi, safi, 'an EoRR with no BoRR before it (RFC 7313 section 4)') unless @lock.synchronize { @deadlines.delete([afi, safi]) }
        purge(afi, safi, 'EoRR')
      end

      # Purges every family whose bound ran out by now. The watcher thread
      # calls it once a second; a test calls it with its own clock.
      def expire
        now = @clock.call
        due = @lock.synchronize do
          list = @deadlines.select { |_, at| at <= now }.keys
          list.each { |f| @deadlines.delete(f) }
          list
        end
        due.each { |afi, safi| purge(afi, safi, 'refresh_stale_time') }
        due
      end

      # Why a request for afi and safi is not answered, or nil when it is.
      # RFC 2918 section 4: our OPEN had to carry the capability and the
      # family. An OPEN with no Multiprotocol capability carries IPv4
      # unicast, RFC 4760 section 8.
      def self.refusal(session_info, afi, safi)
        ours = session_info && session_info.speaker
        return 'no session' unless ours
        unless capabilities(ours).any? { |c| c.is_a?(BGP::OPT_PARM::CAP::Route_refresh) || c.is_a?(BGP::OPT_PARM::CAP::Enhanced_route_refresh) }
          return 'we did not advertise the Route Refresh capability'
        end
        return nil if EndOfRib.advertised(ours).include?([afi, safi])
        "we did not advertise AFI #{afi} SAFI #{safi}"
      end

      # True when the peer's OPEN carried the Enhanced Route Refresh
      # capability, 70: RFC 7313 section 4's procedures apply only then.
      def self.enhanced?(session_info)
        theirs = session_info && session_info.peer
        theirs ? capabilities(theirs).any? { |c| c.is_a?(BGP::OPT_PARM::CAP::Enhanced_route_refresh) } : false
      end

      # The [afi, safi] one UPDATE is about: IPv4 unicast for its own
      # fields, or its MP_REACH_NLRI's or MP_UNREACH_NLRI's.
      def self.family(update)
        return [1, 1] unless BGP::Update.blank?(update.nlri) && BGP::Update.blank?(update.withdrawn)
        pa = update.path_attribute
        mp = pa && ((pa.has?(BGP::Mp_reach) && pa[:mp_reach]) || (pa.has?(BGP::Mp_unreach) && pa[:mp_unreach]))
        mp ? [mp.afi, mp.safi] : [1, 1]
      end

      def self.capabilities(open)
        Array(open.opt_parms).flat_map { |p| p.respond_to?(:capabilities) ? Array(p.capabilities) : [p] }
      end

      private

      def end_of_rib_received?(afi, safi)
        Array(@peer.recorder.data['end_of_rib_received']).include?({ 'afi' => afi, 'safi' => safi })
      end

      def purge(afi, safi, why)
        @speaker.stale_family(@peer, afi, safi, :purge) do |n|
          event("#{why} for AFI #{afi} SAFI #{safi}: #{stale_count(n)} still stale removed",
                :purged => { :afi => afi, :safi => safi, :removed => n }, :reason => why)
        end
      end

      # A thread that purges what ran out, while any family waits.
      # It ends itself, under the lock, once nothing waits, so a BoRR
      # after that starts another.
      def watch
        @lock.synchronize do
          return if @watcher
          @watcher = Thread.new do
            loop do
              sleep 1
              expire
              done = @lock.synchronize do
                @watcher = nil if @deadlines.empty?
                @deadlines.empty?
              end
              break if done
            end
          end
        end
      end

      def ignore(afi, safi, why, level = :info)
        log(level, "bgp4r: #{@peer.address}: ROUTE-REFRESH for AFI #{afi} SAFI #{safi} ignored: #{why}")
        event("ROUTE-REFRESH for AFI #{afi} SAFI #{safi} ignored: #{why}",
              { :ignored => { :afi => afi, :safi => safi }, :reason => why }, level)
        nil
      end

      def stale_count(n)
        n.nil? ? 'no table holds this family, nothing' : n.to_s
      end

      def event(message, data, level = :info)
        @speaker.events.publish(:kind => KIND, :level => level, :peer => @peer.address, :message => message, :data => data)
      end

      def count(way, subtype)
        name = SUBTYPES.fetch(subtype || BGP::Route_refresh::NORMAL, 'other')
        @lock.synchronize { @counts[way][name] += 1 }
      end

      def publish(direction, msg)
        subtype = msg.subtype || BGP::Route_refresh::NORMAL
        name = SUBTYPES.fetch(subtype, subtype)
        @speaker.events.publish(:kind => KIND, :peer => @peer.address,
                                :message => "#{direction == 'send' ? 'Send' : 'Recv'} ROUTE-REFRESH #{name} AFI #{msg.afi} SAFI #{msg.safi}",
                                :data => { :direction => direction, :afi => msg.afi, :safi => msg.safi, :subtype => name })
      end

      def log(level, text)
        @speaker.send(:log, level, text)
      end
    end
  end
end
