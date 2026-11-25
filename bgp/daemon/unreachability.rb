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

    # Unreachability Information in bgp4rd: what it reports and what it
    # is told, docs/design/unreachability.md pull request 3.
    #
    # Two drafts, one shape: draft-tantsura-idr-unreachability-safi-06
    # (AFI 1 and 2, SAFI 81) and draft-tantsura-bess-evpn-unreachability-02
    # (AFI 25, SAFI 70, route type 254, provisional).
    #
    # **Nothing here touches the RIB or the FIB.** Both drafts make that
    # their first MUST (SAFI section 4.2 items 1 and 2, EVPN section
    # 4.1): a report goes in a table of its own, `UnreachTable`, beside
    # `LinkStateTable`. bgp4rd reports and collects; it does not pass a
    # report on. Propagation, with the decision process and aggregation,
    # is a later phase with its own spec.
    module Unreach

      SAFI = IANA::SAFI::UNREACHABILITY_INFORMATION
      EVPN = [IANA::AFI::L2VPN, IANA::SAFI::EVPN].freeze
      ROUTE_TYPE = BGP::Evpn::Ip_prefix_unreachability.type

      # The families a session may carry reports in, as [afi, safi].
      FAMILIES = [[IANA::AFI::IPv4, SAFI], [IANA::AFI::IPv6, SAFI], EVPN].freeze

      # The event kind for a report that arrives, goes, is sent or is
      # cleared.
      KIND = BGP::Events.register_kind(:unreachability)

      # Reason codes by name for the configuration and the API, from the
      # draft's table: 'rpki_invalid' is 3. A number is taken as well.
      REASON_NAMES = BGP::Unreachability::EVPN_REASONS.to_h { |code, name|
        [name.downcase.gsub(/[^a-z0-9]+/, '_'), code]
      }.freeze

      # The [afi, safi] pairs both OPENs of a session carried, of the three.
      def self.families(session_info)
        return [] unless session_info
        FAMILIES.select do |f|
          [session_info.speaker, session_info.peer].all? { |open| mbgp?(open, f) }
        end
      end

      def self.mbgp?(open, family)
        return false unless open
        Array(open.opt_parms).flat_map { |p|
          p.respond_to?(:capabilities) ? Array(p.capabilities) : [p]
        }.any? { |c| c.is_a?(BGP::OPT_PARM::CAP::Mbgp) && [c.afi, c.safi] == family }
      end
      private_class_method :mbgp?

      def self.reason(v)
        return 0 if v.nil?
        return Integer(v) if v.is_a?(Integer) || v.to_s =~ /\A\d+\z/
        REASON_NAMES.fetch(v.to_s.downcase.tr('- ', '__')) do
          raise ArgumentError, "no reason is named #{v.inspect}; the names are " \
                               "#{REASON_NAMES.keys.join(', ')}, or a number"
        end
      end

      # 'A:N' or 'a.b.c.d:N' as Rd and Route_target take it.
      def self.pair(text)
        admin, assigned = text.to_s.split(':', 2)
        raise ArgumentError, "#{text.inspect} is not ADMIN:NUMBER" if assigned.nil?
        [admin.include?('.') ? admin : Integer(admin), Integer(assigned)]
      end

      # One report this speaker makes, from one entry of the
      # `unreachability:` block:
      #
      #   unreachability:
      #     - prefix: 192.0.2.0/24
      #       reason: rpki_invalid      # a name, or a number; 0 when left out
      #       timestamp: 1733789400     # Unix seconds; when it was loaded, if left out
      #     - prefix: 198.51.100.0/24
      #       reason: 9
      #       evpn: { rd: 198.51.100.1:100, route_targets: [65001:100], ethernet_tag: 0 }
      #
      # Without `evpn` it goes as SAFI 81, AFI 1 or 2 by the prefix. With
      # it, as EVPN route type 254.
      Report = Struct.new(:prefix, :reason, :timestamp, :rd, :route_targets,
                          :ethernet_tag, :evi) do

        def self.from_config(h, now = Time.now.to_i)
          raise ArgumentError, "an unreachability entry is a mapping, not #{h.inspect}" unless h.is_a?(Hash)
          h = h.to_h { |k, v| [k.to_s, v] }
          unknown = h.keys - %w[prefix reason timestamp evpn]
          raise ArgumentError, "unknown key(s) #{unknown.join(', ')} in an unreachability entry" unless unknown.empty?
          raise ArgumentError, 'an unreachability entry needs a prefix' unless h['prefix']
          prefix = normal_prefix(h['prefix'])
          ts = h['timestamp'].nil? ? now : Integer(h['timestamp'])
          raise ArgumentError, "a timestamp of #{ts} does not fit 8 octets" if ts && !(0..0xffff_ffff_ffff_ffff).include?(ts)
          e = h['evpn']
          if e.nil?
            new(prefix, Unreach.reason(h['reason']), ts, nil, [], nil, nil)
          else
            raise ArgumentError, "evpn is a mapping, not #{e.inspect}" unless e.is_a?(Hash)
            e = e.to_h { |k, v| [k.to_s, v] }
            unknown = e.keys - %w[rd route_targets ethernet_tag evi]
            raise ArgumentError, "unknown key(s) #{unknown.join(', ')} under evpn" unless unknown.empty?
            raise ArgumentError, 'evpn needs an rd' unless e['rd']
            Unreach.pair(e['rd'])
            rts = Array(e['route_targets']).collect(&:to_s)
            rts.each { |t| Unreach.pair(t) }
            new(prefix, Unreach.reason(h['reason']), ts, e['rd'].to_s, rts,
                Integer(e.fetch('ethernet_tag', 0)), e['evi'] && Integer(e['evi']))
          end
        end

        def self.normal_prefix(p)
          ip = IPAddr.new(p.to_s)
          len = p.to_s.include?('/') ? p.to_s.split('/').last.to_i : (ip.ipv6? ? 128 : 32)
          "#{ip.mask(len)}/#{len}"
        rescue IPAddr::Error
          raise ArgumentError, "#{p.inspect} is not a prefix"
        end

        def evpn? ; !rd.nil? ; end

        def afi ; prefix.include?(':') ? IANA::AFI::IPv6 : IANA::AFI::IPv4 ; end

        # The family it goes in, as FAMILIES names one.
        def family ; evpn? ? EVPN : [afi, SAFI] ; end

        # The draft's NLRI key: the prefix, and for EVPN the RD and the
        # Ethernet Tag. Two reports with one key are one report.
        def key ; [family, rd, ethernet_tag, prefix] ; end

        def family_name
          evpn? ? 'evpn' : (afi == IANA::AFI::IPv6 ? 'ipv6' : 'ipv4')
        end

        # The Reporter TLV, SAFI section 4.1: "The Reporting Speaker MUST
        # populate the Reporter TLV with its own BGP Identifier and AS
        # Number", with a Reason Code and a Timestamp, both SHOULDs.
        def reporter(router_id, my_as)
          u = BGP::Unreachability
          if evpn?
            subs = [u::Evpn_reason_code.new(reason), u::Timestamp.new(timestamp)]
            subs << u::Evi.new(evi) if evi
            u::Evpn_reporter.new(router_id, my_as, *subs)
          else
            u::Reporter.new(router_id, my_as, u::Reason_code.new(reason), u::Timestamp.new(timestamp))
          end
        end

        # The NLRI, an announcement with our reporter, or a withdrawal.
        def nlri(router_id, my_as, withdraw = false)
          reporters = withdraw ? [] : [reporter(router_id, my_as)]
          if evpn?
            BGP::Evpn.new(BGP::Evpn::Ip_prefix_unreachability.new(
              BGP::Rd.new(*Unreach.pair(rd)), nil, ethernet_tag, prefix, reporters))
          else
            BGP::Unreachability.new(prefix, *reporters)
          end
        end

        def to_config
          h = { 'prefix' => prefix, 'reason' => reason, 'timestamp' => timestamp }
          if evpn?
            e = { 'rd' => rd, 'route_targets' => route_targets, 'ethernet_tag' => ethernet_tag }
            e['evi'] = evi if evi
            h['evpn'] = e
          end
          h
        end
      end

      # Every report of a configuration, refusing two with one key.
      def self.reports(list, now = Time.now.to_i)
        reports = Array(list).collect { |h| Report.from_config(h, now) }
        dup = reports.group_by(&:key).find { |_, v| v.size > 1 }
        raise ArgumentError, "#{dup[1].first.prefix} is reported twice" if dup
        reports
      end

      # The key of a received NLRI: the family, and the draft's key fields.
      # SAFI section 3: "uniquely identified by the combination of Prefix
      # Length and Prefix". EVPN section 3.3: "Route Distinguisher,
      # Ethernet Tag ID, Address Family, IP Prefix Length, and IP Prefix".
      def self.key(afi, nlri)
        if nlri.is_a?(BGP::Evpn)
          r = nlri.route
          [EVPN, r.rd.encode, r.ethernet_tag_id.encode, r.address_family, r.prefix_len, r.prefix_octets]
        else
          [[afi, SAFI], nlri.mlen, nlri.prefix_octets]
        end
      end

      # What a receiver keeps of an NLRI's Reporter TLVs: those of type 1
      # that read as one, the first of each (Identifier, AS) (SAFI 3.4,
      # EVPN 3.5), at most 50 (SAFI 4.8) for SAFI 81. Unknown types are
      # skipped and malformed ones discarded (SAFI 5.3, EVPN 4.11.3).
      def self.kept_reporters(reporters, limit = BGP::Unreachability::MAX_REPORTERS)
        seen = {}
        list = reporters.select { |r| r.is_a?(BGP::Unreachability::Reporter) }
                        .reject { |r| seen.key?(r.key) || (seen[r.key] = false) }
        limit ? list.first(limit) : list
      end

      # A reporter as a row shows it.
      def self.reporter_row(r)
        name = r.sub_tlvs.find { |s| s.is_a?(BGP::Unreachability::Reason_code) }
        h = { 'identifier' => r.identifier, 'as' => r.as, 'reason' => r.reason,
              'reason_name' => name ? name.name : 'Unspecified',
              'timestamp' => r.timestamp && Recorder.iso(Time.at(r.timestamp)) }
        h['evi'] = r.evi if r.respond_to?(:evi) && r.evi
        h
      end

      # The ASes of an AS_PATH, AS4_PATH preferred, as Integers.
      def self.path_ases(pa)
        [BGP::As4_path, BGP::As_path].each do |k|
          next unless pa.has?(k)
          return pa[k].as_path.to_s.scan(/\d+/).collect(&:to_i)
        end
        []
      end

      # What one UPDATE asks the table to do, withdrawals first, and only
      # in the families the session negotiated:
      #
      #   [[:withdraw, key], [:announce, key, row_fields]]
      #
      # **The UPDATE's own findings decide first**, which the drafts ask
      # for (SAFI section 5, EVPN 4.11) and the lenient policy leaves to
      # the reader: a session reset or an AFI/SAFI disable takes nothing
      # from the UPDATE, and a treat-as-withdraw turns its announcements
      # into withdrawals (RFC 7606 section 2).
      def self.operations(update, families)
        pa = update.path_attribute
        return [] unless pa
        action = pa.action
        return [] if %i[session_reset afi_safi_disable].include?(action)
        ops = []
        each_nlri(pa, BGP::Mp_unreach, families) { |afi, n| ops << [:withdraw, key(afi, n)] }
        each_nlri(pa, BGP::Mp_reach, families) do |afi, n|
          if action == :treat_as_withdraw
            ops << [:withdraw, key(afi, n)]
          else
            ops << [:announce, key(afi, n), fields(afi, n, pa)]
          end
        end
        ops
      end

      def self.each_nlri(pa, klass, families)
        return unless pa.has?(klass)
        mp = pa[klass]
        fam = [mp.afi, mp.safi]
        return unless families.include?(fam)
        Array(mp.nlris).each do |n|
          if fam == EVPN
            yield mp.afi, n if n.is_a?(BGP::Evpn) && n.route.is_a?(BGP::Evpn::Ip_prefix_unreachability)
          elsif n.is_a?(BGP::Unreachability)
            yield mp.afi, n
          end
        end
      end
      private_class_method :each_nlri

      # The row fields of one received NLRI.
      def self.fields(afi, n, pa)
        ases = path_ases(pa)
        if n.is_a?(BGP::Evpn)
          r = n.route
          reporters = kept_reporters(r.reporters, nil)
          base = { 'family' => 'evpn', 'prefix' => r.ip_prefix,
                   'rd' => r.rd.to_s(false).sub(/\ARD=/, ''),
                   'ethernet_tag' => r.ethernet_tag_id.value }
          rts = pa.has?(BGP::Extended_communities) ?
            pa[BGP::Extended_communities].communities.grep(BGP::Route_target).collect { |c| c.to_hash[:route_target].join(':') } : []
          base['route_targets'] = rts
        else
          reporters = kept_reporters(n.reporters)
          base = { 'family' => afi == IANA::AFI::IPv6 ? 'ipv6' : 'ipv4', 'prefix' => n.prefix }
        end
        # SAFI section 7 item 5, EVPN section 7 item 4: "Implementations
        # SHOULD validate that Reporter AS Numbers in TLVs are consistent
        # with the AS_PATH of UPDATEs that introduced them." An empty
        # AS_PATH is an internal peer's; there the reporter can only be
        # in our own AS, which the row does not know, so it is not flagged.
        foreign = ases.empty? ? [] : reporters.collect(&:as).uniq - ases
        base.merge('reporters' => reporters.collect { |r| reporter_row(r) },
                   'as_path' => ases.join(' '),
                   'reporter_as_not_in_path' => foreign)
      end
    end

    # The reports a speaker received, per peer, outside the RIB.
    #
    # Keyed by peer and by the NLRI key (Unreach.key), so a later
    # announcement of one prefix replaces the earlier and a withdrawal
    # removes it. A session that leaves Established takes its reports
    # with it. Graceful Restart's stale marking is not built: bgp4rd
    # marks nothing stale for any family yet.
    class UnreachTable

      Entry = Struct.new(:fields, :since, :stale)

      def initialize(events: nil, logger: nil)
        @lock = Mutex.new
        @routes = {} # peer => { key => Entry }
        @events, @logger = events, logger
      end

      def attach(neighbor)
        feed = Feed.new(self, neighbor)
        neighbor.add_observer(feed)
        neighbor.on_state_change do |now, was|
          peer_down(neighbor.remote_addr) if was == :Established && now != was
        end
        feed
      end

      def detach(neighbor, feed)
        neighbor.delete_observer(feed)
        self
      end

      def apply(peer, ops, at = Time.now)
        changed = []
        @lock.synchronize do
          ops.each do |op, key, fields|
            case op
            when :withdraw
              e = delete(peer, key)
              changed << [:withdrawn, e.fields] if e
            when :announce
              (@routes[peer] ||= {})[key] = Entry.new(fields, at)
              changed << [:received, fields]
            end
          end
        end
        changed.each { |what, f| publish(peer, what, f) }
        self
      end

      def peer_down(peer)
        @lock.synchronize { @routes.delete(peer) }
        self
      end

      def size(peer = nil)
        @lock.synchronize { peer ? (@routes[peer] || {}).size : @routes.values.sum(&:size) }
      end

      # Marks stale the reports of one family from peer, as a BoRR asks
      # (RFC 7313 section 4). The key's first element is the family.
      # Returns how many were marked.
      def mark_stale(peer, family, reason = 'refresh')
        @lock.synchronize do
          (@routes[peer] || {}).select { |k, _| k.first == family }.each_value { |e| e.stale = reason }.size
        end
      end

      # How many reports from peer are marked stale.
      def stale_size(peer)
        @lock.synchronize { (@routes[peer] || {}).each_value.count(&:stale) }
      end

      # Removes the reports of that family still stale from peer, as an
      # EoRR asks, each published as withdrawn. Returns how many went.
      def purge_stale(peer, family)
        gone = @lock.synchronize do
          h = @routes[peer] or next []
          keys = h.select { |k, e| k.first == family && e.stale }.keys
          keys.collect { |k| delete(peer, k) }
        end
        gone.each { |e| publish(peer, :withdrawn, e.fields) }
        gone.size
      end

      def rows
        @lock.synchronize do
          @routes.flat_map do |peer, h|
            h.values.collect do |e|
              row = { 'peer' => peer }.merge(e.fields).merge('since' => Recorder.iso(e.since))
              e.stale ? row.merge('stale' => e.stale) : row
            end
          end
        end
      end

      private

      def delete(peer, key)
        h = @routes[peer]
        return nil unless h
        e = h.delete(key)
        @routes.delete(peer) if h.empty?
        e
      end

      def publish(peer, what, f)
        return unless @events
        first = Array(f['reporters']).first
        reason = first ? " (#{first['reason_name']})" : ''
        @events.publish(:kind => Unreach::KIND, :peer => peer,
                        :message => "unreachability #{what} from #{peer}: #{f['prefix']}#{reason}",
                        :data => { 'event' => what.to_s }.merge(f))
        unless Array(f['reporter_as_not_in_path']).empty?
          @logger&.call(:warn, "unreachability: #{f['prefix']} from #{peer} names reporter AS " \
                               "#{f['reporter_as_not_in_path'].join(', ')}, not in its AS_PATH " \
                               "#{f['as_path']} (draft-tantsura-idr-unreachability-safi section 7)")
        end
      end

      class Feed
        def initialize(table, neighbor)
          @table, @neighbor = table, neighbor
        end

        def update(msg)
          return unless msg.is_a?(BGP::Update)
          families = Unreach.families(@neighbor.session_info)
          return if families.empty?
          ops = Unreach.operations(msg, families)
          @table.apply(@neighbor.remote_addr, ops) unless ops.empty?
        end
      end
    end

    # The reports this speaker makes, from the `unreachability:` block,
    # sent to every peer that negotiated the family.
    #
    # VpnExporter's shape: keep what was sent; on each refresh send what
    # is new or changed and withdraw what went, to every established
    # peer; on a session coming up, send it all.
    class UnreachOriginator

      PER_UPDATE = 100

      Sent = Struct.new(:report, :since)

      def initialize(speaker, logger: nil)
        @speaker, @logger = speaker, logger
        @lock = Mutex.new
        @sent = {} # key => Sent
      end

      # The reports a configuration asks for. Answers [announced, withdrawn].
      #
      # An entry with no timestamp keeps the one it was first sent with,
      # as long as nothing else about it changed, so a commit of some
      # other key does not send every report again with a new time.
      def refresh(list, now = Time.now.to_i)
        reports = Unreach.reports(list, nil)
        @lock.synchronize do
          reports = reports.collect do |r|
            next r if r.timestamp
            s = @sent[r.key]
            same = s && s.report.to_a.each_with_index.all? { |v, i| i == 2 || v == r.to_a[i] }
            r.dup.tap { |x| x.timestamp = same ? s.report.timestamp : now }
          end
          wanted = reports.to_h { |r| [r.key, r] }
          changed = wanted.values.reject { |r| (s = @sent[r.key]) && s.report == r }
          gone = (@sent.keys - wanted.keys).collect { |k| @sent.delete(k).report }
          at = Time.now
          changed.each { |r| @sent[r.key] = Sent.new(r, at) }
          unless changed.empty? && gone.empty?
            log(:info, "unreachability: #{changed.size} report(s) to send, #{gone.size} to withdraw")
            @speaker.peers.each { |p| send_to(p, changed, gone) }
            changed.each { |r| publish(r, 'reported') }
            gone.each { |r| publish(r, 'cleared') }
          end
          [changed, gone]
        end
      end

      def session_up(peer)
        @lock.synchronize { send_to(peer, @sent.values.collect(&:report), []) }
      end

      # A route refresh for one family, [afi, safi], RFC 2918 section 4:
      # the reports of that family, again. bgp/daemon/refresh.rb.
      def resend(peer, family)
        @lock.synchronize { send_to(peer, @sent.values.collect(&:report).select { |r| r.family == family }, []) }
      end

      def size ; @lock.synchronize { @sent.size } ; end

      def reports ; @lock.synchronize { @sent.values.collect(&:report) } ; end

      def rows
        @lock.synchronize do
          @sent.values.collect do |s|
            r = s.report
            row = { 'peer' => nil, 'family' => r.family_name, 'prefix' => r.prefix }
            if r.evpn?
              row.merge!('rd' => r.rd, 'ethernet_tag' => r.ethernet_tag,
                         'route_targets' => r.route_targets)
            end
            row.merge('reporters' => [Unreach.reporter_row(r.reporter(@speaker.router_id, @speaker.my_as))],
                      'as_path' => '', 'reporter_as_not_in_path' => [],
                      'since' => Recorder.iso(s.since))
          end
        end
      end

      # The UPDATEs that send announced and withdraw withdrawn to peer.
      def updates(peer, announced, withdrawn)
        list = []
        rid, as = @speaker.router_id, @speaker.my_as
        withdrawn.group_by(&:family).each do |fam, rs|
          rs.each_slice(PER_UPDATE) do |c|
            nlris = c.collect { |r| r.nlri(rid, as, true) }
            mp = BGP::Mp_unreach.new(:afi => fam[0], :safi => fam[1], :nlris => nlris)
            list << BGP::Update.new(BGP::Path_attribute.new(mp))
          end
        end
        announced.group_by { |r| [r.family, r.route_targets] }.each do |(fam, rts), rs|
          rs.each_slice(per_update(fam)) do |c|
            list << BGP::Update.new(path_attribute(peer, fam, rts, c.collect { |r| r.nlri(rid, as) }))
          end
        end
        list
      end

      private

      # An EVPN route of 254 is at most 257 octets with its framing, so a
      # 4096-octet UPDATE holds about fifteen; SAFI 81's with one reporter
      # are near 35.
      def per_update(fam)
        fam == Unreach::EVPN ? 10 : PER_UPDATE
      end

      def send_to(peer, announced, withdrawn)
        return unless peer.established?
        ok = Unreach.families(peer.session_info)
        announced = announced.select { |r| ok.include?(r.family) }
        withdrawn = withdrawn.select { |r| ok.include?(r.family) }
        return if announced.empty? && withdrawn.empty?
        updates(peer, announced, withdrawn).each { |u| peer.send_message(u) }
      rescue StandardError => e
        log(:warn, "unreachability: sending to #{peer.address}: #{e.class}: #{e.message}")
      end

      # SAFI section 4.6 and EVPN section 4.10: "ORIGIN SHOULD be set to
      # INCOMPLETE for locally generated information". SAFI 81 has no next
      # hop (Appendix B.1, Next Hop Length 0); EVPN's is ours, as its
      # Example 4.
      def path_attribute(peer, fam, rts, nlris)
        path = peer.ebgp? ? [@speaker.my_as] : []
        attrs = [BGP::Origin.new(2), BGP::As_path.new(*path)]
        attrs << BGP::Local_pref.new(100) unless peer.ebgp?
        if fam == Unreach::EVPN
          nh = (@speaker.local_address || peer.local_ip).to_s
          attrs << BGP::Mp_reach.new(:afi => fam[0], :safi => fam[1], :nexthop => [nh], :nlris => nlris)
          targets = rts.collect { |t| BGP::Route_target.new(*Unreach.pair(t)) }
          attrs << BGP::Extended_communities.new(*targets) unless targets.empty?
        else
          attrs << BGP::Mp_reach.new(:afi => fam[0], :safi => fam[1], :nlris => nlris)
        end
        BGP::Path_attribute.new(*attrs)
      end

      def publish(r, what)
        ev = @speaker.events
        return unless ev
        ev.publish(:kind => Unreach::KIND,
                   :message => "unreachability #{what}: #{r.prefix} (#{BGP::Unreachability.reason_name(r.reason)})",
                   :data => { 'event' => what, 'family' => r.family_name, 'prefix' => r.prefix,
                              'rd' => r.rd, 'reason' => r.reason })
      end

      def log(level, msg)
        @logger&.call(level, msg)
      end
    end

  end
end
