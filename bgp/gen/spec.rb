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
  class Gen
    # A spec bgp4r cannot read: an unknown key, a family with no
    # generator, a value of the wrong type, or one a field cannot hold.
    # It is an ArgumentError because it is the caller's input that is
    # wrong. It is never raised for a route no RFC allows.
    class SpecError < ArgumentError ; end

    # A spec that reads but cannot be carried out: one route and its
    # attributes do not fit in one message.
    class Unpackable < SpecError ; end

    # The packer's arithmetic disagreed with a message it measured. That
    # is a bug in bgp4r and never the caller's fault, so it is not an
    # ArgumentError.
    class PackingError < StandardError ; end

    # Reads a spec into plain data with String keys, refusing what it
    # cannot read. **It checks types and nothing else**, which is the
    # first Conventions rule in CLAUDE.md: a spec may ask for a route no
    # RFC allows, and that is the point of a protocol testing tool. What
    # it refuses is a key it does not know, a value of the wrong JSON
    # type, and a number too large for the field it goes in, since
    # packing that would silently send a different value.
    #
    # Keys may be Strings or Symbols, so a Hash in a test and a parsed
    # JSON body read the same.
    module Spec
      module_function

      # The top level keys a spec takes.
      KEYS = %w[family afi count per_update start path_id label rd vrfs route_target
                source protocol destination_port rate redirect marking
                route_type ip esi ethernet_tag gateway mac_mobility router_mac pmsi_label
                originator igmp_flags max_response_time leaf es_import esi_label
                origin_as prefix_length default
                topology columns protocol_id identifier autonomous_system prefixes prefix_start
                node_name igp_metric admin_group max_bandwidth srlg prefix_metric
                seed group attributes].freeze

      # The keys that belong to some families only, and which. A spec
      # giving one to another family is refused by name in Gen.new, so
      # a label on a unicast spec is not dropped in silence.
      FLOW = %w[flow_spec flow_spec_vpn].freeze
      EVPN = %w[evpn].freeze
      RTC = %w[rt_constrain].freeze
      LS = %w[bgp_ls bgp_ls_vpn].freeze
      RD = %w[vpn vpn_multicast flow_spec_vpn evpn bgp_ls_vpn].freeze
      FAMILY_KEYS = { 'label' => %w[labelled vpn vpn_multicast evpn],
                      'rd' => RD, 'vrfs' => RD, 'route_target' => RD,
                      'source' => FLOW + EVPN, 'protocol' => FLOW,
                      'destination_port' => FLOW, 'rate' => FLOW,
                      'redirect' => FLOW, 'marking' => FLOW,
                      'route_type' => EVPN, 'ip' => EVPN, 'esi' => EVPN,
                      'ethernet_tag' => EVPN, 'gateway' => EVPN,
                      'mac_mobility' => EVPN, 'router_mac' => EVPN,
                      'pmsi_label' => EVPN, 'originator' => EVPN,
                      'igmp_flags' => EVPN, 'max_response_time' => EVPN,
                      'leaf' => EVPN, 'es_import' => EVPN, 'esi_label' => EVPN,
                      'origin_as' => RTC, 'prefix_length' => RTC, 'default' => RTC,
                      'topology' => LS, 'columns' => LS, 'protocol_id' => LS,
                      'identifier' => LS, 'autonomous_system' => LS,
                      'prefixes' => LS, 'prefix_start' => LS, 'node_name' => LS,
                      'igp_metric' => LS, 'admin_group' => LS, 'max_bandwidth' => LS,
                      'srlg' => LS, 'prefix_metric' => LS }.freeze

      # The BGP-LS keys that are patterns, with the largest value each
      # field holds. RFC 9552 section 5.3.2.4 gives the IGP metric 3
      # octets at its widest, which is the width bgp4r writes; the
      # administrative group (RFC 5305 section 3.1), an SRLG (RFC 5307
      # section 1.3) and a prefix metric (RFC 9552 section 5.3.3.4) are
      # 4, and a bandwidth is a 4-octet float, so any 32 bit number of
      # bytes per second is accepted (RFC 5305 section 3.4).
      LS_MAX = { 'igp_metric' => 0xffffff, 'admin_group' => 0xffffffff,
                 'max_bandwidth' => 0xffffffff, 'srlg' => 0xffffffff,
                 'prefix_metric' => 0xffffffff }.freeze

      # The EVPN keys that are integers, with the largest value each
      # field holds: an Ethernet Tag ID and a MAC Mobility sequence
      # number are 4 octets (RFC 7432 sections 7.2 and 7.7), and the
      # PMSI Tunnel's label is a label (RFC 6514 section 5).
      EVPN_MAX = { 'ethernet_tag' => 0xffffffff, 'mac_mobility' => 0xffffffff,
                   'pmsi_label' => 0xfffff, 'esi_label' => 0xfffff }.freeze

      # RFC 9251 section 9.1's IGMP flags, by the names bgp4r gives them.
      IGMP_FLAGS = %w[v1 v2 v3 ie].freeze

      # The largest value each flow spec key's field holds: an IP
      # protocol is one octet (RFC 8955 section 4.2.2.3), a port two
      # (section 4.2.2.4), a DSCP six bits (section 7.5), and a rate is
      # written as a float, so any 32 bit number is accepted (section
      # 7.1).
      FLOW_MAX = { 'protocol' => 0xff, 'destination_port' => 0xffff,
                   'rate' => 0xffffffff, 'marking' => 63 }.freeze

      # The announce block keys bgp4r already uses everywhere else, with
      # the kind of value each is, which says the patterns it takes, and
      # the largest value a field of it can hold. See bgp/gen/vary.rb.
      ATTRIBUTE_KINDS = {
        'origin'               => [:int, 0xff],
        'next_hop'             => [:addr, nil],
        'as_path'              => [:list, nil],
        'med'                  => [:int, 0xffffffff],
        'local_pref'           => [:int, 0xffffffff],
        'communities'          => [:strings, nil],
        'extended_communities' => [:strings, nil],
        'large_communities'    => [:strings, nil],
      }.freeze
      ATTRIBUTES = ATTRIBUTE_KINDS.keys.freeze

      U32 = 0xffffffff

      # A label is 20 bits, RFC 3032 section 2.1.
      LABEL_MAX = 0xfffff

      # The spec as plain data with String keys: a plain value in the
      # form it is sent in, a single community string as a list of one,
      # and a pattern as its Hash. Every value goes through Vary.compile
      # here, so a pattern bgp4r cannot read is refused when the spec is,
      # and `patterns` compiles the same values again for a generator.
      def read(spec)
        raise SpecError, "a spec is a Hash, not #{spec.class}" unless spec.is_a?(Hash)
        s = stringify(spec, 'spec')
        s.each_key do |k|
          raise SpecError, "unknown key '#{k}'; a spec takes #{KEYS.join(', ')}" unless KEYS.include?(k)
        end
        out = {}
        out['family'] = family(s.fetch('family', 'unicast'))
        out['start'] = string(s, 'start', true)
        out['count'] = integer(s, 'count', true, 1)
        out['per_update'] = integer(s, 'per_update', false, 1)
        out['afi'] = integer(s, 'afi', false, 0, 0xffff)
        out['seed'] = integer(s, 'seed', false, 0)
        out['group'] = integer(s, 'group', false, 1)
        out['path_id'] = value(s['path_id'], 'path_id', :int, U32, out['seed']) if s.key?('path_id')
        out['label'] = value(s['label'], 'label', :int, LABEL_MAX, out['seed']) if s.key?('label')
        out['vrfs'] = integer(s, 'vrfs', false, 1)
        FLOW_MAX.each do |k, max|
          out[k] = value(s[k], k, :int, max, out['seed']) if s.key?(k)
        end
        out['route_type'] = integer(s, 'route_type', false, 0, 0xff)
        # RFC 4684 section 4: a 4-octet origin AS, and a prefix length in
        # one octet, which is all the bound there is.
        out['origin_as'] = value(s['origin_as'], 'origin_as', :int, U32, out['seed']) if s.key?('origin_as')
        out['prefix_length'] = integer(s, 'prefix_length', false, 0, 0xff)
        if s.key?('default')
          unless s['default'] == true || s['default'] == false
            raise SpecError, "default is true or false, not #{s['default'].inspect}"
          end
          out['default'] = s['default']
        end
        EVPN_MAX.each do |k, max|
          out[k] = value(s[k], k, :int, max, out['seed']) if s.key?(k)
        end
        LS_MAX.each do |k, max|
          out[k] = value(s[k], k, :int, max, out['seed']) if s.key?(k)
        end
        out['topology'] = string(s, 'topology', false)
        if out['topology'] && !%w[ring grid].include?(out['topology'])
          raise SpecError, "topology is ring or grid, not #{out['topology'].inspect}"
        end
        out['columns'] = integer(s, 'columns', false, 1)
        # RFC 9552 section 5.2: a 1-octet Protocol-ID, an 8-octet
        # Identifier, and a 4-octet AS in sub-TLV 512 (section 5.2.1.4).
        out['protocol_id'] = integer(s, 'protocol_id', false, 0, 0xff)
        out['identifier'] = integer(s, 'identifier', false, 0, 2**64 - 1)
        out['autonomous_system'] = integer(s, 'autonomous_system', false, 0, U32)
        out['prefixes'] = integer(s, 'prefixes', false, 0)
        out['prefix_start'] = string(s, 'prefix_start', false)
        out['node_name'] = string(s, 'node_name', false)
        %w[ip gateway originator leaf].each do |k|
          out[k] = string(s, k, false)
          next unless out[k]
          begin
            IPAddr.new(out[k])
          rescue IPAddr::Error => e
            raise SpecError, "#{k} #{out[k].inspect} is not an address: #{e.message}"
          end
        end
        out['esi'] = octets(s, 'esi', 10, 'RFC 7432 section 5')
        # RFC 9251 section 9.3: the Maximum Response Time is one octet.
        out['max_response_time'] = integer(s, 'max_response_time', false, 0, 0xff)
        if s.key?('es_import')
          unless s['es_import'] == true || s['es_import'] == false
            raise SpecError, "es_import is true or false, not #{s['es_import'].inspect}"
          end
          out['es_import'] = s['es_import']
        end
        if s.key?('igmp_flags')
          f = s['igmp_flags']
          unless f.is_a?(Array) && f.all? { |x| IGMP_FLAGS.include?(x.to_s) }
            raise SpecError, "igmp_flags is a list of #{IGMP_FLAGS.join(', ')}, not #{f.inspect}"
          end
          out['igmp_flags'] = f.collect(&:to_s)
        end
        out['router_mac'] = octets(s, 'router_mac', 6, 'RFC 9135 section 8.1')
        out['source'] = string(s, 'source', false)
        if out['source']
          begin
            IPAddr.new(out['source'])
          rescue IPAddr::Error => e
            raise SpecError, "source #{out['source'].inspect} is not a prefix: #{e.message}"
          end
        end
        # A redirect target does not step per VRF, so it is only read.
        if s.key?('redirect')
          distinguisher(s['redirect'], 'redirect')
          out['redirect'] = s['redirect']
        end
        %w[rd route_target].each do |k|
          next unless s.key?(k)
          d = distinguisher(s[k], k)
          d.at((out['vrfs'] || 1) - 1)
          out[k] = s[k]
        end
        out['attributes'] = attributes(s.fetch('attributes', {}), out['seed'])
        out.reject { |_, v| v.nil? }
      end

      # The compiled patterns of a spec `read` answered: 'path_id' and
      # one per attribute given, each answering `at(i)`.
      def patterns(spec)
        out = {}
        out['path_id'] = Vary.compile(spec['path_id'], 'path_id', :int, max: U32, seed: spec['seed']) if spec['path_id']
        spec['attributes'].each do |k, v|
          kind, max = ATTRIBUTE_KINDS[k]
          out[k] = Vary.compile(v, "attributes.#{k}", kind, max: max, seed: spec['seed'])
        end
        out
      end

      # An RD or a route target as text, `ADMIN:N`, which steps once per
      # VRF by adding to N. The administrator says which of the three
      # layouts it is, and RFC 4364 section 4.2 gives them: an AS that
      # fits two octets is type 0 with a 4-octet N, an IPv4 address is
      # type 1 and a 4-octet AS is type 2, both with a 2-octet N. RFC
      # 4360 sections 3.1 and 3.2 and RFC 5668 section 2 give a route
      # target the same three, so one reader serves both.
      #
      # **A 4-octet AS below 65536 cannot be asked for**: 65000 reads as
      # type 0. Nothing here needed it, and `mp_reach` sends any RD.
      Distinguisher = Struct.new(:name, :admin, :first, :type, :max) do
        # The one for VRF v, as the [admin, assigned] pair `Rd.new` and
        # `Route_target` both take. Refused when N runs past its field,
        # since the alternative is writing a different number.
        def at(v)
          n = first + v
          if n > max
            raise SpecError, "#{name} #{admin}:#{first} steps to #{n} by VRF #{v + 1}, " \
                             "past the #{max} a type #{type} field holds (RFC 4364 section 4.2)"
          end
          [admin, n]
        end

        def text(v) ; at(v).join(':') ; end
      end

      def distinguisher(text, name)
        raise SpecError, "#{name} is ADMIN:N as a string, not #{text.inspect}" unless text.is_a?(String)
        admin, n = text.split(/:(?=[^:]*\z)/)
        unless n =~ /\A\d+\z/
          raise SpecError, "#{name} #{text.inspect} is not ADMIN:N, as 65000:1, 192.0.2.1:1 or 4200000000:1"
        end
        if admin =~ /\A\d+\.\d+\.\d+\.\d+\z/
          type, a = 1, admin
          begin
            IPAddr.new(a)
          rescue IPAddr::Error
            raise SpecError, "#{name} #{text.inspect}: #{a} is not an IPv4 address"
          end
        elsif admin =~ /\A\d+\z/
          a = admin.to_i
          type = a <= 0xffff ? 0 : 2
          raise SpecError, "#{name} #{text.inspect}: #{a} does not fit 4 octets" if a > U32
        else
          raise SpecError, "#{name} #{text.inspect}: the administrator is an AS number or an IPv4 address"
        end
        Distinguisher.new(name, a, n.to_i, type, type == 0 ? U32 : 0xffff)
      end

      # A fixed width field written as hex octets, with or without
      # colons, as the ESI's ten and a MAC's six. Refused when it is not
      # that many octets, since the field could not hold anything else.
      def octets(h, k, n, rfc)
        v = string(h, k, false)
        return nil unless v
        unless v.delete(':') =~ /\A\h{#{2 * n}}\z/
          raise SpecError, "#{k} #{v.inspect} is #{n} octets of hex, as #{(['00'] * n).join(':')} (#{rfc})"
        end
        v
      end

      def family(v)
        v = v.to_s if v.is_a?(Symbol)
        raise SpecError, "family is a name, not #{v.inspect}" unless v.is_a?(String)
        v
      end

      def attributes(a, seed)
        raise SpecError, "attributes is a Hash, not #{a.class}" unless a.is_a?(Hash)
        a = stringify(a, 'attributes')
        out = {}
        a.each do |k, v|
          raise SpecError, "unknown attribute '#{k}'; attributes take #{ATTRIBUTES.join(', ')}" unless ATTRIBUTES.include?(k)
          kind, max = ATTRIBUTE_KINDS[k]
          out[k] = value(v, "attributes.#{k}", kind, max, seed)
        end
        out
      end

      # One value, compiled to check it and kept as plain data: what a
      # fixed value is sent as, or the pattern's Hash with String keys.
      def value(v, name, kind, max, seed)
        p = Vary.compile(v, name, kind, max: max, seed: seed)
        p.is_a?(Vary::Fixed) ? p.value : deep_stringify(v, name)
      end

      def deep_stringify(v, name)
        case v
        when Hash then stringify(v, name).transform_values { |e| deep_stringify(e, name) }
        when Array then v.collect { |e| deep_stringify(e, name) }
        else v
        end
      end

      def string(h, k, required, path = '')
        v = h[k]
        raise SpecError, "#{path}#{k} is required" if v.nil? && required
        return nil if v.nil?
        raise SpecError, "#{path}#{k} is a string, not #{v.inspect}" unless v.is_a?(String)
        v
      end

      def integer(h, k, required, min, max = nil, path = '')
        v = h[k]
        raise SpecError, "#{path}#{k} is required" if v.nil? && required
        return nil if v.nil?
        raise SpecError, "#{path}#{k} is an integer, not #{v.inspect}" unless v.is_a?(Integer)
        raise SpecError, "#{path}#{k} is at least #{min}, not #{v}" if v < min
        raise SpecError, "#{path}#{k} #{v} does not fit its field, whose largest value is #{max}" if max && v > max
        v
      end

      def stringify(h, where)
        out = {}
        h.each do |k, v|
          key = k.is_a?(Symbol) ? k.to_s : k
          raise SpecError, "#{where} keys are names, not #{k.inspect}" unless key.is_a?(String)
          raise SpecError, "#{where} has '#{key}' twice, once as a String and once as a Symbol" if out.key?(key)
          out[key] = v
        end
        out
      end
    end
  end
end

require 'bgp/gen/vary'
