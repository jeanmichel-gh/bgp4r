
# NOTIFICATION Message Format
#  
#     A NOTIFICATION message is sent when an error condition is detected.
#     The BGP connection is closed immediately after it is sent.
#  
#  
#  
#  
#  Rekhter, et al.             Standards Track                    [Page 21]
#  
#  RFC 4271                         BGP-4                      January 2006
#  
#  
#     In addition to the fixed-size BGP header, the NOTIFICATION message
#     contains the following fields:
#  
#        0                   1                   2                   3
#        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        | Error code    | Error subcode |   Data (variable)             |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#

require 'bgp/messages/message'

module BGP

class Notification < Message

  def self.code_to_s(*args)
    @code_to_s[args]
  end

  # The IANA "BGP Error (Notification) Codes" registry. Codes 10 to 255 are
  # unassigned, and a code or subcode with no entry here reads "Undefined",
  # which is the honest answer for a code point IANA has not given a name.
  #
  # Value 0 is named in the error code registry and in five of the six
  # subcode registries, and was in none of them here: every one of those
  # read "Undefined", which was less than this table knew. Each is below
  # beside the others of its registry.
  @code_to_s=Hash.new("Undefined")
  # The error code registry names 0 "Reserved" and gives no reference for
  # it. A NOTIFICATION carrying it is not a code bgp4r has yet to learn.
  @code_to_s[[0]]    = "Reserved"
  @code_to_s[[1]]    = "Header Error"
  @code_to_s[[2]]    = "OPEN msg error"
  @code_to_s[[3]]    = "UPDATE msg error"
  @code_to_s[[4]]    = "Hold Timer Expired"
  @code_to_s[[5]]    = "Finite State Machine Error"
  @code_to_s[[6]]    = "Cease"
  # RFC 7313 section 5 and section 6: IANA allocated code 7 as
  # "ROUTE-REFRESH Message Error" and created the "BGP ROUTE-REFRESH
  # Message Error subcodes" registry for it. bgp4r named it "CAPABILITY
  # Message Error" with the subcodes of the expired dynamic capability
  # draft, which IANA never registered against code 7.
  @code_to_s[[7]]    = "ROUTE-REFRESH Message Error"
  @code_to_s[[8]]    = "Send Hold Timer Expired"       # RFC 9687 section 9
  @code_to_s[[9]]    = "Loss of LSDB Synchronization"  # RFC 9815 section 8.6
  # Subcode 0 of the Message Header, OPEN and UPDATE registries is
  # "Unspecific", which IANA references to RFC Errata 4493 rather than to a
  # section of RFC 4271. The registry is what was read here, not the
  # erratum, which is not fetchable from this sandbox.
  @code_to_s[[1,0]]  = "Unspecific"
  @code_to_s[[1,1]]  = "Connection Not Synchronized"
  @code_to_s[[1,2]]  = "Bad Message Length"
  @code_to_s[[1,3]]  = "Bad Message Type"    
  @code_to_s[[2,0]]  = "Unspecific"
  @code_to_s[[2,1]]  = "Unsupported Version Number"
  @code_to_s[[2,2]]  = "Bad Peer AS"                    
  @code_to_s[[2,3]]  = "Bad BGP Identifier"             
  @code_to_s[[2,4]]  = "Unsupported Optional Parameter" 
  @code_to_s[[2,5]]  = "[Deprecated]"                   
  @code_to_s[[2,6]]  = "Unacceptable Hold Time"         
  # RFC 5492 section 5: "The value of this Subcode is 7." Subcode 7 used to
  # repeat the name of subcode 4, and the two are different errors: RFC 4271
  # section 6.2 sends 4 for an Optional Parameter Type it does not
  # recognize, RFC 5492 sends 7 for a capability carried inside one.
  @code_to_s[[2,7]]  = "Unsupported Capability"
  # RFC 9234 section 7: "Due to improper use of the values 8, 9, and 10,
  # IANA has marked values 8-10 as "Deprecated"" in the "OPEN Message Error
  # subcodes" registry, and registered 11 as "Role Mismatch". Section 4.2
  # is what sends 11: two Roles that do not form one of its three pairs,
  # or, under its strict mode, a peer that advertised no BGP Role
  # capability. bgp4r names the subcode and sends it when a script says
  # to; it does not compare the Roles itself.
  @code_to_s[[2,8]]  = "Deprecated"
  @code_to_s[[2,9]]  = "Deprecated"
  @code_to_s[[2,10]] = "Deprecated"
  @code_to_s[[2,11]] = "Role Mismatch"
  @code_to_s[[3,0]]  = "Unspecific"
  @code_to_s[[3,1]]  = "Malformed Attribute List"
  @code_to_s[[3,2]]  = "Unrecognized Well-known Attribute"  
  @code_to_s[[3,3]]  = "Missing Well-known Attribute"       
  @code_to_s[[3,4]]  = "Attribute Flags Error"              
  @code_to_s[[3,5]]  = "Attribute Length Error"             
  @code_to_s[[3,6]]  = "Invalid ORIGIN Attribute"           
  @code_to_s[[3,7]]  = "Deprecated"                       
  @code_to_s[[3,8]]  = "Invalid NEXT_HOP Attribute"         
  @code_to_s[[3,9]]  = "Optional Attribute Error"           
  @code_to_s[[3,10]] = "Invalid Network Field"             
  @code_to_s[[3,11]] = "Malformed AS_PATH"
  # Code 4, Hold Timer Expired, has no subcode registry at all, so there is
  # nothing to name under it and its subcode octet reads "Undefined". That
  # is deliberate rather than a gap: the IANA BGP Parameters page lists a
  # subcode registry for codes 1, 2, 3, 5, 6 and 7 and none for 4.
  #
  # RFC 6608 section 3: the four Finite State Machine Error subcodes. It
  # lists "0 - Unspecified Error" with the three below it, and IANA
  # references the whole registry to RFC 6608.
  @code_to_s[[5,0]]  = "Unspecified Error"
  @code_to_s[[5,1]]  = "Receive Unexpected Message in OpenSent State"
  @code_to_s[[5,2]]  = "Receive Unexpected Message in OpenConfirm State"
  @code_to_s[[5,3]]  = "Receive Unexpected Message in Established State"
  # The Cease registry names 0 "Reserved" and gives no reference for it,
  # the same way the error code registry does.
  @code_to_s[[6,0]]  = "Reserved"
  @code_to_s[[6,1]]  = "Maximum Number of Prefixes Reached"
  @code_to_s[[6,2]]  = "Administrative Shutdown"
  @code_to_s[[6,3]]  = "Peer De-configured"
  @code_to_s[[6,4]]  = "Administrative Reset"
  @code_to_s[[6,5]]  = "Connection Rejected"
  @code_to_s[[6,6]]  = "Other Configuration Change"
  @code_to_s[[6,7]]  = "Connection Collision Resolution"
  @code_to_s[[6,8]]  = "Out of Resources"
  # The IANA "BGP Cease NOTIFICATION message subcodes" registry adds these
  # two to the eight of RFC 4486, referencing the RFC named on each.
  @code_to_s[[6,9]]  = "Hard Reset"  # RFC 8538
  @code_to_s[[6,10]] = "BFD Down"    # RFC 9384
  # RFC 7313 section 6 created the "BGP ROUTE-REFRESH Message Error
  # subcodes" registry: 0 Reserved, 1 "Invalid Message Length", 2 to 255
  # unassigned. Section 5 is what sends subcode 1. The four names that used
  # to be here, Unknown Sequence Number, Invalid Capability Length,
  # Malformed Capability Value and Unsupported Capability Code, come from
  # the expired dynamic capability draft; against code 7 they name code
  # points IANA leaves unassigned.
  @code_to_s[[7,0]]  = "Reserved"
  @code_to_s[[7,1]]  = "Invalid Message Length"

  def initialize(*args)
    @msg_type=NOTIFICATION
    if args.size==1  and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    elsif args[0].is_a?(self.class)
      parse(args[0].encode, *args[1..-1])
    elsif args.size==1  and args[0].is_a?(Notification) and args[0].respond_to?(:encode)
        parse(args[0].encode)
    else
      @code, @subcode, @data=args
    end
  end

  def encode
    # default to ipv4 and unicast when not set
    super([@code,@subcode, @data].pack('CCa*'))
  end

  def parse(s)
    @code, @subcode, @data= super(s).unpack('CCa*')
  end

  def to_hash
    {:code=> @code, :subcode=> @subcode, :data=>@data}
  end

  def to_string
    Notification.code_to_s(@code, @subcode)
  end

  def to_s
    msg = self.encode
    s = "Notification (#{NOTIFICATION}), length: #{msg.size}: "
    s += "#{Notification.code_to_s(@code)} (#{@code}), #{Notification.code_to_s(@code, @subcode)} (#{@subcode}) " 
    s += "\ndata: [#{@data}]" if @data and @data.size>0
    s
  end

end
end
