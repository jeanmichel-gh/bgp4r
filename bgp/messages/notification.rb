
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

  @code_to_s=Hash.new("Undefined")
  @code_to_s[[1]]    = "Header Error"
  @code_to_s[[2]]    = "OPEN msg error"
  @code_to_s[[3]]    = "UPDATE msg error"
  @code_to_s[[4]]    = "Hold Timer Expired"
  @code_to_s[[5]]    = "Finite State Machine Error"
  @code_to_s[[6]]    = "Cease"
  @code_to_s[[7]]    = "CAPABILITY Message Error"
  @code_to_s[[1,1]]  = "Connection Not Synchronized"
  @code_to_s[[1,2]]  = "Bad Message Length"
  @code_to_s[[1,3]]  = "Bad Message Type"    
  @code_to_s[[2,1]]  = "Unsupported Version Number"
  @code_to_s[[2,2]]  = "Bad Peer AS"                    
  @code_to_s[[2,3]]  = "Bad BGP Identifier"             
  @code_to_s[[2,4]]  = "Unsupported Optional Parameter" 
  @code_to_s[[2,5]]  = "[Deprecated]"                   
  @code_to_s[[2,6]]  = "Unacceptable Hold Time"         
  @code_to_s[[2,7]]  = "Unsupported Optional Parameter"
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
  @code_to_s[[6,1]]  = "Maximum Number of Prefixes Reached"
  @code_to_s[[6,2]]  = "Administrative Shutdown"
  @code_to_s[[6,3]]  = "Peer De-configured"
  @code_to_s[[6,4]]  = "Administrative Reset"
  @code_to_s[[6,5]]  = "Connection Rejected"
  @code_to_s[[6,6]]  = "Other Configuration Change"
  @code_to_s[[6,7]]  = "Connection Collision Resolution"
  @code_to_s[[6,8]]  = "Out of Resources"
  @code_to_s[[7,1]]  = "Unknown Sequence Number"
  @code_to_s[[7,2]]  = "Invalid Capability Length"
  @code_to_s[[7,3]]  = "Malformed Capability Value"
  @code_to_s[[7,4]]  = "Unsupported Capability Code"
  
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
