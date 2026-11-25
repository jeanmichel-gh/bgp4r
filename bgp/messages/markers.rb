require 'bgp/messages/update'
module BGP

  # The End-of-RIB marker, RFC 4724 section 2: "An UPDATE message with no
  # reachable Network Layer Reachability Information (NLRI) and empty
  # withdrawn NLRI is specified as the End-of-RIB marker". For IPv4
  # unicast it is the UPDATE of minimum length, 23 octets; "For any other
  # address family, it is an UPDATE message that contains only the
  # MP_UNREACH_NLRI attribute [BGP-MP] with no withdrawn routes for that
  # <AFI, SAFI>."
  #
  #   Update.end_of_rib_marker                       # IPv4 unicast
  #   Update.end_of_rib_marker(:afi=>2, :safi=>1)    # IPv6 unicast
  def Update.end_of_rib_marker(*args)
    if args.empty?
      Update.new(Path_attribute.new()) if args.empty?
    elsif args[0].is_a?(Hash)
      Update.new(Path_attribute.new(Mp_unreach.new(*args)))
    end
  end

  class Update

    # The <AFI, SAFI> this UPDATE is the End-of-RIB marker of, as
    # [afi, safi], or nil when it is not one. The two shapes of RFC 4724
    # section 2 and nothing else: no withdrawn routes, no NLRI, and either
    # no path attribute at all, which is IPv4 unicast's, or one
    # MP_UNREACH_NLRI with no routes. An UPDATE that also carries another
    # attribute is not a marker.
    def end_of_rib
      return nil unless Update.blank?(withdrawn) && Update.blank?(nlri)
      pa = path_attribute
      return [1, 1] if pa.nil? || pa.size.zero?
      return nil unless pa.size == 1 && pa.has?(Mp_unreach)
      mp = pa[:mp_unreach]
      mp.nlris.empty? ? [mp.afi, mp.safi] : nil
    end

    # True when a withdrawn routes or NLRI field holds nothing.
    def self.blank?(field)
      field.nil? || field.encode.empty?
    end
  end
end
