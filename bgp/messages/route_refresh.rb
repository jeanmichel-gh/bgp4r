#  Route-REFRESH Message
#  
#     The ROUTE-REFRESH message is a new BGP message type defined as
#     follows:
#  
#            Type: 5 - ROUTE-REFRESH
#  
#            Message Format: One <AFI, SAFI> encoded as
#  
#                    0       7      15      23      31
#                    +-------+-------+-------+-------+
#                    |      AFI      | Res.  | SAFI  |
#                    +-------+-------+-------+-------+
#  


require 'bgp/messages/message'

module BGP

class Route_refresh < Message
  attr_reader :afi, :safi
  def initialize(*args)
    @msg_type=ROUTE_REFRESH
    if args.size==1  and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    elsif args[0].is_a?(self.class)
      parse(args[0].encode, *args[1..-1])
    elsif args.size==1 and args[0].is_a?(Hash)
      self.afi = args[0][:afi] if args[0][:afi]
      self.safi = args[0][:safi] if args[0][:safi]
    else
      @afi, @safi=args
    end
  end
  
  def afi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Fixnum) and (0..0xffff) === val
    @afi=val
  end
  
  def safi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Fixnum) and (0..0xff) === val
    @safi=val
  end
  
  def encode
    # default to ipv4 and unicast when not set
    @afi ||=1
    @safi ||=1
    super([@afi, 0, @safi].pack('nCC'))
  end
  
  def parse(s)
    @afi, reserved, @safi= super(s).unpack('nCC')
  end
  
  def to_hash
    {:afi=> @afi, :safi=> @safi}
  end
  
  def to_s
    msg = self.encode
    "Route Refresh (#{ROUTE_REFRESH}), length: #{msg.size}\n" +   "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi})"
  end
end

#
#  Carrying ORF Entries in BGP
#  
#     ORF entries are carried in the BGP ROUTE-REFRESH message [BGP-RR].
#  
#     A BGP speaker can distinguish an incoming ROUTE-REFRESH message that
#     carries one or more ORF entries from an incoming plain ROUTE-REFRESH
#     message by using the Message Length field in the BGP message header.
#

class Orf
  def self.factory(s)
    type, len = s.unpack('Cn')
    case type
    when ORF::PREFIX 
      Prefix_orf.new(s.slice!(0,len+3).is_packed)
    else
      raise RuntimeError, "orf type #{type} not implemented"
    end
  end
end

#FIXME: Unit-test
class Orf_route_refresh < Message
  
  attr_accessor :orfs
  
  def initialize(*args)
    @msg_type=ROUTE_REFRESH
    @orfs=[]
    if args.size==1  and args[0].is_a?(String) and args[0].is_packed?
      parse(args[0])
    elsif args[0].is_a?(self.class)
      parse(args[0].encode, *args[1..-1])
    elsif args.size==1 and args[0].is_a?(Hash)
      self.afi = args[0][:afi] if args[0][:afi]
      self.safi = args[0][:safi] if args[0][:safi]
    else
      @afi, @safi=args
    end
  end
  
  def afi_to_i
    @afi
  end
  
  def safi_to_i
    @safi
  end
  
  def afi
    IANA.afi(@afi)
  end
  
  def safi
     IANA.safi(@safi)
  end
  
  def afi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Fixnum) and (0..0xffff) === val
    @afi=val
  end
  
  def safi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Fixnum) and (0..0xff) === val
    @safi=val
  end
  
  def when_to_s
    case @when
    when 1 ; 'defer (1)'
    when 2 ; 'immediate (2)'
    else
      "bogus (#{@when})"
    end
  end
  
  def encode
    super([@afi, 0, @safi, @orfs.collect { |o| o.encode }.join].pack('nCCa*'))
  end
  
  def parse(s)
    @afi, reserved, @safi, orfs= super(s).unpack('nCCa*')
    while orfs.size>0
      #puts "orfs before factory: #{orfs.unpack('H*')}"
      @orfs << Orf.factory(orfs.is_packed)
      #puts "orfs after factory: #{orfs.unpack('H*')}"
    end
  end
  
  def to_hash
    {:afi=> @afi, :safi=> @safi}
  end
  
  def to_s
    msg = self.encode
    "ORF Route Refresh (#{ROUTE_REFRESH}), length: #{msg.size}\n" +   
    "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi}):\n" +
    @orfs.collect { |orf| orf.to_s}.join("\n")
  end
  
  def add(*args)
    @orfs ||=[]
    args.each {  |arg| @orfs << arg if arg.is_a?(Orf) }
  end
  alias << add
  
  def communities
    @communities.collect { |comm| comm.to_s }.join(' ')
  end
  
end

end