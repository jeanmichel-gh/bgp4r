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

require 'bgp/common'
require 'bgp/iana'
require 'bgp/nlris/rd'
require 'bgp/nlris/mcast_vpn_route'

module BGP

  # One MCAST-VPN NLRI: the 3-tuple of RFC 6514 section 4, "MCAST-VPN
  # NLRI", carried over SAFI 5.
  #
  #                 +-----------------------------------+
  #                 |      Route Type (1 octet)         |
  #                 +-----------------------------------+
  #                 |     Length (1 octet)              |
  #                 +-----------------------------------+
  #                 | Route Type specific (variable)    |
  #                 +-----------------------------------+
  #
  # `docs/mcast-vpn.md` is the guide. Every section number here was read
  # in the RFC text on 2026-10-31. Nothing dispatches to this class yet.
  #
  # **The framing is the EVPN shape exactly**, which is why that
  # experience transfers whole. Section 4: "The Length field indicates
  # the length in octets of the Route Type specific field of the
  # MCAST-VPN NLRI", so the Length counts the body alone and sits behind
  # a Route Type octet. A prefix family's length is in bits and
  # `Mp_reach#parse` has always worked out how many octets to slice with
  # `(blen+7)/8+1`, which is wrong here three times over.
  # `Mcast_vpn.nlri_size` answers the question for this family, so the
  # two parse loops can ask rather than calculate, exactly as they
  # already ask `Flow_spec.nlri_size` and `Evpn.nlri_size`.
  #
  # **It needs no AFI, where the flow spec family did.** Section 4 says
  # "with an Address Family Identifier (AFI) of 1 or 2 and a Subsequent
  # AFI (SAFI) of MCAST-VPN", so this family has **two** AFIs where EVPN
  # has one, and that still buys the parse nothing: the Multicast Source
  # and Multicast Group are length prefixed and the Originating Router's
  # IP Address takes its family from its own width, so the octets say
  # which family they are. Where the two AFIs are expected to matter is
  # the next hop, which is the wiring part's question and not this one.
  #
  # **The framing is recursive, which route type 4 will need.** Section
  # 4.4 says "the Route Key of the Leaf A-D route is set to the NLRI of
  # the received route", so a Route Key read as a whole nested NLRI is
  # parsed by this same class and its extent comes from its own Length
  # octet. **That reading is a reading and not a rule**: neither RFC
  # 6514 nor draft-ietf-bess-rfc6514bis-00 says whether the Route Key
  # includes the Route Type and Length octets, where RFC 9572 needed its
  # own terminology section to settle the same question for EVPN route
  # type 11. Route type 4 arrives in a later part; the framing is
  # already able to carry it either way.
  #
  # **Nothing validates.** Any route type, any length, any body,
  # including a Length that disagrees with the octets that came with it.
  class Mcast_vpn

    # RFC 6514 section 4. Both framing fields are one octet, so a body
    # is at most 255 octets and the Length counts the body alone.
    MAX_LEN = 255
    FRAMING = 2

    # The route type registry, as IANA's "BGP MCAST-VPN Route Types"
    # gives it, read on 2026-10-31. **Ten assigned values where RFC 6514
    # defines seven**: 0x01 to 0x07 from section 4, then 0x43, 0x44 and
    # 0x47 from RFC 7441, whose header says `Updates: 6514`. 0x00 and
    # 0x80 to 0xff are Reserved.
    #
    # **Empty in this part**, which lands the framing and the primitives
    # with nothing dispatching to them, the way #181 did for EVPN and
    # #156 for the FIB planner. Every type therefore reads back as an
    # `Unknown` that replays byte for byte. Later parts fill the rows:
    # 1, 2 and 5 first, then 3, 6 and 7, then 4.
    #
    # The three mLDP types are **not** rows to fill. Each carries an
    # mLDP FEC Element that RFC 7441 does not lay out, pointing at RFC
    # 6388 section 2.2, so that field belongs to LDP and bgp4r has
    # nothing of LDP. They stay `Unknown` on purpose; see
    # `docs/mcast-vpn.md`.
    #
    # `test/unit/mcast_vpn_doc_test.rb` **discovers** this table rather
    # than listing it, so a route type class cannot join the library
    # without `docs/mcast-vpn.md` being told, and a class registered
    # here with no row, or a row with no class, fails either way.
    ROUTES = {}.freeze

    # Hash key back to class, for the hash build path. `Unknown` is in
    # here and in no row above, which is the whole point of it: no type
    # number reaches it, and a hash that carries one has to build back.
    BY_KEY = (ROUTES.values + [Unknown]).uniq
             .each_with_object({}) { |k, h| h[k.hash_key] = k }.freeze

    attr_reader :route, :path_id

    # The Length that arrived, when it is not the number of octets that
    # came with it, so encode writes back what the peer sent rather than
    # what is really there. nil on anything built from values.
    attr_reader :declared_len

    # Four ways in, as Conventions asks:
    #
    #   Mcast_vpn.new(Mcast_vpn::Unknown.new(1, octets))
    #   Mcast_vpn.new(:unknown => { :type => 1, :value => '0011' })
    #   Mcast_vpn.new(wire_bytes)
    #   Mcast_vpn.new(another_mcast_vpn)
    def initialize(*args)
      @route, @path_id, @declared_len = nil, nil, nil
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size == 1 and args[0].is_a?(Mcast_vpn)
        parse(args[0].encode.is_packed)
      elsif args.size == 1 and args[0].is_a?(Route)
        @route = args[0]
      elsif args.size == 1 and args[0].is_a?(Hash)
        from_hash(args[0])
      else
        raise ArgumentError, "invalid argument: #{args.inspect}, expected " \
                             'an Mcast_vpn route, a hash, wire bytes or an ' \
                             'Mcast_vpn'
      end
      self
    end

    def self.new_ntop(s, path_id = nil)
      m = new(s.is_packed)
      m.path_id = path_id if path_id
      m
    end

    attr_writer :path_id

    # RFC 7911 section 3 prepends a Path Identifier to the NLRI, so an
    # extended one is four octets longer. Named as Prefix names it.
    def extended?
      !@path_id.nil?
    end

    # How many octets the next MCAST-VPN NLRI occupies, its two framing
    # octets included. This is what `Mp_reach#parse` and
    # `Mp_unreach#parse` need in place of the prefix families'
    # `(blen+7)/8+1`, and it lives here so the family owns its framing.
    #
    # Answers nil for octets too short to frame, so a caller can stop
    # rather than loop.
    def self.nlri_size(s)
      return nil if s.nil? or s.size < FRAMING
      FRAMING + s.getbyte(1)
    end

    def type
      @route && @route.type
    end

    # The Length octet this NLRI writes: what arrived when that
    # disagreed with the body, and the body's own size otherwise.
    def length
      @declared_len || (@route ? @route.encode.size : 0)
    end

    def encode
      body = @route ? @route.encode : +''
      s = [type.to_i, length, body].pack('CCa*')
      s = [@path_id].pack('N') + s if extended?
      s
    end

    def to_shex
      encode.unpack1('H*')
    end

    def size
      encode.size
    end

    def to_hash
      h = @route ? @route.to_hash : {}
      h = h.merge(:length => @declared_len) if @declared_len
      h = h.merge(:path_id => @path_id) if extended?
      h
    end

    def to_s
      s = @route ? @route.to_s : '(empty)'
      s = "[#{@path_id}] " + s if extended?
      s
    end

    def ==(other)
      other.is_a?(Mcast_vpn) and other.encode == encode
    end

    private

    # Route Type, Length, then exactly Length octets of body. A Length
    # that overruns what is there takes what is there and is kept, so
    # encode gives the peer's own Length back rather than correcting it.
    def parse(s)
      t   = s.slice!(0, 1).unpack1('C')
      len = s.slice!(0, 1).unpack1('C')
      body = s.slice!(0, [len, s.size].min)
      @declared_len = len if len != body.size
      @route = read_route(t, body) || Unknown.new(t, body)
      self
    end

    # **A route type is kept only if it can give its own octets back**,
    # which is stricter than catching an exception and has to be, for
    # the reason `Flow_spec` and `Evpn` both record: a layout parsed
    # from a body that does not fit it invents the fields it did not
    # find, so it would answer `encode` with octets the peer never sent.
    # Nothing in the framing guarantees the Length agrees with the body.
    #
    # So the body is parsed on a **copy** and the result accepted only
    # when its `encode` matches what it was given. A body that fails
    # that falls back to `Unknown`, which keeps the octets whole and
    # replays them. That is a known route type number reading back as
    # Unknown, which looks odd and is the honest answer; `declared_len`
    # already records a Length that lied.
    #
    # **It is also what keeps route type 4's reading from becoming an
    # assertion**, in the part that adds it: a Route Key read as a
    # nested NLRI is accepted only where the whole body replays.
    #
    # **Nothing reaches the body of this method in this part**, because
    # `ROUTES` is empty and the guard above answers nil for every type.
    # So these three lines are the one uncovered piece of this family
    # today, and the part that adds route types 1, 2 and 5 is where they
    # first run. Said here rather than left for a coverage report to
    # raise as a question.
    def read_route(t, body)
      klass = ROUTES[t]
      return nil if klass.nil?
      r = klass.new(body.dup.is_packed)
      r.encode == body ? r : nil
    rescue StandardError
      nil
    end

    def from_hash(h)
      h = h.dup
      @declared_len = h.delete(:length)
      @path_id      = h.delete(:path_id)
      key = h.keys.find { |k| BY_KEY.has_key?(k) }
      raise ArgumentError, "no MCAST-VPN route type in #{h.inspect}" if key.nil?
      @route = BY_KEY[key].new(h)
    end

  end

end

load "../../test/unit/nlris/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
