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
require 'bgp/gen/spec'

module BGP
  class Gen
    # The session a spec is sent on, which the library itself knows
    # nothing of. Without one a spec's attributes go out as written.
    # With one, each route's attributes get the three rules
    # `Daemon::Speaker#path_attribute` applies to an announce block, so
    # a spec and an announce block sent by one injector agree:
    #
    # * **AS_PATH**: over eBGP our AS goes in front (RFC 4271 section
    #   5.1.2), unless `as_path_literal` is true, which is phase 0b's
    #   key and means the same thing here.
    # * **NEXT_HOP**: the session's own address when the spec gives
    #   none. For an IPv6 spec on an IPv4 session that is an IPv4
    #   address under AFI 2, which `Mp_reach` writes as an IPv4-mapped
    #   IPv6 address on its own; nothing here chooses that.
    # * **LOCAL_PREF**: never to an external peer (RFC 4271 section
    #   5.1.5), and 100 to an internal one when the spec gives none.
    #   **So a spec's `local_pref` is dropped over eBGP**, as an announce
    #   block's is. `expected` says so, since it is built from the same
    #   row, which is why a dry run is worth asking for.
    #
    # The rules run on the row of plain values, before the attribute set
    # is built, so `updates` and `expected` cannot disagree about them.
    class Sender
      KEYS = %w[as ebgp next_hop as_path_literal].freeze

      # RFC 4271 section 5.1.5 leaves the value to the speaker. 100 is
      # what every bgp4r announce block sends to an internal peer.
      LOCAL_PREF = 100

      attr_reader :as, :next_hop

      # A Sender from a Hash with String or Symbol keys, or nil for nil.
      def self.read(h)
        return nil if h.nil?
        return h if h.is_a?(Sender)
        raise SpecError, "a sender is a Hash, got #{h.class}" unless h.is_a?(Hash)
        h = h.to_h { |k, v| [k.to_s, v] }
        unknown = h.keys - KEYS
        raise SpecError, "unknown sender key(s) #{unknown.join(', ')}; a sender takes #{KEYS.join(', ')}" unless unknown.empty?
        new(h)
      end

      def initialize(h)
        @ebgp = boolean(h, 'ebgp')
        @literal = boolean(h, 'as_path_literal')
        @as = h['as']
        if @ebgp && !@literal
          unless @as.is_a?(Integer) && @as.between?(0, Spec::U32)
            raise SpecError, "an eBGP sender needs its own as, 0 to #{Spec::U32}, got #{@as.inspect}"
          end
        end
        @next_hop = h['next_hop']
        IPAddr.new(@next_hop) if @next_hop
      rescue IPAddr::Error => e
        raise SpecError, "sender next_hop #{@next_hop.inspect} is not an address: #{e.message}"
      end

      def ebgp? ; @ebgp ; end
      def as_path_literal? ; @literal ; end

      # The row with the three rules applied. The row is the generator's
      # own fresh Hash, so it is changed in place.
      def apply(r)
        r['as_path'] = [@as] + r['as_path'] if @ebgp && !@literal
        r['next_hop'] = @next_hop if r['next_hop'].nil? && @next_hop
        if @ebgp
          r.delete('local_pref')
        else
          r['local_pref'] = LOCAL_PREF if r['local_pref'].nil?
        end
        r
      end

      private

      # A JSON boolean and nothing else, for the reason
      # `Injector#check` gives for as_path_literal: a string "true"
      # would quietly mean something.
      def boolean(h, name)
        v = h.fetch(name, false)
        return v if v == true || v == false
        raise SpecError, "sender #{name} must be true or false, got #{v.inspect}"
      end
    end
  end
end
