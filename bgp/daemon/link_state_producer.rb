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
require 'bgp/daemon/link_state_table'
require 'bgp/daemon/link_state_sources'
require 'socket'
require 'io/wait'

module BGP
  module Daemon

    # A BGP-LS Producer: it reads an IGP's LSDB, isisd's or ospfd's, and
    # originates BGP-LS routes. RFC 9552 section 3: "The term BGP-LS
    # Producer refers to a BGP Speaker that is originating link-state
    # information into BGP."
    #
    # docs/design/bgp-ls-producer.md is the design, with
    # docs/design/bgp-ls-ospf.md for OSPF, and docs/bgp-ls-howto.md
    # explains it. One thread:
    #
    # 1. Subscribe to the IGP daemon's events.
    # 2. Read `show.topology` for each configured level (isisd) or area
    #    and the AS scope (ospfd), and build the routes.
    # 3. Compare with the routes already sent. Send what is new or
    #    changed in MP_REACH_NLRI, and what is gone in MP_UNREACH_NLRI.
    # 4. Wait for an event saying one of them changed: isisd's `spf` of
    #    a configured level, ospfd's `topology`. Go to 2.
    #
    # One IGP source per Producer: the block names `isisd` or `ospfd`.
    # The source objects are in link_state_sources.rb.
    #
    # If the socket closes, it tries again every RETRY seconds and keeps
    # what it sent, so the next read sends only what changed. A session
    # that comes up gets every route (`session_up`, from
    # `Speaker#on_established`).
    #
    # Only the peers in `peers` get BGP-LS, and only when the session
    # negotiated AFI 16388 / SAFI 71.
    class LinkStateProducer
      include BGP::Logging

      # The node file's `link_state:` keys. Any other is refused.
      KEYS = %w[isisd levels ospfd areas external identifier peers unreachable].freeze

      SOCKET = IsisSource::SOCKET
      RETRY = 5

      # RFC 9552 section 5.2, Table 2: "3 OSPFv2".
      OSPFV2 = 3

      # Section 5.2.3.1's route types, by ospfd's `route_type` name.
      ROUTE_TYPES = { 'intra' => 1, 'inter' => 2, 'external_1' => 3, 'external_2' => 4,
                      'nssa_1' => 5, 'nssa_2' => 6 }.freeze

      # `unreachable: withdraw`, the default, is RFC 9552 section 5.9's
      # SHOULD. `keep` is the MAY.
      UNREACHABLE = %w[withdraw keep].freeze

      # Octets of NLRI per UPDATE, well under RFC 4271's 4096-octet
      # message, with room for the other attributes.
      CHUNK = 3000

      T = BGP::Link_state::Tlv

      Sent = Struct.new(:nlri, :attribute, :since)

      attr_reader :source, :identifier, :peers, :last_error

      # config is the node file's `link_state:` block. arg[:connect] is a
      # callable that answers a connected IO, for a test; by default a
      # UNIXSocket on the source's path. ospfd's source calls it twice.
      # arg[:retry] is seconds between attempts.
      def initialize(speaker, config, arg = {})
        @speaker = speaker
        @logger = arg[:logger]
        read_config(config)
        @connect = arg[:connect] || -> { UNIXSocket.new(@source.path) }
        @retry = arg[:retry] || RETRY
        @lock = Mutex.new
        @sent = {} # NLRI octets => Sent
        @stopping = false
        @wake = ConditionVariable.new
        @wake_lock = Mutex.new
        @reads = 0
        @topologies = nil # the last `show.topology` answers it read
      end

      def path ; @source.path ; end
      def levels ; @source.is_a?(IsisSource) ? @source.levels : [] ; end
      def areas ; @source.is_a?(OspfSource) ? @source.areas : [] ; end

      # How many times it has read the topology and diffed it.
      def reads ; @lock.synchronize { @reads } ; end

      # `withdraw` or `keep`: what it does with a node the IGP marks
      # unreachable.
      def unreachable ; @lock.synchronize { @unreachable } ; end

      # Changes `unreachable` on a running Producer, and rebuilds at once
      # from the topology it last read, so the peers see the change now
      # and not at the next SPF: `withdraw` withdraws what an unreachable
      # node originated, and `keep` sends it again. Answers [announced,
      # withdrawn] as `refresh` does, or two empty lists before the
      # first read.
      #
      # **The rebuild holds the lock from the build to the send**, as
      # `refresh` does, so it cannot interleave with a read on the
      # Producer's thread and send a diff of an older topology after a
      # newer one.
      def set_unreachable(value)
        value = LinkStateProducer.unreachable(value)
        @lock.synchronize do
          @unreachable = value
          @topologies ? diff(@topologies) : [[], []]
        end
      end

      def unreachable=(value)
        set_unreachable(value)
      end

      # `withdraw` or `keep` as a String, or ArgumentError naming both.
      def self.unreachable(value)
        v = value.to_s
        raise ArgumentError, "link_state: unreachable is #{UNREACHABLE.join(' or ')}, not #{v}" unless UNREACHABLE.include?(v)
        v
      end

      def start
        @thread ||= Thread.new do
          Thread.current['name'] = 'BGP-LS producer'
          run
        end
        self
      end

      def stop
        @stopping = true
        @source.close rescue nil
        @wake_lock.synchronize { @wake.broadcast }
        @thread.join(2) if @thread
        self
      end

      # The routes as built from the topology answers, without sending
      # them: { NLRI octets => [Link_state, Link_state_attribute] }.
      # topologies is one `show.topology` answer per level, from isisd,
      # or per area and for the AS scope, from ospfd. Each answer says
      # which it is: `level`, `area` or `scope`.
      def build(topologies)
        out = {}
        topologies.each do |topo|
          Array(topo['nodes']).each do |node|
            next if node['reachable'] == false && @unreachable == 'withdraw'
            routes = if topo.key?('level')
                       LinkStateProducer.node_routes(node, Integer(topo['level']), @identifier)
                     else
                       LinkStateProducer.ospf_routes(node, topo['area'], @identifier)
                     end
            routes.each { |ls, attr| out[ls.encode] = [ls, attr] }
          end
        end
        out
      end

      # One read: build the routes, diff them against what was sent, and
      # send the difference to every peer that takes BGP-LS. Answers
      # [announced, withdrawn] as two lists of Link_state.
      def refresh(topologies)
        @lock.synchronize do
          @reads += 1
          @topologies = topologies
          diff(topologies)
        end
      end

      # The body of `refresh`, with the lock held: `build` reads
      # `@unreachable`, which `set_unreachable` changes under it.
      def diff(topologies)
        now = build(topologies)
        changed = now.reject { |k, (_ls, attr)| (s = @sent[k]) && s.attribute.encode == attr.encode }
        gone = @sent.keys - now.keys
        at = Time.now
        changed.each { |k, (ls, attr)| @sent[k] = Sent.new(ls, attr, at) }
        withdrawn = gone.collect { |k| @sent.delete(k).nlri }
        announced = changed.values.collect { |ls, attr| [ls, attr] }
        unless announced.empty? && withdrawn.empty?
          log(:info, "bgp-ls: #{announced.size} to announce, #{withdrawn.size} to withdraw")
          eligible.each { |p| send_to(p, announced, withdrawn) }
        end
        [announced.collect(&:first), withdrawn]
      end
      private :diff

      # A session came up: send it every route, if it takes BGP-LS.
      def session_up(peer)
        @lock.synchronize do
          next unless eligible?(peer)
          send_to(peer, @sent.values.collect { |s| [s.nlri, s.attribute] }, [])
        end
      end

      def size ; @lock.synchronize { @sent.size } ; end

      # What this speaker sent, as `show.link_state` rows with peer nil.
      def rows
        list = @lock.synchronize { @sent.values }
        LinkStateTable.sort(list.collect { |s| LinkStateTable.row(s.nlri, s.attribute, nil, s.since) })
      end

      # The peers this Producer sends to now: configured in `peers`,
      # Established, and negotiated 16388/71.
      def eligible
        @peers.filter_map { |a| @speaker.peer(a) }.select { |p| eligible?(p) }
      end

      def eligible?(peer)
        @peers.include?(peer.address) && peer.established? &&
          LinkStateTable.negotiated?(peer.session_info)
      end

      # The routes of one `show.topology` node, as [Link_state,
      # Link_state_attribute] pairs. pid is the Protocol-ID, which is the
      # IS-IS level: RFC 9552 section 5.2, Table 2, 1 for IS-IS Level 1
      # and 2 for Level 2.
      #
      # * One Node NLRI. Its attribute carries Node Flag Bits (1024), O
      #   for overload and A for attached; Node Name (1026) when there is
      #   a hostname; one IS-IS Area Identifier (1027) per area. The A
      #   bit is the table's, per erratum 7789 on section 5.3.1.1.
      # * One Link NLRI per neighbor, with IGP Metric (1095), 3 octets
      #   for a wide metric and 1 for a narrow one. Section 5.3.2.4:
      #   "IS-IS wide metrics have a length of 3 octets."
      # * One Prefix NLRI per IPv4 prefix, with Prefix Metric (1155).
      #
      # Phase 1 leaves out IPv6 prefixes, the link identifiers and
      # addresses (258 to 260), and every TE and SR TLV.
      def self.node_routes(node, pid, identifier)
        local = { :local_node_descriptors => [{ :igp_router_id => router_id(node.fetch('id')) }] }
        routes = []
        flags = []
        flags << :overload if node['overload']
        flags << :attached if node['attached']
        tlvs = [T::Node_flag_bits.new(*flags)]
        name = node['hostname'].to_s
        tlvs << T::Node_name.new(name) unless name.empty?
        Array(node['areas']).each { |a| tlvs << T::Isis_area_id.new(LinkStateTable.area_octets(a)) }
        routes << [BGP::Link_state.new(:node => head(pid, identifier, local)),
                   BGP::Link_state_attribute.new(*tlvs)]
        Array(node['neighbors']).each do |nb|
          remote = { :remote_node_descriptors => [{ :igp_router_id => router_id(nb.fetch('id')) }] }
          width = nb['style'] == 'narrow' ? 1 : 3
          routes << [BGP::Link_state.new(:link => head(pid, identifier, local, remote)),
                     BGP::Link_state_attribute.new(T::Igp_metric.new(Integer(nb.fetch('metric')), width))]
        end
        Array(node['prefixes']).each do |pf|
          prefix = pf.fetch('prefix').to_s
          next if prefix.include?(':')
          routes << [BGP::Link_state.new(:ipv4_prefix => head(pid, identifier, local, { :ip_reachability => prefix })),
                     BGP::Link_state_attribute.new(T::Prefix_metric.new(Integer(pf.fetch('metric', 0))))]
        end
        routes
      end

      # The routes of one ospfd `show.topology` node (ospfv2
      # docs/design/ospf-topology.md), as [Link_state,
      # Link_state_attribute] pairs. area is the answer's dotted quad, or
      # nil for the AS scope. The mapping is docs/design/bgp-ls-ospf.md's.
      #
      # * Protocol-ID 3 on every NLRI (Table 2: "3 OSPFv2").
      # * Node Descriptors: OSPF Area-ID (514), then IGP Router-ID
      #   (515), in ascending order (section 5.2.1.4: "MUST be arranged
      #   in ascending order"). 515 is the 4-octet Router-ID, or for a
      #   network node (a pseudonode) the DR's Router-ID and its
      #   interface address, 8 octets. No Area-ID for the AS scope: it
      #   "is not used for NLRIs when carrying information that is
      #   derived from AS-scope LSAs" (section 5.2.1.4).
      # * One Node NLRI for an area's node, with Node Flag Bits (1024): B
      #   for an ABR, E for an ASBR. No Node Name: ospfd has none.
      # * One Link NLRI per neighbor, with IPv4 interface (259) and
      #   neighbor (260) addresses when ospfd gives both, as section
      #   5.2.2 says they MUST be then. IGP Metric (1095) in 2 octets:
      #   "OSPF link metrics have a length of 2 octets" (5.3.2.4).
      # * One Prefix NLRI per IPv4 prefix: OSPF Route Type (264), then
      #   IP Reachability (265). Prefix Metric (1155), and the OSPF
      #   Forwarding Address (1156) when it is not 0.0.0.0.
      # * The AS scope gives prefixes only; its ASBR's Node NLRI comes
      #   from its area.
      def self.ospf_routes(node, area, identifier)
        local = { :local_node_descriptors => ospf_descriptors(node.fetch('id'), area) }
        routes = []
        if area
          flags = []
          flags << :abr if node['abr']
          flags << :external if node['asbr']
          routes << [BGP::Link_state.new(:node => head(OSPFV2, identifier, local)),
                     BGP::Link_state_attribute.new(T::Node_flag_bits.new(*flags))]
          Array(node['neighbors']).each do |nb|
            tlvs = [local, { :remote_node_descriptors => ospf_descriptors(nb.fetch('id'), area) }]
            if nb['address'] && nb['remote_address']
              tlvs << { :ipv4_interface_address => nb['address'] }
              tlvs << { :ipv4_neighbor_address => nb['remote_address'] }
            end
            routes << [BGP::Link_state.new(:link => head(OSPFV2, identifier, *tlvs)),
                       BGP::Link_state_attribute.new(T::Igp_metric.new(Integer(nb.fetch('metric')), 2))]
          end
        end
        Array(node['prefixes']).each do |pf|
          prefix = pf.fetch('prefix').to_s
          next if prefix.include?(':')
          tlvs = [local]
          type = ROUTE_TYPES[pf['route_type'].to_s]
          tlvs << { :ospf_route_type => type } if type
          tlvs << { :ip_reachability => prefix }
          attrs = [T::Prefix_metric.new(Integer(pf.fetch('metric', 0)))]
          fwd = pf['forwarding'].to_s
          attrs << T::Ospf_forwarding_address.new(fwd) unless fwd.empty? || fwd == '0.0.0.0'
          routes << [BGP::Link_state.new(:ipv4_prefix => head(OSPFV2, identifier, *tlvs)),
                     BGP::Link_state_attribute.new(*attrs)]
        end
        routes
      end

      # [{ospf_area_id}, {igp_router_id}], or the Router-ID alone with no
      # area.
      def self.ospf_descriptors(id, area)
        rid = { :igp_router_id => ospf_router_id(id) }
        area ? [{ :ospf_area_id => area }, rid] : [rid]
      end

      # ospfd's `10.255.0.2` as 4 octets of hex, and a network node's
      # `10.255.0.2:10.0.23.1`, the DR and its interface address, as 8
      # (section 5.2.1.4).
      def self.ospf_router_id(id)
        id.to_s.split(':').collect { |a| IPAddr.new(a).hton.unpack1('H*') }.join
      end

      def self.head(pid, identifier, *tlvs)
        { :protocol_id => pid, :identifier => identifier, :tlvs => tlvs }
      end

      # isisd's `0000.0001.0101.00` as the IGP Router-ID value of section
      # 5.2.1.4, in hex: the 6-octet system ID, or 7 octets when the
      # pseudonode octet is not zero.
      def self.router_id(id)
        h = id.to_s.delete('.')
        h.size == 14 && h.end_with?('00') ? h[0, 12] : h
      end

      private

      def read_config(config)
        raise ArgumentError, "link_state: is a block of #{KEYS.join(', ')}" unless config.is_a?(Hash)
        unknown = config.keys.map(&:to_s) - KEYS
        unless unknown.empty?
          raise ArgumentError, "link_state: unknown key(s) #{unknown.join(', ')}: use one of #{KEYS.join(', ')}"
        end
        @source = config.key?('ospfd') ? ospf_source(config) : isis_source(config)
        @identifier = Integer(config.fetch('identifier', 0))
        @peers = Array(config.fetch('peers', [])).collect(&:to_s)
        missing = @peers.reject { |a| @speaker.peer(a) }
        unless missing.empty?
          raise ArgumentError, "link_state: peers #{missing.join(', ')} are not configured neighbors"
        end
        @unreachable = LinkStateProducer.unreachable(config.fetch('unreachable', 'withdraw'))
      end

      # An absent source means isisd at its default path, so every phase
      # 1 and 2 file reads as before.
      def isis_source(config)
        %w[areas external].each do |k|
          raise ArgumentError, "link_state: #{k} goes with ospfd, not isisd" if config.key?(k)
        end
        levels = Array(config.fetch('levels', [1])).collect { |l| Integer(l) }
        bad = levels - [1, 2]
        raise ArgumentError, "link_state: levels are 1 and 2, not #{bad.join(', ')}" unless bad.empty?
        IsisSource.new(config.fetch('isisd', SOCKET).to_s, levels)
      end

      def ospf_source(config)
        raise ArgumentError, 'link_state: isisd or ospfd, not both: one IGP per Producer' if config.key?('isisd')
        raise ArgumentError, 'link_state: levels go with isisd, not ospfd' if config.key?('levels')
        areas = Array(config.fetch('areas', ['0.0.0.0'])).collect { |a| LinkStateProducer.area_id(a) }
        raise ArgumentError, 'link_state: areas is empty' if areas.empty?
        external = config.fetch('external', true)
        unless [true, false].include?(external)
          raise ArgumentError, "link_state: external is true or false, not #{external.inspect}"
        end
        OspfSource.new(config.fetch('ospfd', OspfSource::SOCKET).to_s, areas.uniq, external)
      end

      # An OSPF area as a dotted quad, given as one or as a number.
      def self.area_id(a)
        n = case a
            when Integer then a
            when /\A\d+\z/ then Integer(a, 10)
            when /\A\d{1,3}(\.\d{1,3}){3}\z/ then IPAddr.new(a).to_i
            end
        raise ArgumentError, "link_state: area #{a.inspect} is not a dotted quad or a number" unless n && n.between?(0, 0xffff_ffff)
        IPAddr.new(n, Socket::AF_INET).to_s
      rescue IPAddr::InvalidAddressError
        raise ArgumentError, "link_state: area #{a.inspect} is not a dotted quad or a number"
      end

      def send_to(peer, announced, withdrawn)
        updates(peer, announced, withdrawn).each { |u| peer.send_message(u) }
      rescue NoSession => e
        log(:warn, "bgp-ls: #{e.message}")
      end

      # The UPDATEs for one peer: the withdrawals, then one MP_REACH_NLRI
      # per BGP-LS Attribute, since the attribute applies to every NLRI
      # beside it.
      def updates(peer, announced, withdrawn)
        list = []
        chunks(withdrawn).each do |c|
          list << BGP::Update.new(BGP::Path_attribute.new(
            BGP::Mp_unreach.new(:afi => IANA::AFI::BGP_LS, :safi => IANA::SAFI::BGP_LS, :nlris => c)))
        end
        nexthop = peer.local_ip
        announced.group_by { |_ls, attr| attr.encode }.each_value do |pairs|
          attr = pairs.first[1]
          chunks(pairs.collect(&:first)).each do |c|
            list << BGP::Update.new(path_attribute(peer, nexthop, c, attr))
          end
        end
        list
      end

      # RFC 4271 section 5.1.2: empty AS_PATH toward an internal peer, our
      # AS toward an external one. LOCAL_PREF to an internal peer only
      # (section 5.1.5). The next hop is this session's address, which
      # RFC 9552 section 5.5 allows for either family.
      def path_attribute(peer, nexthop, nlris, attr)
        attrs = [BGP::Origin.new(0), BGP::As_path.new(*(peer.ebgp? ? [@speaker.my_as] : []))]
        attrs << BGP::Local_pref.new(100) unless peer.ebgp?
        attrs << BGP::Mp_reach.new(:afi => IANA::AFI::BGP_LS, :safi => IANA::SAFI::BGP_LS,
                                   :nexthop => [nexthop], :nlris => nlris)
        attrs << attr
        BGP::Path_attribute.new(*attrs)
      end

      def chunks(nlris)
        out, cur, size = [], [], 0
        nlris.each do |ls|
          n = ls.encode.bytesize
          if size + n > CHUNK && !cur.empty?
            out << cur
            cur, size = [], 0
          end
          cur << ls
          size += n
        end
        out << cur unless cur.empty?
        out
      end

      # json is required here and not at the top, as Speaker#write_state
      # does: the rescue below names JSON::ParserError.
      def run
        require 'json'
        until @stopping
          begin
            session
          rescue SystemCallError, IOError, Error, JSON::ParserError, KeyError, ArgumentError, TypeError => e
            @last_error = "#{e.class}: #{e.message}"
            log(:warn, "bgp-ls: #{@source.name} #{path}: #{e.message}; again in #{@retry}s") unless @stopping
          ensure
            @source.close
          end
          @wake_lock.synchronize { @wake.wait(@wake_lock, @retry) unless @stopping }
        end
      rescue StandardError => e
        log(:error, "bgp-ls: producer stopped: #{e.class}: #{e.message}")
      end

      # One connection to the IGP daemon (two for ospfd): subscribe, then
      # read and wait, until it closes.
      def session
        @source.open(@connect)
        @last_error = nil
        stopping = -> { @stopping }
        until @stopping
          refresh(@source.read)
          @source.wait(stopping) unless @source.dirty?
        end
      end
    end

  end
end
