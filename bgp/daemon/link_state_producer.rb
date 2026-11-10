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
require 'socket'
require 'io/wait'

module BGP
  module Daemon

    # A BGP-LS Producer: it reads isisd's LSDB and originates BGP-LS
    # routes. RFC 9552 section 3: "The term BGP-LS Producer refers to a
    # BGP Speaker that is originating link-state information into BGP."
    #
    # docs/design/bgp-ls-producer.md is the design and
    # docs/bgp-ls-howto.md explains it. One thread:
    #
    # 1. Subscribe to isisd's events.
    # 2. Read `show.topology` for each configured level, and build the
    #    routes.
    # 3. Compare with the routes already sent. Send what is new or
    #    changed in MP_REACH_NLRI, and what is gone in MP_UNREACH_NLRI.
    # 4. Wait for an `spf` event of a configured level. Go to 2.
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
      KEYS = %w[isisd levels identifier peers unreachable].freeze

      SOCKET = '/run/isis4r/isisd.sock'
      RETRY = 5

      # `unreachable: withdraw`, the default, is RFC 9552 section 5.9's
      # SHOULD. `keep` is the MAY.
      UNREACHABLE = %w[withdraw keep].freeze

      # Octets of NLRI per UPDATE, well under RFC 4271's 4096-octet
      # message, with room for the other attributes.
      CHUNK = 3000

      T = BGP::Link_state::Tlv

      Sent = Struct.new(:nlri, :attribute, :since)

      class Error < StandardError ; end

      attr_reader :levels, :identifier, :peers, :path, :last_error

      # config is the node file's `link_state:` block. arg[:connect] is a
      # callable that answers a connected IO, for a test; by default a
      # UNIXSocket on `isisd`. arg[:retry] is seconds between attempts.
      def initialize(speaker, config, arg = {})
        @speaker = speaker
        @logger = arg[:logger]
        read_config(config)
        @connect = arg[:connect] || -> { UNIXSocket.new(@path) }
        @retry = arg[:retry] || RETRY
        @lock = Mutex.new
        @sent = {} # NLRI octets => Sent
        @stopping = false
        @wake = ConditionVariable.new
        @wake_lock = Mutex.new
        @id = 0
        @reads = 0
      end

      # How many times it has read the topology and diffed it.
      def reads ; @lock.synchronize { @reads } ; end

      def start
        @thread ||= Thread.new do
          Thread.current['name'] = 'BGP-LS producer'
          run
        end
        self
      end

      def stop
        @stopping = true
        sock = @sock
        sock.close if sock && !sock.closed? rescue nil
        @wake_lock.synchronize { @wake.broadcast }
        @thread.join(2) if @thread
        self
      end

      # The routes as built from the topology answers, without sending
      # them: { NLRI octets => [Link_state, Link_state_attribute] }.
      # topologies is one `show.topology` answer per level.
      def build(topologies)
        out = {}
        topologies.each do |topo|
          pid = Integer(topo.fetch('level'))
          Array(topo['nodes']).each do |node|
            next if node['reachable'] == false && @unreachable == 'withdraw'
            LinkStateProducer.node_routes(node, pid, @identifier).each do |ls, attr|
              out[ls.encode] = [ls, attr]
            end
          end
        end
        out
      end

      # One read: build the routes, diff them against what was sent, and
      # send the difference to every peer that takes BGP-LS. Answers
      # [announced, withdrawn] as two lists of Link_state.
      def refresh(topologies)
        now = build(topologies)
        @lock.synchronize do
          @reads += 1
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
      end

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
        @path = config.fetch('isisd', SOCKET).to_s
        @levels = Array(config.fetch('levels', [1])).collect { |l| Integer(l) }
        bad = @levels - [1, 2]
        raise ArgumentError, "link_state: levels are 1 and 2, not #{bad.join(', ')}" unless bad.empty?
        @identifier = Integer(config.fetch('identifier', 0))
        @peers = Array(config.fetch('peers', [])).collect(&:to_s)
        missing = @peers.reject { |a| @speaker.peer(a) }
        unless missing.empty?
          raise ArgumentError, "link_state: peers #{missing.join(', ')} are not configured neighbors"
        end
        @unreachable = config.fetch('unreachable', 'withdraw').to_s
        unless UNREACHABLE.include?(@unreachable)
          raise ArgumentError, "link_state: unreachable is #{UNREACHABLE.join(' or ')}, not #{@unreachable}"
        end
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
            log(:warn, "bgp-ls: isisd #{@path}: #{e.message}; again in #{@retry}s") unless @stopping
          ensure
            close
          end
          @wake_lock.synchronize { @wake.wait(@wake_lock, @retry) unless @stopping }
        end
      rescue StandardError => e
        log(:error, "bgp-ls: producer stopped: #{e.class}: #{e.message}")
      end

      # One connection to isisd: subscribe, then read and wait, until it
      # closes.
      def session
        @sock = @connect.call
        @dirty = false
        call('events.subscribe', {})
        @last_error = nil
        until @stopping
          @dirty = false
          refresh(@levels.collect { |l| call('show.topology', 'level' => l) })
          wait_for_spf unless @dirty
        end
      end

      def close
        s, @sock = @sock, nil
        s.close if s && !s.closed?
      rescue IOError
        nil
      end

      # Sends one request and reads lines until its answer. An event read
      # on the way is noted.
      def call(method, params)
        id = (@id += 1)
        @sock.write("#{JSON.generate('id' => id, 'method' => method, 'params' => params)}\n")
        loop do
          msg = next_message
          next note(msg) unless msg.key?('id')
          next unless msg['id'] == id
          raise Error, "#{method}: #{msg['error']}" if msg['error']
          return msg['result']
        end
      end

      # Reads until an `spf` event of a configured level, then a little
      # longer, so one change that runs SPF at both levels is one read.
      def wait_for_spf
        note(next_message) until @dirty || @stopping
        note(next_message) while !@stopping && @sock.wait_readable(0.1)
      end

      def next_message
        line = @sock.gets
        raise IOError, 'isisd closed the socket' if line.nil?
        msg = JSON.parse(line)
        raise Error, 'isisd sent a line that is not a JSON object' unless msg.is_a?(Hash)
        msg
      end

      # An `spf` event names its IS-IS level in its data, as `level`.
      def note(msg)
        ev = msg['event']
        return unless ev.is_a?(Hash) && ev['kind'] == 'spf'
        data = ev['data'].is_a?(Hash) ? ev['data'] : {}
        @dirty = true if @levels.include?(data['level'])
      end
    end

  end
end
