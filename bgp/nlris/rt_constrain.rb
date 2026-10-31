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
require 'bgp/path_attributes/extended_communities'

module BGP

  # The Route Target membership NLRI of RFC 4684, "Constrained Route
  # Distribution for BGP/MPLS IP VPNs", AFI 1 SAFI 132. Section 4:
  #
  #   The NLRI field in the MP_REACH_NLRI and MP_UNREACH_NLRI is a
  #   prefix of 0 to 96 bits, encoded as defined in Section 4 of [5].
  #
  #        +-------------------------------+
  #        | origin as        (4 octets)   |
  #        +-------------------------------+
  #        | route target     (8 octets)   |
  #        +                               +
  #        |                               |
  #        +-------------------------------+
  #
  # Its [5] is **RFC 2858**, which RFC 4760 obsoletes; the framing is the
  # one every prefix family here already uses, a length octet in bits
  # then the octets that hold them.
  #
  # **So this family needs no new framing rule, unlike the two before
  # it.** `MpReachCommon::ClassMethods#nlri_size` has an arm for flow
  # spec and one for EVPN because each frames its own way; its `else`
  # branch is `(s.getbyte(0) + 7) / 8 + 1`, which is already exactly
  # section 4's arithmetic. Measured on 2026-10-31 against the three
  # cases the section describes: a zero-length prefix is 1 octet, a
  # 32-bit one 5 and a 96-bit one 13. A reader looking for an arm here
  # will not find one, and that is why.
  #
  # **The route target inside is partial by design and that is the whole
  # point of the family**, which is the thing to understand before
  # reading the rest. Section 4:
  #
  #   Route targets can then be expressed as prefixes, where, for
  #   instance, a prefix would encompass all route target extended
  #   communities assigned by a given Global Administrator [6].
  #
  # A two-octet-AS route target is type, sub-type, a 2-octet Global
  # Administrator and a 4-octet Local Administrator (RFC 4360 section
  # 3.1), so "all of one Global Administrator's" is 4 of its 8 octets,
  # which is a 64-bit prefix. The whole community is only there at 96
  # bits. So `BGP::Route_target` is **not** reused as a field the way
  # `BGP::Label` is in the EVPN route types: at 64 bits half of it is
  # absent, and a class that always decoded one would invent the half it
  # did not get. This holds a prefix length and the octets, and answers
  # `origin_as` and `route_target` only where the length makes them
  # whole.
  #
  # Two more things section 4 settles:
  #
  #   Except for the default route target, which is encoded as a zero-
  #   length prefix, the minimum prefix length is 32 bits.  As the
  #   origin-as field cannot be interpreted as a prefix.
  #
  # and the default route target "can be used to indicate to a peer the
  # willingness to receive all VPN route advertisements".
  #
  # **Nothing validates**, per the conventions in CLAUDE.md. A length of
  # 1 to 31 is what that minimum forbids and it still builds and
  # encodes, as does one above 96, so a test can put either on the wire
  # and watch a router decide. RFC 4684 says nothing about malformed
  # NLRIs anywhere in its text, so what a receiver should answer with is
  # not this RFC's to give and is not invented here.
  class Rt_constrain

    # Section 4: "a prefix of 0 to 96 bits", the origin AS 4 octets and
    # the route target 8.
    MAX_MLEN = 96
    AS_BITS   = 32
    RT_BITS   = 64

    # The length below which section 4 allows only the zero-length
    # default, "as the origin-as field cannot be interpreted as a
    # prefix". Not enforced; named so a test can say what it is
    # deviating from.
    MIN_MLEN = AS_BITS

    class << self
      # The octets one NLRI occupies, for a caller that has a list of
      # them. The same arithmetic nlri_size already does, kept here so
      # the family can answer for itself the way Flow_spec and Evpn do.
      def nlri_size(s)
        return nil if s.nil? or s.empty?
        (s.getbyte(0) + 7) / 8 + 1
      end

      def new_ntop(s, path_id = nil)
        rt = new(s.is_packed)
        rt.path_id = path_id if path_id
        rt
      end
    end

    attr_reader :mlen
    attr_accessor :path_id

    def initialize(*args)
      @mlen, @value, @path_id = 0, +'', nil
      if args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      elsif args.size == 1 and args[0].is_a?(Rt_constrain)
        parse(args[0].encode.is_packed)
      elsif args.size == 1 and args[0].is_a?(Hash)
        from_hash(args[0])
      elsif args.empty?
        # Section 4's default route target, a zero-length prefix.
      else
        from_values(*args)
      end
      self
    end

    # Section 4's zero-length prefix, the default route target.
    def default?
      @mlen.zero?
    end

    # The origin AS, or nil below the 32 bits that hold it. Reading one
    # out of fewer bits would be inventing it.
    #
    # **That guard cannot be reached**, and it is kept anyway. @value is
    # always fitted to the length: fit_to_mlen does it on a build from
    # values, and parse slices at most octets_for(@mlen), so a length
    # under 32 bits always means fewer than 4 octets and unpack1('N')
    # answers nil on its own. Measured by sabotage on 2026-10-31, which
    # changed no test. It stays because the arithmetic that makes it
    # redundant lives in two other methods, and because saying the rule
    # once here is what a reader comes for. The route_target guard below
    # is the opposite case and is load bearing.
    def origin_as
      return nil if @mlen < AS_BITS
      @value[0, 4].unpack1('N')
    end

    # The route target as an extended community, and only when all 64 of
    # its bits are there. Section 4 puts no constraint on which extended
    # community it is, so this is whatever factory makes of the octets,
    # which for anything but a route target sub-type is an Unknown that
    # replays them.
    #
    # **Both halves of the condition are load bearing**, unlike the one
    # above. A length of 89 to 95 bits occupies twelve octets, so the
    # community's octets are all there and only the length says its last
    # bits are padding; without the length check a community would be
    # reported that the sender did not send. Found by sabotage, which
    # also found that the test stepped over that whole band.
    def route_target
      return nil unless @mlen >= AS_BITS + RT_BITS and @value.size >= 12
      Extended_community.factory(@value[4, 8].is_packed)
    end

    # The octets of the route target that are there when it is partial,
    # which is the documented use, as hex. nil when there are none and
    # when it is whole, since route_target answers then. The hex is what
    # arrived and nothing is inferred from the length, which a peer can
    # have overstated; mlen is next to it for the caller to compare.
    def route_target_bits
      return nil if @mlen <= AS_BITS or @mlen >= AS_BITS + RT_BITS
      @value[4..-1].to_s.unpack1('H*')
    end

    # The whole prefix as hex and its length, which is the only honest
    # view of a length no field of the RFC covers.
    def bits
      [@value.unpack1('H*'), @mlen]
    end

    def encode
      s = +''
      s << [@path_id].pack('N') if @path_id
      s << [@mlen].pack('C') << @value
    end

    def to_shex(*args)
      encode(*args).unpack1('H*')
    end

    # Either the two named fields reproduce the octets or they do not,
    # and which is the only question. They do at exactly the two lengths
    # section 4's figure describes, 32 bits and 96, with the octets to
    # match; then the hash is those fields and nothing else, which is
    # what a test writing one by hand wants. Everything else is the
    # length and the octets verbatim: a partial route target, which is
    # the documented use, a length no RFC allows, or fewer octets than
    # the length demanded. Same rule as :tail and :bits elsewhere, where
    # the extra key is there only when the ordinary one cannot hold it.
    def to_hash
      h = {}
      h[:path_id] = @path_id if @path_id
      if default?
        h[:mlen] = 0
      elsif natural?
        h[:origin_as] = origin_as
        rt = route_target
        h[:route_target] = rt.to_hash if rt
      else
        h[:mlen] = @mlen
        h[:value] = @value.unpack1('H*')
      end
      h
    end

    def to_s
      s = +'RT constrain'
      s << " ID=#{@path_id}" if @path_id
      if default?
        s << ': default'
      elsif (rt = route_target)
        s << ": #{origin_as}, #{rt}"
      elsif (bits = route_target_bits)
        s << ": #{origin_as}, route target #{bits}"
      elsif (as = origin_as)
        s << ": #{as}"
      else
        s << ": #{@value.unpack1('H*')}"
      end
      # The length, whenever the fields above do not account for it: a
      # partial route target, one of the lengths section 4 forbids, or
      # fewer octets than the length claimed. Without this a 200-bit
      # prefix carrying 4 readable octets printed as an ordinary origin
      # AS and said nothing about the 200.
      s << "/#{@mlen}" unless default? or natural?
      s
    end

    def ==(other)
      other.is_a?(Rt_constrain) and encode == other.encode
    end

    private

    # Whether the two fields of section 4's figure account for the whole
    # prefix: one of its two lengths, with the octets to match.
    def natural?
      [AS_BITS, AS_BITS + RT_BITS].include?(@mlen) and
        @value.size == octets_for(@mlen)
    end

    # The octets a prefix of mlen bits occupies. Section 4's framing, and
    # the same arithmetic as every other prefix family.
    def octets_for(mlen)
      (mlen + 7) / 8
    end

    def parse(s)
      # No path_id is read here. RFC 7911 section 3 puts it in front of
      # the NLRI, and the parse loop reads it and hands it to new_ntop,
      # which is what every other family does.
      @mlen = s.slice!(0, 1).unpack1('C').to_i
      # Whatever arrived, so encode replays it. A peer that sent fewer
      # octets than its own length octet demands gets them back as it
      # sent them rather than padded out to what it claimed.
      @value = s.slice!(0, [octets_for(@mlen), s.size].min).to_s
    end

    def from_values(*args)
      as, rt, mlen = args
      @value = +''
      @value << [as.to_i].pack('N') unless as.nil?
      @value << rt_octets(rt) unless rt.nil?
      @mlen = mlen || (@value.size * 8)
      fit_to_mlen
    end

    # A route target given as a Route_target or any other extended
    # community, as the 64-bit Integer those answer with to_i, as the 8
    # octets themselves, or as the pair Route_target.new takes.
    def rt_octets(rt)
      case rt
      when Extended_community then rt.encode
      when Integer            then Extended_community.octets(rt)
      when Array              then Route_target.new(*rt).encode
      when String             then rt.dup
      else
        raise ArgumentError, "invalid route target #{rt.inspect}"
      end
    end

    # Build to exactly the width the length asks for: pad when the
    # fields are short of it, truncate when they overrun it, and zero
    # the bits past the length in the last octet, which is what an
    # encoder does with a prefix's padding. Parsing does none of this,
    # so a capture replays as it arrived.
    def fit_to_mlen
      want = octets_for(@mlen)
      @value = @value.ljust(want, "\x00")[0, want].to_s
      return if @mlen.zero? or (@mlen % 8).zero?
      keep = 0xff << (8 - (@mlen % 8)) & 0xff
      @value.setbyte(want - 1, @value.getbyte(want - 1) & keep)
    end

    def from_hash(h)
      @path_id = h[:path_id] if h[:path_id]
      if h[:value]
        @mlen = h[:mlen].to_i
        @value = [h[:value]].pack('H*')
        return
      end
      from_values(h[:origin_as], coerce_rt(h[:route_target]), h[:mlen])
    end

    # A route target from a hash, which is the wrapped form its own
    # to_hash answers with, {:route_target=>[65000, 100]}. Route_target
    # does not take that, so unwrap it first, the same thing
    # Extended_community::Typed#unwrap does one level down. A bare value
    # list and the hex of the 8 octets are taken too.
    #
    # The key is looked up in Extended_communities::HASH_BUILDERS rather
    # than turned into a class name, for three reasons: that table is
    # the one place the library already knows how to build a community
    # from its hash key, it covers every registered community and not
    # just the ones whose key capitalises to a class name, and a name
    # built with const_get on this class resolves up the ancestors to
    # Object and finds nothing, since the communities live under BGP.
    # The first draft did that and passed only because the probe had
    # include BGP at the top level, which is the trap Conventions
    # records; without it, NameError on
    # BGP::Extended_community::Route_target.
    def coerce_rt(rt)
      case rt
      when nil, Extended_community, Integer, Array then rt
      when String then Extended_community.factory([rt].pack('H*').is_packed)
      when Hash
        raise ArgumentError, "invalid route target #{rt.inspect}" if rt.size != 1
        key, value = rt.first
        build = Extended_communities::HASH_BUILDERS[key]
        raise ArgumentError, "invalid route target #{rt.inspect}" unless build
        build.call(value)
      else
        raise ArgumentError, "invalid route target #{rt.inspect}"
      end
    end

  end

end
