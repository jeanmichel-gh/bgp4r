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

# One entry per class in the library that answers #to_hash: how to build
# one, whether its hash reads back, what it loses when it does not, and
# what has been decided about that.
#
# Not a test. to_hash_round_trip_test.rb asserts every declaration here,
# and docs/to-hash-round-trips.md is the same table for a reader.
#
# **Every verdict here is declared, not computed.** The test measures and
# compares. A verdict read off the library would assert nothing: it would
# agree with whatever the library happened to do, which is how a
# conformance column in this repo once carried two wrong rows for months.
#
# **A recipe has to exercise every field the class carries.** A thin one
# passes for the wrong reason, which is worse than no entry because it
# reads as verified. Three did while this file was being written.
# `Label_stack.new(100, 101)` round trips cleanly and says nothing about
# the Rsrv bits its hash drops, because that recipe never set them.
# `CAP::Orf.new(1, 1, [64, 3])` passed because those arguments quietly
# build a capability with no ORF entries in it at all. And
# `Mpls_label_stack.new(100, 200)` passed by both routes, while the same
# stack parsed off the wire with TC and TTL set loses both. Where a field
# can only arrive by parsing, the recipe parses.
#
# Recipes are taken from each class's own unit test wherever one builds
# the class already, so the octets are the ones the suite has always
# used, many of them captures from an RFC.

require 'bgp4r'
require 'bgp/orfs/orf'

module ToHashCatalog

  # There are two routes a hash can come back by, and a class can fail on
  # one and be fine on the other, in both directions.
  #
  # Its own `new` is one. The other is whatever actually reads these
  # hashes: `Path_attribute.new` for a path attribute,
  # `Extended_communities.new` for an extended community,
  # `Sub_tlv.from_hash` for a tunnel sub-TLV, `As_path.new` for a
  # segment, or the same list splatted back for an NLRI collection. For a
  # few classes nothing reads the hash at all, and there the other route
  # is the fields taken back out by hand, which proves the hash is
  # complete even though no door exists.
  #
  #   :ok        its own new rebuilds the same wire bytes.
  #   :elsewhere its own new does not, the other route does. The hash
  #              carries everything; what is missing is a door.
  #   :ok_alone  its own new does, the other route does not. Worse than
  #              it sounds: a hash key inherited from a parent class is
  #              the cause, and the attribute then rebuilds a different
  #              attribute without saying so.
  #   :lossy     no route gives the octets back. Information is gone.
  #
  # Whether a failing route raises or quietly answers something else is
  # in `loses` rather than in the verdict, because a verdict is meant to
  # say what a person gets. The quiet ones are the dangerous half and
  # every one of them says so.
  #
  # loses:    what the hash does not carry, or what stands in the way,
  #           for a verdict that is not :ok
  # decision: what is to be done, a key of DECISIONS
  # build:    a lambda giving one instance that exercises every field
  # via:      the other route, a lambda taking the to_hash and answering
  #           octets to compare against `encode`. Required for :elsewhere
  #           and :ok_alone. Optional on :lossy, where the test asserts
  #           it does *not* give the octets back, so the loss is measured
  #           by that route too rather than asserted by hand.
  Entry = Struct.new(:verdict, :loses, :decision, :build, :via)

  def self.entry(verdict, loses, decision, via = nil, &build)
    Entry.new(verdict, loses, decision, build, via)
  end

  DECISIONS = {
    nil   => 'nothing to decide, the round trip works',
    :fix  => 'to be fixed; cheap enough to be worth it',
    :keep => 'left as it is, deliberately; the reason is in the document',
  }.freeze

  VERDICT_WORDS = {
    :ok        => 'yes',
    :elsewhere => 'by another route',
    :ok_alone  => 'not in its attribute',
    :lossy     => 'no',
  }.freeze

  DECISION_WORDS = { nil => '--', :fix => 'fix', :keep => "won't fix" }.freeze

  # --- the other routes ------------------------------------------------

  # Every path attribute: the attribute set's own hash build path, which
  # is where an attribute hash is read in practice, since a test builds a
  # Path_attribute and not a lone attribute.
  PATH_ATTR = lambda { |h| BGP::Path_attribute.new(h).encode }

  # Every extended community: the collection attribute's hash build path,
  # where HASH_BUILDERS reads these. encode[3..] drops the attribute's
  # flags, type and length octets, leaving the value octets to compare.
  XTENDED = lambda do |h|
    BGP::Extended_communities.new(:extended_communities => [h]).encode[3..]
  end

  # Every AS_PATH segment, through the attribute that holds it.
  AS_SEG = lambda { |h| BGP::As_path.new(h).encode[3..] }

  # Every tunnel encapsulation sub-TLV. Sub_tlv.from_hash is the reader
  # the sub-TLV classes have and their own `new` does not call.
  SUB_TLV = lambda { |h| BGP::Tunnel_encap::Sub_tlv.from_hash(h).encode }

  def self.wire(hex) ; [hex].pack('H*').is_packed ; end

  # Every class in the library that answers #to_hash, which is the set
  # ENTRIES and NO_RECIPE together have to cover.
  #
  # The DYN_CAP classes are left out: capabilities.rb generates one bare
  # subclass per CAP class, overriding nothing, so each one's hash
  # behaviour is its parent's by construction.
  # to_hash_round_trip_test.rb asserts that construction rather than
  # measuring eleven more instances of the same answer.
  #
  # Measured over `require 'bgp4r'` and `require 'bgp/orfs/orf'`, which
  # was checked to give the same 98 classes as requiring every file under
  # bgp/, so this set does not depend on what else a suite has loaded.
  def self.classes_answering_to_hash
    found = {}
    walk = lambda do |mod|
      mod.constants(false).each do |c|
        begin ; v = mod.const_get(c) ; rescue StandardError ; next ; end
        next unless v.is_a?(Module)
        name = v.name or next
        next unless name.start_with?('BGP')
        next if found.key?(name)
        found[name] = v
        walk.call(v)
      end
    end
    walk.call(BGP)
    found.select do |name, k|
      k.is_a?(Class) && k.method_defined?(:to_hash) && !name.include?('DYN_CAP')
    end.keys
  end

  ENTRIES = {}

  # ====================================================================
  # Path attributes
  #
  # The pattern here is one thing: most of these nest their fields under
  # their own name, `{:aggregator => {...}}`, and their own `new` reads
  # the inner hash because that is the hash Path_attribute hands it. So
  # the attribute set is the door, and it works.
  # ====================================================================

  # Fixed: the Hash branch assigned the Symbol raw, skipping the
  # translation the Symbol branch already had, so the class could not read
  # back its own to_hash. An ORIGIN the RFC does not define now hashes as
  # its code rather than as :undefined, and any octet builds.
  ENTRIES['BGP::Origin'] = entry(:ok, nil, nil, PATH_ATTR) do
    BGP::Origin.new(:incomplete)
  end

  ENTRIES['BGP::Next_hop'] = entry(:ok, nil, nil) { BGP::Next_hop.new('10.0.0.1') }

  ENTRIES['BGP::Local_pref'] = entry(:ok, nil, nil) { BGP::Local_pref.new(0xdeadbeef) }

  ENTRIES['BGP::Multi_exit_disc'] = entry(:ok, nil, nil) do
    BGP::Multi_exit_disc.new(0xdeadbeef)
  end

  ENTRIES['BGP::Otc'] = entry(:ok, nil, nil) { BGP::Otc.new(64512) }

  ENTRIES['BGP::Originator_id'] = entry(
    :elsewhere,
    'nothing. new has no Hash branch at all, so the hash reaches ' \
    'IPAddr.create. The class has a new_hash that reads it.',
    :keep, PATH_ATTR) { BGP::Originator_id.new('10.0.0.1') }

  ENTRIES['BGP::Aggregator'] = entry(
    :elsewhere,
    'nothing. The fields nest under :aggregator and new reads the inner ' \
    'hash, so Path_attribute is the door.',
    :keep, PATH_ATTR) { BGP::Aggregator.new('10.0.0.1', 65001) }

  # RFC 6793 section 3: AS4_AGGREGATOR is always 4 octets. The hash key
  # is inherited, so the attribute set rebuilds the wrong attribute.
  # Fixed: it inherited Aggregator's :aggregator key, so Path_attribute
  # rebuilt a 2 octet AGGREGATOR and cut AS 4200000001 to 59905, in
  # silence. It writes :as4_aggregator now, which the registry already
  # read.
  ENTRIES['BGP::As4_aggregator'] = entry(
    :elsewhere,
    'nothing. Its own new reads the bare hash Aggregator takes, ' \
    ':asn and :address, so the wrapped form is the attribute set\'s to ' \
    'read, as with Aggregator itself.',
    :keep, PATH_ATTR) { BGP::As4_aggregator.new('2.2.2.2', 4200000001) }

  ENTRIES['BGP::As_path'] = entry(:ok, nil, nil) do
    BGP::As_path.new(BGP::As_path::Sequence.new(1, 2),
                     BGP::As_path::Set.new(3, 4),
                     BGP::As_path::Confed_sequence.new(5, 6),
                     BGP::As_path::Confed_set.new(7, 8))
  end

  # Fixed: it inherited As_path's :as_path key, so Path_attribute rebuilt
  # a type 2 AS_PATH in the 2 octet form and cut the AS numbers, in
  # silence, while a build straight from the hash went on working.
  # segments_from_hash already read either key, so :as4_path cost nothing.
  ENTRIES['BGP::As4_path'] = entry(:ok, nil, nil, PATH_ATTR) do
    BGP::As4_path.new(BGP::As_path::Sequence.new(4200000001, 2),
                      BGP::As_path::Set.new(4200000002))
  end

  { 'Sequence' => [3, 4], 'Set' => [1, 2],
    'Confed_sequence' => [5, 6], 'Confed_set' => [7, 8] }.each do |seg, ases|
    ENTRIES["BGP::As_path::#{seg}"] = entry(
      :elsewhere,
      'nothing. None of the four segment classes has a Hash branch, so ' \
      'the hash is stored as the one AS number and encode packs a Hash. ' \
      'As_path.segment_from_hash reads it correctly.',
      :keep, AS_SEG) { BGP::As_path.const_get(seg).new(*ases) }
  end

  # RFC 4271 section 4.3 gives it a zero length value, and to_hash is
  # {}, so merging it into an attribute set adds no key and the
  # attribute disappears.
  # Fixed: to_hash was {}, so merging it added no key and the attribute
  # vanished from a round tripped attribute set. It now writes the
  # :atomic_aggregate key the registry had taken all along.
  ENTRIES['BGP::Atomic_aggregate'] = entry(
    :elsewhere,
    'nothing. The attribute carries no value, so there is no bare hash ' \
    'for its own new to read and the attribute set is the only route. ' \
    'That route works now; it used to drop the attribute in silence.',
    :keep, PATH_ATTR) { BGP::Atomic_aggregate.new(wire('400600')) }

  ENTRIES['BGP::Aigp'] = entry(:ok, nil, nil) do
    BGP::Aigp.new(0x1f2f3f4f5f6f7f8f).add_tlv(9, "\x01\x02")
  end

  ENTRIES['BGP::Communities'] = entry(:ok, nil, nil) do
    BGP::Communities.new(wire('c0080a' + 'ffffff01' + '00010002' + 'abcd'))
  end

  ENTRIES['BGP::Cluster_list'] = entry(:ok, nil, nil) do
    BGP::Cluster_list.new(wire('800a09' + '0a0a0a0a' + '0b0b0b0b' + 'ff'))
  end

  ENTRIES['BGP::Large_communities'] = entry(:ok, nil, nil) do
    BGP::Large_communities.new(wire('c0201d' +
      '0000fbf0' + '00000001' + '00000002' +
      '0000fbf0' + 'ffffffff' + 'fffffffe' +
      '0102030405'))
  end

  ENTRIES['BGP::Mp_reach'] = entry(
    :elsewhere,
    'nothing. Everything nests under :mp_reach and set reads the inner ' \
    'hash. The unwrapped hash rebuilds all of it, next hop, RDs, labels ' \
    'and Path Identifiers included.',
    :keep, PATH_ATTR) do
    BGP::Mp_reach.new(:safi => 128, :nexthop => ['10.0.0.1'], :nlris => [
      { :rd => [100, 100], :prefix => '192.168.0.0/24', :label => 101, :path_id => 101 },
      { :rd => [100, 100], :prefix => '192.168.1.0/24', :label => 102, :path_id => 102 },
    ])
  end

  ENTRIES['BGP::Mp_unreach'] = entry(
    :elsewhere,
    'nothing. The same :mp_unreach wrapper as Mp_reach.',
    :keep, PATH_ATTR) do
    BGP::Mp_unreach.new(:safi => 1, :nlris => [
      { :prefix => '192.168.1.0/24', :path_id => 100 },
      { :prefix => '192.168.2.0/24', :path_id => 101 },
    ])
  end

  # Fixed: new read the three fields off the outer hash, where to_hash
  # had put them one level down in a one element :unknown list, so all
  # three were nil and 80c802ff00 came back as 000000, a different
  # attribute, with no error. It unwraps that list now.
  ENTRIES['BGP::Attr::Raw'] = entry(:ok, nil, nil, PATH_ATTR) do
    BGP::Attr::Raw.new(0x8, 200, "\xff\x00")
  end

  # Fixed with Attr::Raw, whose to_hash and Hash branch it inherits.
  ENTRIES['BGP::Attr::Unknown'] = entry(:ok, nil, nil, PATH_ATTR) do
    BGP::Attr::Unknown.new(0xc, 99, 0, 'x')
  end

  # The attribute set itself. ATOMIC_AGGREGATE disappearing was the
  # third loss here and is fixed, so the recipe is built from wire bytes
  # that exercise the two that remain: two attributes of one type, which
  # the one key per type hash collapses into one, and a trailing octet
  # after the last whole attribute, which has no key. Both are silent.
  #
  # Origin, two Communities 1:1 and 2:2, then one octet of tail. encode
  # gives these octets back exactly, so the recipe is faithful and the
  # loss is the hash's alone.
  ENTRIES['BGP::Path_attribute'] = entry(
    :lossy,
    'two things. A second attribute of a type already present, because ' \
    'the hash is one key per type, so two Communities collapse into the ' \
    'last one. And the tail parse_wire keeps after the last whole ' \
    'attribute, which has no key. Both silently.',
    :fix) do
    BGP::Path_attribute.new(wire('40010102' + 'c00804' + '00010001' +
                                 'c00804' + '00020002' + '40'))
  end

  # ====================================================================
  # Extended communities
  #
  # One pattern covers nearly the whole family: no individual community
  # class has a Hash branch, because these hashes are read by
  # Extended_communities through HASH_BUILDERS and nowhere else. The
  # information is all there. Nineteen of them rebuild byte for byte
  # through the collection, type octet, reserved bits and all.
  # ====================================================================

  ENTRIES['BGP::Extended_communities'] = entry(:ok, nil, nil) do
    BGP::Extended_communities.new(wire('c01019' +
      '0202000000640001' + '030cffffffff0008' + '8077000000000000' + 'ff'))
  end

  ENTRIES['BGP::Ipv6_extended_communities'] = entry(:ok, nil, nil) do
    BGP::Ipv6_extended_communities.new(wire('c01929' +
      '4002' + '20010db8000000000000000000000001' + '0064' +
      'ff09' + 'fe800000000000000000000000000001' + 'ffff' + 'ff'))
  end

  ENTRIES['BGP::Ipv6_extended_communities::Ipv6_extended_community'] =
    entry(:ok, nil, nil) do
      BGP::Ipv6_extended_communities::Ipv6_extended_community.new(
        9, 'fe80::1', 0xffff, :type => 0xff)
    end

  NO_HASH_BRANCH = 'nothing. No individual extended community class has ' \
    'a Hash branch; these hashes are read by Extended_communities ' \
    'through HASH_BUILDERS, which rebuilds this one byte for byte.'

  {
    'Route_target'            => '4102010101010064',
    'Route_origin'            => '4203000000640001',
    'Link_bandwidth'          => '00040064447a0000',
    'Bgp_data_collect'        => '4008fde800deadbe',
    'Ospf_domain_id'          => '0205000100020003',
    'Ospf_router_id'          => '0107010203040009',
    'Color'                   => '430b000000000064',
    'Origin_validation_state' => '0300000000000001',
    'Encapsulation'           => '030cffffffff0008',
    'Traffic_rate_bytes'      => 'c006000a447a0000',
    'Traffic_rate_packets'    => 'c00c000a447a0000',
    'Redirect'                => 'c008fde900000064',
    'Traffic_marking'         => '8009ffffffffffe0',
    'Mac_mobility'            => '0600ffff00000005',
    'Esi_label'               => '0601ffffff00064f',
    'Es_import'               => '4602aabbccddeeff',
    'Router_mac'              => '4603aabbccddeeff',
  }.each do |name, hex|
    ENTRIES["BGP::#{name}"] = entry(:elsewhere, NO_HASH_BRANCH, :keep, XTENDED) do
      BGP::const_get(name).new(wire(hex))
    end
  end

  ENTRIES['BGP::Extended_community::Unknown'] = entry(
    :elsewhere,
    'nothing. Its own new refuses {:unknown=>hex}, though it takes the ' \
    'bare hex string. The collection reads the hash.',
    :keep, XTENDED) { BGP::Extended_community::Unknown.new('8077000000000064') }

  # Fixed: its own new read :sample, :terminal and :bits off the outer
  # hash, found all three nil, and built a clean looking community
  # encoding 8007000000000000, losing all 48 value bits with no error. It
  # was the one community quiet where the others raise, because its field
  # defaults pass their own check. It unwraps its own key now.
  ENTRIES['BGP::Traffic_action'] = entry(:ok, nil, nil, XTENDED) do
    BGP::Traffic_action.new(wire('8007ffffffffffff'))
  end

  ENTRIES['BGP::Opaque'] = entry(
    :lossy,
    'the type octet and the sub-type. :opaque is not in HASH_BUILDERS ' \
    'either, so nothing reads this hash, and its value ' \
    "['0a0000010064', nil] cannot be fed back to a new that wants " \
    'type, sub-type and value.',
    :fix, XTENDED) do
    BGP::Opaque.new(BGP::ATTR::XTENDED_COMMUNITY::NON_TRANSITIVE, 10, '0a0000010064')
  end

  ENTRIES['BGP::Extended_community'] = entry(
    :lossy,
    'the type octet and the sub-type: the hash is {:extended_community ' \
    '=> [10, 20]} and that key is not in HASH_BUILDERS. This is the ' \
    'partial base class; a subclass is what a test builds.',
    :keep, XTENDED) { BGP::Extended_community.new(0x4002000a00000014) }

  # ====================================================================
  # Tunnel encapsulation, prefix SID, PMSI tunnel
  #
  # Two families. The sub-TLVs are the extended community story again:
  # Sub_tlv.from_hash reads them, their own new does not. The three path
  # attributes are the real losses, and four fields here have no key in
  # any hash at all.
  # ====================================================================

  NO_SUB_TLV_BRANCH = 'nothing. Its own new takes the hash where a field ' \
    'value belongs. Sub_tlv.from_hash is the reader and rebuilds it.'

  ENTRIES['BGP::Tunnel_encap::Ds_field'] = entry(
    :elsewhere, NO_SUB_TLV_BRANCH, :keep, SUB_TLV) do
    BGP::Tunnel_encap::Ds_field.new(46)
  end

  ENTRIES['BGP::Tunnel_encap::Embedded_label_handling'] = entry(
    :elsewhere, NO_SUB_TLV_BRANCH, :keep, SUB_TLV) do
    BGP::Tunnel_encap::Embedded_label_handling.new(2)
  end

  ENTRIES['BGP::Tunnel_encap::Protocol_type'] = entry(
    :elsewhere, NO_SUB_TLV_BRANCH, :keep, SUB_TLV) do
    BGP::Tunnel_encap::Protocol_type.new(0x0800)
  end

  ENTRIES['BGP::Tunnel_encap::Udp_dest_port'] = entry(
    :elsewhere, NO_SUB_TLV_BRANCH, :keep, SUB_TLV) do
    BGP::Tunnel_encap::Udp_dest_port.new(4789)
  end

  ENTRIES['BGP::Tunnel_encap::Sub_tlv'] = entry(
    :elsewhere, NO_SUB_TLV_BRANCH, :keep, SUB_TLV) do
    BGP::Tunnel_encap::Sub_tlv.new(200, "\x09\x0a".b)
  end

  # Fixed: its own new took the hash as the value octets and called to_s
  # on it, so the sub-TLV value became the 28 octets of
  # {:encapsulation=>"01020304"} as Ruby inspects it. On the wire, with
  # no error, while Sub_tlv.from_hash read the same hash correctly.
  ENTRIES['BGP::Tunnel_encap::Encapsulation'] = entry(:ok, nil, nil, SUB_TLV) do
    BGP::Tunnel_encap::Encapsulation.new([1, 2, 3, 4].pack('C4'))
  end

  ENTRIES['BGP::Tunnel_encap::Color'] = entry(
    :lossy,
    'the flags field. color_flags has no key in the hash, so flags ' \
    '0x1234 come back as 0000 even through Sub_tlv.from_hash.',
    :fix, SUB_TLV) { BGP::Tunnel_encap::Color.new(100, :flags => 0x1234) }

  ENTRIES['BGP::Tunnel_encap::Egress_endpoint'] = entry(
    :lossy,
    'the reserved field of RFC 9012 section 3.1. It has no key, so ' \
    '11223344 comes back as 00000000 by either route.',
    :fix, SUB_TLV) do
    BGP::Tunnel_encap::Egress_endpoint.new('10.0.0.1', :reserved => 0x11223344)
  end

  # RFC 9012 section 3.6 entries are label(20) TC(3) S(1) TTL(8). The
  # hash keeps the labels only, so a stack parsed off the wire loses TC
  # and TTL. new(100, 200) sets neither and would pass.
  ENTRIES['BGP::Tunnel_encap::Mpls_label_stack'] = entry(
    :lossy,
    'the TC and TTL octets. The hash is the label numbers only, so a ' \
    'stack read off the wire with TC 5 and TTL 64 comes back with both ' \
    'zeroed: 064a40 becomes 064000.',
    :fix, SUB_TLV) do
    BGP::Tunnel_encap::Mpls_label_stack.new(
      :value => [(100 << 12) | (5 << 9) | 64, (200 << 12) | 0x100 | 255].pack('NN'))
  end

  ENTRIES['BGP::Tunnel_encap::Tunnel'] = entry(
    :lossy,
    'the tail of a cut sub-TLV header. :tunnel_type, :sub_tlvs and the ' \
    ':length override all survive; @tail has no key. The Egress_endpoint ' \
    'reserved field goes with it, through the sub-TLV hash.',
    :fix) do
    BGP::Tunnel_encap::Tunnel.from_value(
      8, wire('060a' + '11223344' + '0001' + '0a000001' + '06')).length!(99)
  end

  ENTRIES['BGP::Tunnel_encap'] = entry(
    :lossy,
    'both tails, the attribute level one and the per tunnel one, plus ' \
    'the Egress_endpoint reserved field and the Color flags underneath. ' \
    '29 value octets rebuild as 26.',
    :fix, PATH_ATTR) do
    v = '00080016' + '060a' + '11223344' + '0001' + '0a000001' +
        '0408' + '030b1234' + '00000064' + '000800'
    BGP::Tunnel_encap.new(wire('c017' + format('%02x', v.length / 2) + v))
  end

  # Fixed: nothing read this hash, because new took it as the type and
  # pack raised. The hash always carried both fields.
  ENTRIES['BGP::Prefix_sid::Tlv'] = entry(:ok, nil, nil) do
    BGP::Prefix_sid::Tlv.new(9, "\x01\x02\x03".b)
  end

  # Fixed: the reserved octet of RFC 8669 section 3.1 and the flags of
  # sections 3.1 and 3.2 had no key, so a TLV read off the wire came back
  # zeroed. They go in the value rather than beside it, because
  # Prefix_sid#to_hash merges the known TLVs into one hash where two
  # :flags keys would collide, and an ordinary TLV hashes exactly as it
  # did before.
  ENTRIES['BGP::Prefix_sid::Label_index'] = entry(:ok, nil, nil) do
    BGP::Prefix_sid::Label_index.new(wire('0ac00000000064'))
  end

  # Fixed with Label_index. Its own new was quiet about it too: it read
  # the hash as one range, so hash[0].to_i was 0 and it built [0, 0].
  ENTRIES['BGP::Prefix_sid::Originator_srgb'] = entry(:ok, nil, nil) do
    BGP::Prefix_sid::Originator_srgb.new(wire('c0de003e800003e8'))
  end

  # Fixed: new read only the inner hash, so given its own to_hash it
  # found no key it knew and built an empty attribute, c02800, in
  # silence. It unwraps :prefix_sid now, and the two TLVs above carry
  # their own fields, so the whole attribute round trips: both TLVs with
  # reserved and flags set, and the tail of a cut TLV header.
  ENTRIES['BGP::Prefix_sid'] = entry(:ok, nil, nil, PATH_ATTR) do
    v = '010007' + '0ac00000000064' + '030008' + 'c0de003e800003e8' + '0100'
    BGP::Prefix_sid.new(wire('c028' + format('%02x', v.length / 2) + v))
  end

  ENTRIES['BGP::Pmsi_tunnel'] = entry(
    :lossy,
    'the other seven bits of the flags octet. to_hash writes :flags only ' \
    'when no leaf bit is set, so flags 0x41 hash as ' \
    ':leaf_info_required=>true alone and the RFC 7902 Extension bit is ' \
    'gone: 41 comes back as 01.',
    :fix, PATH_ATTR) do
    BGP::Pmsi_tunnel.new(:pim_ssm, ['10.0.0.1', '232.1.1.1'],
                         :label => 100, :flags => 0x41)
  end

  # ====================================================================
  # Outbound route filtering
  #
  # The clean corner of the library, and clean on the hard parts: the
  # :bits key for RFC 5291 section 4 reserved bits, the kept :value and a
  # :length that disagrees with its own octets.
  # ====================================================================

  ORF_ENTRY_TAIL = '00000001' + '18' + '20' + '18c0a801'

  ENTRIES['BGP::Prefix_entry'] = entry(:ok, nil, nil) do
    BGP::Prefix_entry.new(wire('3f' + ORF_ENTRY_TAIL))
  end

  ENTRIES['BGP::Prefix_orf'] = entry(:ok, nil, nil) do
    BGP::Prefix_orf.new(wire('820013' + '00' + ORF_ENTRY_TAIL + '4000000002'))
  end

  ENTRIES['BGP::Orf::Unknown'] = entry(:ok, nil, nil) do
    BGP::Orf::Unknown.new(wire('4100094243'))
  end

  # ====================================================================
  # NLRI encodings
  # ====================================================================

  # RFC 7911 section 3 Path Identifier, the prefix, and the tail a Length
  # field too wide for its family leaves over.
  PREFIX_WIRE = '00000064210102030405'

  ['Prefix', 'Inet_unicast', 'Inet_multicast'].each do |name|
    ENTRIES["BGP::#{name}"] = entry(:ok, nil, nil) do
      BGP::const_get(name).new_ntop_extended(wire(PREFIX_WIRE))
    end
  end

  ENTRIES['BGP::Rd'] = entry(:ok, nil, nil) { BGP::Rd.new(1, 257, 2) }

  ENTRIES['BGP::Label'] = entry(:ok, nil, nil) { BGP::Label.new(wire('00064e')) }

  # RFC 8277 section 2.2 gives each entry a 3 bit field bgp4r calls exp,
  # which the stack's hash drops. Two labels with exp 1 each.
  ENTRIES['BGP::Label_stack'] = entry(
    :lossy,
    'the 3 bit Rsrv field RFC 8277 section 2.2 puts above each label, ' \
    'which bgp4r calls exp. 000642000653 comes back as 000640000651. ' \
    'The Bottom of Stack bit goes the same way, though encode writes 0 ' \
    'for every entry above the bottom anyway. The @compatibility form is ' \
    'the one shape that does round trip.',
    :fix) { BGP::Label_stack.new(wire('000642000653')) }

  ENTRIES['BGP::Labeled'] = entry(
    :lossy,
    'the Path Identifier, and the label exp field with it. Label_stack ' \
    'writes :label for a one label stack where Labeled reads only ' \
    ':labels, so a single label stack builds empty and encode dies on ' \
    'nil; with two labels it builds and drops the Path Identifier, ' \
    'because new passes the prefix string alone to Prefix.new.',
    :fix) { BGP::Labeled.new_ntop(wire('200006430a'), 1, 1, 7) }

  ENTRIES['BGP::Vpn'] = entry(
    :elsewhere,
    'nothing. The hash carries :rd and :prefix, and both rebuild it, ' \
    'but new matches only String, Prefix and Rd so a Hash matches ' \
    'nothing and encode dies on @rd. The route here is the two fields ' \
    'handed back by hand, which is what proves the hash is complete.',
    :fix,
    lambda { |h| BGP::Vpn.new(h[:prefix], BGP::Rd.new(*h[:rd])).encode }) do
    BGP::Vpn.new('10.1.2.3/24', BGP::Rd.new('1.1.1.1', 1))
  end

  ENTRIES['BGP::Nlri'] = entry(
    :elsewhere,
    'nothing. The list has to be splatted: Nlri.new(*h[:nlris]) ' \
    'rebuilds it, where Nlri.new(h) sends the Hash to add, which has no ' \
    ':path_id key and hits a bare raise.',
    :keep,
    lambda { |h| BGP::Nlri.new(*h[:nlris]).encode }) do
    BGP::Nlri.new([100, '77.0.0.0/17'], '78.0.0.0/8', '0.0.0.0/0')
  end

  ENTRIES['BGP::Withdrawn'] = entry(
    :elsewhere,
    'nothing. The same splat as Nlri, under the :withdrawns key.',
    :keep,
    lambda { |h| BGP::Withdrawn.new(*h[:withdrawns]).encode }) do
    BGP::Withdrawn.new([5, '10.0.0.0/8'], '101.0.0.0/8', '0.0.0.0/0')
  end

  # ====================================================================
  # Messages
  # ====================================================================

  # RFC 9072 section 2 extended form, two capabilities, an Optional
  # Parameters Length that disagrees with its own octets, and a trailing
  # octet that is not a parameter.
  ENTRIES['BGP::Open'] = entry(:ok, nil, nil) do
    body = '04' + '0064' + '00b4' + '0a000001' + 'ff' + 'ff' + '0005' +
           '02' + '0002' + '0200' +
           '02' + '0006' + '41' + '04' + '00000064' + '41'
    BGP::Open.new(wire('ff' * 16 + format('%04x', 19 + body.size / 2) + '01' + body))
  end

  ENTRIES['BGP::Update'] = entry(:ok, nil, nil) do
    BGP::Update.new(
      BGP::Withdrawn.new([5, '10.0.0.0/8'], '101.0.0.0/8'),
      BGP::Path_attribute.new(
        BGP::Origin.new(1),
        BGP::Next_hop.new('192.168.1.5'),
        BGP::Multi_exit_disc.new(100),
        BGP::Local_pref.new(100),
        BGP::As_path.new(1, 2, 3)
      ),
      BGP::Nlri.new([100, '77.0.0.0/17'], '78.0.0.0/8'))
  end

  ENTRIES['BGP::Route_refresh'] = entry(:ok, nil, nil) do
    BGP::Route_refresh.new(2, 128, :eorr)
  end

  ENTRIES['BGP::Orf_route_refresh'] = entry(:ok, nil, nil) do
    body = '05' + '0002' + '00' + '80' + '02' +
           '41' + '0002' + 'aabb' +
           '40' + '0009' + '000000000a0000080a' + '41'
    BGP::Orf_route_refresh.new(
      wire('ff' * 16 + format('%04x', 19 + (body.size / 2) - 1) + body))
  end

  ENTRIES['BGP::Notification'] = entry(
    :elsewhere,
    'nothing. :code, :subcode and :data are all there and all rebuild ' \
    'it, but new has no Hash branch, so the hash becomes @code and ' \
    'encode raises in pack. The route here is the three fields handed ' \
    'back by hand, which is what proves the hash is complete.',
    :fix,
    lambda { |h| BGP::Notification.new(h[:code], h[:subcode], h[:data]).encode }) do
    BGP::Notification.new(6, 2, 'bye')
  end

  # ====================================================================
  # OPEN capabilities
  # ====================================================================

  ENTRIES['BGP::OPT_PARM::CAP::As4'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::As4.new(65001)
  end

  ENTRIES['BGP::OPT_PARM::CAP::Mbgp'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Mbgp.new(2, 128)
  end

  ENTRIES['BGP::OPT_PARM::CAP::Role'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Role.new(:customer)
  end

  ENTRIES['BGP::OPT_PARM::CAP::Extended_nexthop'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Extended_nexthop.new([1, 1, 2], [1, 128, 2])
  end

  # Each of these three keeps value octets no RFC gives it, and writes
  # them back, so the recipe gives it some.
  { 'Dynamic' => '02044302aabb',
    'Enhanced_route_refresh' => '02044602aabb',
    'Route_refresh' => '02048002aabb' }.each do |name, hex|
    ENTRIES["BGP::OPT_PARM::CAP::#{name}"] = entry(:ok, nil, nil) do
      BGP::OPT_PARM::CAP.const_get(name).new(wire(hex))
    end
  end

  ENTRIES['BGP::OPT_PARM::CAP::Unknown'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Unknown.new(100, 'value')
  end

  ENTRIES['BGP::OPT_PARM::Optional_parameter::Unknown'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::Optional_parameter::Unknown.new(wire('010901020000'))
  end

  ENTRIES['BGP::OPT_PARM::Capability'] = entry(
    :elsewhere,
    'nothing. One field, :code, and it rebuilds the capability, but new ' \
    'makes the Hash the code and encode raises. The route here is that ' \
    'field handed back by hand.',
    :keep,
    lambda { |h| BGP::OPT_PARM::Capability.new(h[:code]).encode }) do
    BGP::OPT_PARM::Capability.new(100)
  end

  ENTRIES['BGP::OPT_PARM::Capability::Unknown'] = entry(
    :lossy,
    'its value octets. It inherits Capability#to_hash, so the hash is ' \
    '{:code=>100} and the five octets it kept are gone. CAP::Unknown, ' \
    'the sibling one namespace down, has its own to_hash with :value ' \
    'and does round trip.',
    :fix) do
    BGP::OPT_PARM::Capability::Unknown.new(wire('0207640576616c7565'))
  end

  ENTRIES['BGP::OPT_PARM::CAP::Add_path'] = entry(
    :lossy,
    'every RFC 7911 section 4 <AFI, SAFI, Send/Receive> tuple. The hash ' \
    'is {:code=>69} whatever the capability holds.',
    :fix) do
    BGP::OPT_PARM::CAP::Add_path.new_array([[:send, 1, 1], [:recv, 2, 1], [3, 1, 128]])
  end

  ENTRIES['BGP::OPT_PARM::CAP::Graceful_restart'] = entry(
    :lossy,
    'the restart state, the restart time and every address family ' \
    'tuple. The hash is {:code=>64} whatever the capability holds.',
    :fix) do
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0x8, 120)
    gr.add(1, 1, 0x80)
    gr.add(2, 128, 0)
    gr
  end

  ENTRIES['BGP::OPT_PARM::CAP::Orf'] = entry(
    :lossy,
    'every ORF Entry. The hash is {:code=>3}, and new with a Hash ' \
    'quietly builds an empty capability, so 26 octets become 4. ' \
    "Orf::Entry has no to_hash at all and its own new has an empty " \
    'Hash branch.',
    :fix) do
    orf = BGP::OPT_PARM::CAP::Orf.new
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 1, [1, 1], [2, 1], [3, 1]))
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 2, [1, 1], [2, 1], [3, 1]))
    orf
  end

  # Classes with no entry, each with the reason. An abstract base with no
  # sensible instance belongs here; a class merely awkward to build does
  # not.
  NO_RECIPE = {
    'BGP::Extended_community::Typed' =>
      'an abstract base with no sensible instance. All three build ' \
      'paths fail inside it: TYPE and SUBTYPE are supplied only by ' \
      'subclasses, so a field or hash build raises NameError, and a ' \
      'wire build raises NoMethodError on parse_value. Its subclasses ' \
      'are measured instead.',
    'BGP::Tunnel_encap::Int_sub_tlv' =>
      'an abstract base with no sensible instance. Its initialize and ' \
      'to_hash read self.class::TYPE, SIZE, NAME and KEY and it ' \
      'defines none of them, so new(5) raises NameError. Its four ' \
      'concrete subclasses are measured instead.',
  }.freeze

end
