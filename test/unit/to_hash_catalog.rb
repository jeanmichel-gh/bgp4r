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
# and rake to_hash:status prints them for a reader. This file is the only
# record: there is deliberately no document holding a second copy, since
# the one that did spent four pull requests out of date in its prose
# while its generated table stayed true.
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
    :keep => 'left as it is, deliberately; the reason is on the entry',
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

  # The attribute set itself, and all three of its losses are closed:
  # ATOMIC_AGGREGATE disappearing, the kept tail, and two attributes of
  # one type collapsing into the last. The recipe is the third, since it
  # was the one that outlived a shape argument: Origin and two
  # Communities, 1:1 and 2:2, where the hash carries the second
  # occurrence under DUP_KEY and new builds it after the distinct types.
  #
  # A repeat that arrived before a type it does not repeat comes back in
  # that same order rather than its own, so its octets differ while
  # every attribute survives. Nothing in BGP orders path attributes, and
  # Path_attribute#<=> says so by sorting each side before comparing, so
  # that is normalising and not a loss. It is measured in
  # path_attribute_test.rb, which asserts the surviving set, because a
  # catalog recipe can only ask for the octets back.
  ENTRIES['BGP::Path_attribute'] = entry(:ok, nil, nil) do
    BGP::Path_attribute.new(wire('40010102' + 'c00804' + '00010001' +
                                 'c00804' + '00020002'))
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

  # Fixed: it inherited Capability's bare {:code=>69}, so every RFC 7911
  # section 4 <AFI, SAFI, Send/Receive> triple was lost, and a Hash fell
  # to a bare raise in new. Capability.from_hash refused this code by
  # name; it builds it now.
  ENTRIES['BGP::OPT_PARM::CAP::Add_path'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Add_path.new_array([[:send, 1, 1], [:recv, 2, 1], [3, 1, 128]])
  end

  # Fixed with Add_path, and for the same reason: Capability's bare
  # {:code=>64} lost the restart state, the restart time and every
  # family together, and a Hash went to parse, which called slice! on it.
  # The recipe sets the RFC 4724 section 3 Restart State bit, a restart
  # time, and a family with the Forwarding State bit set.
  ENTRIES['BGP::OPT_PARM::CAP::Graceful_restart'] = entry(:ok, nil, nil) do
    gr = BGP::OPT_PARM::CAP::Graceful_restart.new(0x8, 120)
    gr.add(1, 1, 0x80)
    gr.add(2, 128, 0)
    gr
  end

  ENTRIES['BGP::OPT_PARM::CAP::Orf'] = entry(:ok, nil, nil) do
    orf = BGP::OPT_PARM::CAP::Orf.new
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 1, [1, 1], [2, 1], [3, 1]))
    orf.add(BGP::OPT_PARM::CAP::Orf::Entry.new(1, 2, [1, 1], [2, 1], [3, 1]))
    orf
  end

  # New here, because the fix above gave Entry a to_hash it never had, and
  # the completeness guard asked for it the moment it did. Built off the
  # wire so the RFC 5291 section 5 Reserved octet is set: encode used to
  # write 0 for it whatever arrived, so a captured capability could not be
  # sent again. The hash carries it only when it is not 0.
  ENTRIES['BGP::OPT_PARM::CAP::Orf::Entry'] = entry(:ok, nil, nil) do
    BGP::OPT_PARM::CAP::Orf::Entry.new(wire('0001ff01014001'))
  end

  # ====================================================================
  # Flow Specification components
  # ====================================================================

  # RFC 8955 section 4.2.2 and RFC 8956 section 3. Every one of these
  # round trips, which is not luck: the hash shape was written against
  # these classes rather than inherited from an older one, so there is no
  # field here that entered the object after the hash was settled, which
  # is the root cause behind every lossy row above.
  #
  # The recipes exercise every field, and for an operator component that
  # means more than the pairs: the AND bit of RFC 8955 section 4.2.1.1, a
  # value too wide for one octet, a last pair with no end-of-list bit,
  # the reserved bit that section says "MUST be set to 0 on NLRI
  # encoding", and the tail of a pair whose value field overran. All five
  # are reachable from values as well as from the wire, so these build
  # from values; nothing here arrives only by parsing.

  # An operator component recipe. The three pairs read ">= 137", "AND <=
  # 139 with the reserved bit set" and "== 8080 without the end-of-list
  # bit", and then four octets that cannot be a whole pair.
  FS_NUMERIC = lambda do |k|
    k.new([:ge, 137],
          { :op => :and_le, :value => 139, :reserved => 8 },
          { :op => :eq, :value => 8080, :eol => false },
          { :tail => '1100' })
  end

  # The same for a bitmask component, whose low two bits are (not << 1) |
  # m per RFC 8955 section 4.2.1.2 and whose reserved field is two bits
  # rather than one.
  FS_BITMASK = lambda do |k|
    k.new([:match, 0x02],
          { :op => :and_not_any, :value => 0x05, :reserved => 12 },
          { :op => :any, :value => 0x08, :eol => false },
          { :tail => '1100' })
  end

  { 'Ip_protocol' => 3, 'Upper_layer_protocol' => 3, 'Port' => 4,
    'Destination_port' => 5, 'Source_port' => 6, 'Icmp_type' => 7,
    'Icmpv6_type' => 7, 'Icmp_code' => 8, 'Icmpv6_code' => 8,
    'Packet_length' => 10, 'Dscp' => 11, 'Flow_label' => 13,
  }.each_key do |name|
    k = BGP::Flow_spec.const_get(name)
    ENTRIES["BGP::Flow_spec::#{name}"] = entry(:ok, nil, nil) { FS_NUMERIC.call(k) }
  end

  %w[Tcp_flags Fragment Ipv6_fragment].each do |name|
    k = BGP::Flow_spec.const_get(name)
    ENTRIES["BGP::Flow_spec::#{name}"] = entry(:ok, nil, nil) { FS_BITMASK.call(k) }
  end

  # RFC 8955 section 4.2.2.1: "<type (1 octet), length (1 octet), prefix
  # (variable)>", and the prefix is all the class carries.
  ENTRIES['BGP::Flow_spec::Destination_prefix'] = entry(:ok, nil, nil) do
    BGP::Flow_spec::Destination_prefix.new('192.0.2.0/24')
  end

  ENTRIES['BGP::Flow_spec::Source_prefix'] = entry(:ok, nil, nil) do
    BGP::Flow_spec::Source_prefix.new('203.0.113.0/24')
  end

  # RFC 8956 section 3.1 adds an offset octet and padding, so those are
  # the two fields the IPv4 classes have not got. The padding only exists
  # where length minus offset is not a whole octet, which is why this is
  # section 3.8.2's 39 bit pattern and not section 3.8.1's 40 bit one.
  ENTRIES['BGP::Flow_spec::Destination_ipv6_prefix'] = entry(:ok, nil, nil) do
    BGP::Flow_spec::Destination_ipv6_prefix.new('2001:db8::/32')
  end

  ENTRIES['BGP::Flow_spec::Source_ipv6_prefix'] = entry(:ok, nil, nil) do
    BGP::Flow_spec::Source_ipv6_prefix.new(
      :prefix => '::1234:5678:9a00:0/65-104', :padding => 1)
  end

  # The fifth keep-what-you-cannot-read class. It holds a type octet and
  # the rest of the NLRI value, and both are in the hash.
  ENTRIES['BGP::Flow_spec::Unknown'] = entry(:ok, nil, nil) do
    BGP::Flow_spec::Unknown.new(99, "\x01\x02\x03\x04\x05")
  end

  # The NLRI that carries them, RFC 8955 section 4. Six fields, and the
  # recipe exercises all six, since Conventions says a thin recipe
  # passes for the wrong reason: the component list, the section 8 Route
  # Distinguisher, the RFC 7911 section 3 Path Identifier, a repeated
  # component type under :duplicates, a Length that disagrees with its
  # own octets, and a kept tail.
  #
  # Every one is reachable from values as well as from the wire, so this
  # builds from values. The AFI is not a field: it is a parse time
  # question, and the hash carries it implicitly because the six shared
  # type numbers have a key each per family.
  ENTRIES['BGP::Flow_spec'] = entry(:ok, nil, nil) do
    BGP::Flow_spec.new(:path_id => 100, :rd => [100, 200],
                       :destination_prefix => '192.0.2.0/24',
                       :port => [[:eq, 25]],
                       :duplicates => [{ :port => [[:eq, 80]] }],
                       :length => 99,
                       :tail => 'deadbeef')
  end

  # The EVPN primitives, RFC 7432 sections 5 and 7. Each recipe
  # exercises every field the class carries, which for the two Sized
  # subclasses is the bit count as well as the value, since a length
  # that disagrees with its octets is the interesting case and the one a
  # thin recipe would miss.
  #
  # All five are :ok and that is not luck. These classes were written
  # after the hash shape was understood, so no field here entered the
  # object later than its hash, which is the one sentence behind every
  # lossy row above.
  ENTRIES['BGP::Evpn::Esi'] = entry(:ok, nil, nil) do
    BGP::Evpn::Esi.new(1, '001122334455667788')
  end

  ENTRIES['BGP::Evpn::Ethernet_tag_id'] = entry(:ok, nil, nil) do
    BGP::Evpn::Ethernet_tag_id.new(0xffffffff)
  end

  # A bit count of 24 against six octets, which is the lie the field is
  # allowed to tell: RFC 7432 section 7.2 fixes the MAC at six octets
  # and puts its length in bits, so the two can disagree.
  ENTRIES['BGP::Evpn::Mac_addr'] = entry(:ok, nil, nil) do
    BGP::Evpn::Mac_addr.new(24, ['001122334455'].pack('H*'))
  end

  # The same for the IP Address, whose width does follow its length, so
  # a count of 24 means three octets here rather than six.
  ENTRIES['BGP::Evpn::Addr'] = entry(:ok, nil, nil) do
    BGP::Evpn::Addr.new(24, ['c00002'].pack('H*'))
  end

  ENTRIES['BGP::Evpn::Unknown'] = entry(:ok, nil, nil) do
    BGP::Evpn::Unknown.new(99, "\x01\x02\x03\x04\x05")
  end

  # Route type 1, RFC 7432 section 7.1. Four fields and the recipe
  # exercises all four, with the MPLS Label carrying its three Rsrv bits
  # set and its low bit clear: a Label left at its default would pass
  # without ever showing that the route's hash carries :exp and :bottom.
  ENTRIES['BGP::Evpn::Ethernet_ad'] = entry(:ok, nil, nil) do
    BGP::Evpn::Ethernet_ad.new([100, 200],
                               '00:11:22:33:44:55:66:77:88:99',
                               100,
                               BGP::Label.new(:label => 500, :exp => 5,
                                              :bottom => 0))
  end

  # Route type 2, RFC 7432 section 7.2, the largest layout in the
  # family. Seven fields and the recipe exercises all seven, including
  # both optional ones: an IPv6 address, so the longest shape is the one
  # measured, and a second label, so :label2 is in the hash. The MAC
  # carries a length outside section 14's 48, which is the branch that
  # makes the hash fall back to the Sized form.
  ENTRIES['BGP::Evpn::Mac_ip_advertisement'] = entry(:ok, nil, nil) do
    BGP::Evpn::Mac_ip_advertisement.new(
      [100, 200], '00:11:22:33:44:55:66:77:88:99', 100,
      BGP::Evpn::Mac_addr.new(24, ['001122334455'].pack('H*')),
      '2001:db8::1',
      BGP::Label.new(:label => 500, :exp => 5, :bottom => 0),
      BGP::Label.new(501))
  end

  # Route type 3, RFC 7432 section 7.3. Three fields and no ESI, which
  # is what makes it the odd one of the five.
  ENTRIES['BGP::Evpn::Inclusive_multicast'] = entry(:ok, nil, nil) do
    BGP::Evpn::Inclusive_multicast.new([100, 200], 100, '2001:db8::1')
  end

  # Route type 4, RFC 7432 section 7.4. Three fields, and the address is
  # an IPv6 one so the 35 octet form is the one measured; the 23 octet
  # form and the odd-length fallback are asserted in the class test.
  ENTRIES['BGP::Evpn::Ethernet_segment'] = entry(:ok, nil, nil) do
    BGP::Evpn::Ethernet_segment.new([100, 200],
                                    '00:11:22:33:44:55:66:77:88:99',
                                    '2001:db8::1')
  end

  # Route type 5, RFC 9136 section 3.1. Six fields and the recipe
  # exercises all six, with the prefix in the pair form so the
  # out-of-range length branch is the one measured: a length of 200,
  # which section 3.1 says MUST NOT happen and which nothing validates,
  # is what the hash used to lose before it fell back to that form.
  ENTRIES['BGP::Evpn::Ip_prefix_route'] = entry(:ok, nil, nil) do
    BGP::Evpn::Ip_prefix_route.new(
      [100, 200], '00:11:22:33:44:55:66:77:88:99', 100,
      { :len => 200, :octets => '0a000000' }, '10.0.0.1',
      BGP::Label.new(:label => 500, :exp => 5, :bottom => 0))
  end

  # The Flags octet of route types 6, 7 and 8, RFC 9251 sections 9.1 to
  # 9.3. The recipe sets a reserved bit as well as two defined ones, so
  # it exercises the `{:bits => n}` entry the list cannot otherwise
  # carry: a Flags built from names alone would round trip without ever
  # showing that half of the hash.
  ENTRIES['BGP::Evpn::Flags'] = entry(:ok, nil, nil) do
    BGP::Evpn::Flags.new(0xf6)
  end

  # Route type 6, RFC 9251 section 9.1. Six fields and the recipe
  # exercises all six, with an absent Multicast Source, which section
  # 9.1.1 makes the ordinary (*,G) case, and a group whose length lies
  # about the octets behind it.
  ENTRIES['BGP::Evpn::Selective_multicast'] = entry(:ok, nil, nil) do
    BGP::Evpn::Selective_multicast.new(
      [100, 200], 100, nil, BGP::Evpn::Addr.new(24, ['e80101'].pack('H*')),
      '2001:db8::1', [:v3, :v2])
  end

  # Route type 7, RFC 9251 section 9.2. Seven fields and the recipe
  # exercises all seven.
  ENTRIES['BGP::Evpn::Membership_report_synch'] = entry(:ok, nil, nil) do
    BGP::Evpn::Membership_report_synch.new(
      [100, 200], '00:11:22:33:44:55:66:77:88:99', 100, '192.0.2.1',
      '232.1.1.1', '2001:db8::1', [:v3])
  end

  # Route type 8, RFC 9251 section 9.3. Nine fields, and two of them
  # only reach the object through the hash or the wire: the Reserved
  # field, which a build from values writes as zero because section
  # 9.3.1 tells an originator to, and a Flags with a reserved bit set.
  # Conventions says to exercise every field a class carries, so this
  # recipe builds from the hash rather than from values.
  ENTRIES['BGP::Evpn::Leave_synch'] = entry(:ok, nil, nil) do
    BGP::Evpn::Leave_synch.new(
      :rd => [100, 200], :esi => '00:11:22:33:44:55:66:77:88:99',
      :ethernet_tag_id => 100, :source => '192.0.2.1',
      :group => '232.1.1.1', :originator => '2001:db8::1',
      :reserved => 'deadbeef', :max_response_time => 100,
      :flags => [:v2, { :bits => 0xf2 }])
  end

  # The Region ID of route type 9, RFC 9572 sections 3.1 and 6.2. One
  # field, and the recipe uses the first of section 6.2's three example
  # encodings, a Transitive Two-Octet AS-specific EC of sub-type 0x09
  # carrying AS 65000.
  ENTRIES['BGP::Evpn::Region_id'] = entry(:ok, nil, nil) do
    BGP::Evpn::Region_id.new('00090000fde80000')
  end

  # Route type 9, RFC 9572 section 3.1. Three fields and the recipe
  # exercises all three.
  ENTRIES['BGP::Evpn::Per_region_i_pmsi'] = entry(:ok, nil, nil) do
    BGP::Evpn::Per_region_i_pmsi.new([100, 200], 100, '00090000fde80000')
  end

  # Route type 10, RFC 9572 section 3.2. Five fields and the recipe
  # exercises all five, with an absent Multicast Source, which is the
  # (*,G) case, and a group whose length lies about its octets.
  ENTRIES['BGP::Evpn::S_pmsi'] = entry(:ok, nil, nil) do
    BGP::Evpn::S_pmsi.new(
      [100, 200], 100, nil, BGP::Evpn::Addr.new(24, ['e80101'].pack('H*')),
      '2001:db8::1')
  end

  # Route type 11, RFC 9572 section 3.3. Two fields, and the Route Key
  # is a whole NLRI, so its hash is nested one level deeper than any
  # other route type's. The recipe puts a route type 9 in there rather
  # than an Unknown, so the nesting is exercised through a real route
  # type and the inner hash has to read back as well as the outer.
  ENTRIES['BGP::Evpn::Leaf_a_d'] = entry(:ok, nil, nil) do
    BGP::Evpn::Leaf_a_d.new(
      BGP::Evpn.new(BGP::Evpn::Per_region_i_pmsi
                      .new([100, 200], 100, '00090000fde80000')),
      '2001:db8::1')
  end

  # The NLRI framing, RFC 7432 section 7. Three fields and the recipe
  # exercises all three: the route, the RFC 7911 section 3 Path
  # Identifier, and a Length that disagrees with its own octets.
  #
  # Built from the wire rather than from values, because `declared_len`
  # only arrives by parsing: an NLRI built from a route computes its
  # Length from the body, so there is no way to make it lie from values.
  # Conventions says where a field only arrives by parsing, parse.
  ENTRIES['BGP::Evpn'] = entry(:ok, nil, nil) do
    BGP::Evpn.new_ntop(['09140011223344556677'].pack('H*'), 7)
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
    # The six abstract bases of flow_spec_component.rb. Each supplies
    # TYPE and HASH_KEY from a subclass, so none of the three build paths
    # can run in the base itself: a field build raises NameError on TYPE
    # and the Op_component ones raise NotImplementedError on pair_klass.
    # The 20 concrete classes above are measured instead.
    'BGP::Flow_spec::Component' =>
      'an abstract base with no sensible instance. TYPE and HASH_KEY ' \
      'come from the subclasses, and encode_value is not defined here ' \
      'at all. Its 20 concrete subclasses are measured instead.',
    'BGP::Flow_spec::Op_component' =>
      'an abstract base. pair_klass raises NotImplementedError, so no ' \
      'build path reaches a pair. Numeric_component and ' \
      'Bitmask_component supply it and their subclasses are measured.',
    'BGP::Flow_spec::Numeric_component' =>
      'an abstract base: it supplies pair_klass and nothing else, so ' \
      'TYPE and HASH_KEY are still missing. Its 12 subclasses are ' \
      'measured.',
    'BGP::Flow_spec::Bitmask_component' =>
      'an abstract base, as Numeric_component is. Its 3 subclasses are ' \
      'measured.',
    'BGP::Flow_spec::Prefix_component' =>
      'an abstract base: parse reads the class AFI constant, which only ' \
      'Destination_prefix and Source_prefix define. Both are measured.',
    'BGP::Flow_spec::Ipv6_prefix_component' =>
      'an abstract base, as Prefix_component is. ' \
      'Destination_ipv6_prefix and Source_ipv6_prefix are measured.',
    'BGP::Evpn::Sized' =>
      'an abstract base: from_text raises, so the one argument form no ' \
      'subclass overrides cannot be built, and the class carries no ' \
      'hash_key of its own. Addr and Mac_addr supply both and are ' \
      'measured.',
    'BGP::Evpn::Route' =>
      'an abstract base with no sensible instance. type and hash_key ' \
      'read self.class::TYPE and HASH_KEY and it defines neither, and ' \
      'encode calls an encode_value it does not have. Unknown is ' \
      'measured, and the route types fill this in later parts.',
    'BGP::Tunnel_encap::Int_sub_tlv' =>
      'an abstract base with no sensible instance. Its initialize and ' \
      'to_hash read self.class::TYPE, SIZE, NAME and KEY and it ' \
      'defines none of them, so new(5) raises NameError. Its four ' \
      'concrete subclasses are measured instead.',
  }.freeze

end
