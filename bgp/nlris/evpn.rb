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
require 'bgp/nlris/evpn_route'

module BGP

  # One EVPN NLRI: the 3-tuple of RFC 7432 section 7, carried over
  # AFI 25 and SAFI 70.
  #
  #                 +-----------------------------------+
  #                 |    Route Type (1 octet)           |
  #                 +-----------------------------------+
  #                 |     Length (1 octet)              |
  #                 +-----------------------------------+
  #                 | Route Type specific (variable)    |
  #                 +-----------------------------------+
  #
  # `docs/evpn.md` is the guide. Every section number here was read in
  # the RFC text. Nothing dispatches to this class yet.
  #
  # **One NLRI holds one route, not a list**, which is where this
  # differs from `Flow_spec`. A flow spec NLRI is a list of components
  # under one length; an EVPN NLRI is a single Route Type with its own
  # length, and several of them sit one after another in the attribute.
  #
  # **The NLRI owns its own framing, as the flow spec family does.**
  # A prefix family's length is in bits and `Mp_reach#parse` has always
  # worked out how many octets to slice with `(blen+7)/8+1`. Section 7's
  # Length is in octets, counts only the body, and sits behind a Route
  # Type octet, so that arithmetic is wrong here three times over.
  # `Evpn.nlri_size` answers the question for this family, so the two
  # parse loops can ask rather than calculate, exactly as they already
  # ask `Flow_spec.nlri_size`.
  #
  # **It needs no AFI, where the flow spec family did.** RFC 8956
  # section 8.1.2 gives component type 13 one meaning for IPv4 and
  # another for IPv6, so `Flow_spec` had to be told which family it was
  # parsing. Nothing in EVPN is ambiguous that way: route type 5's
  # Length is 34 for IPv4 and 58 for IPv6 (RFC 9136 section 3.1), and
  # every other variable width address is length prefixed, so the octets
  # say which family they are.
  #
  # **The framing is recursive and still self delimiting.** RFC 9572
  # section 3.3 makes route type 11's Route Key "the NLRI of the route
  # for which this Leaf A-D route is generated", and its terminology
  # section says the Leaf A-D route "embeds the entire NLRI of the
  # triggering PMSI A-D route". Entire, so Route Type and Length
  # included, so a Route Key is read by this same class and its extent
  # comes from its own Length octet. Route type 11 arrives in a later
  # part; the framing is already able to carry it.
  #
  # **Nothing validates.** Any route type, any length, any body,
  # including a Length that disagrees with the octets that came with it.
  class Evpn

    # RFC 7432 section 7. Both framing fields are one octet, so a body
    # is at most 255 octets and the Length counts the body alone.
    MAX_LEN   = 255
    FRAMING   = 2

    # The route type registry, as RFC 9572 section 3 Table 1 and Table 2
    # give it: eight types across RFC 7432, RFC 9136 and RFC 9251, and
    # three more of its own.
    #
    # **Empty on purpose.** This part landed the primitives and the
    # framing, so every EVPN NLRI reads back as an `Evpn::Unknown` that
    # replays byte for byte and none of them has meaning yet. Each later
    # part fills rows in here, and `test/unit/evpn_doc_test.rb`
    # discovers this table rather than listing it, so a route type class
    # cannot join the library without `docs/evpn.md` being told.
    ROUTES = {}.freeze

    # Hash key back to class, for the hash build path. Unknown is in
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
    #   Evpn.new(Evpn::Unknown.new(9, octets))
    #   Evpn.new(:unknown => { :type => 9, :value => '0011' })
    #   Evpn.new(wire_bytes)
    #   Evpn.new(another_evpn)
    def initialize(*args)
      @route, @path_id, @declared_len = nil, nil, nil
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size == 1 and args[0].is_a?(Evpn)
        parse(args[0].encode.is_packed)
      elsif args.size == 1 and args[0].is_a?(Route)
        @route = args[0]
      elsif args.size == 1 and args[0].is_a?(Hash)
        from_hash(args[0])
      else
        raise ArgumentError, "invalid argument: #{args.inspect}, expected " \
                             'an Evpn route, a hash, wire bytes or an Evpn'
      end
      self
    end

    def self.new_ntop(s, path_id = nil)
      e = new(s.is_packed)
      e.path_id = path_id if path_id
      e
    end

    attr_writer :path_id

    # RFC 7911 section 3 prepends a Path Identifier to the NLRI, so an
    # extended one is four octets longer. Named as Prefix names it.
    def extended?
      !@path_id.nil?
    end

    # How many octets the next EVPN NLRI occupies, its two framing
    # octets included. This is what `Mp_reach#parse` and
    # `Mp_unreach#parse` need in place of the prefix families'
    # `(blen+7)/8+1`, and it lives here so the family owns its framing.
    #
    # Answers nil for octets too short to hold the framing, so a caller
    # can stop rather than loop.
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
      other.is_a?(Evpn) and other.encode == encode
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
      klass = ROUTES[t]
      @route = if klass
                 # **Unreachable in this part, and the one line in these
                 # two files that is.** `ROUTES` is empty, so no type
                 # number resolves and every NLRI takes the branch
                 # below. The branch stays because the next part fills
                 # `ROUTES` and this is the line it arrives on, the way
                 # `Fib`'s `:no_next_hop` branch stays for a caller that
                 # cannot reach it through a live table. What guards it
                 # meanwhile is `evpn_doc_test.rb`, which fails if a
                 # route class and `ROUTES` disagree in either
                 # direction.
                 klass.new(body.is_packed)
               else
                 Unknown.new(t, body)
               end
      self
    end

    def from_hash(h)
      h = h.dup
      @declared_len = h.delete(:length)
      @path_id      = h.delete(:path_id)
      key = h.keys.find { |k| BY_KEY.has_key?(k) }
      raise ArgumentError, "no EVPN route type in #{h.inspect}" if key.nil?
      @route = BY_KEY[key].new(h)
    end

  end

end
