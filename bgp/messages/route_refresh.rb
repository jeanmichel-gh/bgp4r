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
    raise ArgumentError, "invalid argument" unless val.is_a?(Integer) and (0..0xffff) === val
    @afi=val
  end
  
  def safi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Integer) and (0..0xff) === val
    @safi=val
  end
  
  def encode
    # default to ipv4 and unicast when not set
    @afi ||=1
    @safi ||=1
    super([@afi, 0, @safi].pack('nCC'))
  end
  
  def parse(s)
    @afi, _, @safi= super(s).unpack('nCC')
  end
  
  def to_hash
    {:afi=> @afi, :safi=> @safi}
  end
  
  def to_s
    msg = self.encode
    "Route Refresh (#{ROUTE_REFRESH}), length: #{msg.size}\n" +   "AFI #{IANA.afi?(@afi)} (#{@afi}), SAFI #{IANA.safi?(@safi)} (#{@safi})"
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
  # RFC 5291 section 4: an ORF is an ORF Type octet, a two octet Length of
  # ORF entries and the entries. The AFI comes from the message carrying
  # the ORF.
  def self.factory(s, afi=1)
    type, len = s.unpack('Cn')
    # Fewer than three octets cannot hold an ORF header, so there is no
    # Length of ORF entries to trust and no type to dispatch on. Keep what
    # is left rather than reading a length that is not there.
    return Orf::Unknown.new(s.slice!(0,s.size).is_packed, afi) if len.nil?
    case type
    when ORF::PREFIX, ORF::PREFIX_CISCO
      # RFC 5292 section 3 assigns 64 to the Address Prefix ORF. 130 is the
      # vendor code point of the RFC 5291 section 7 range that bgp4r sends
      # from Prefix_orf#cisco_prefix_entry_type; no RFC covers it. The
      # layout behind it is the prefix ORF's, Prefix_orf#_parse_ reads it
      # already and keeps whatever type octet it finds, so read it as a
      # prefix ORF. An operator then sees the entries of what bgp4r sent,
      # and encode gives back the same octets, type 130 included.
      Prefix_orf.new(s.slice!(0,len+3).is_packed, afi)
    else
      # Any other ORF Type keeps its octets and writes them back. Raising
      # here took down the parse of the whole ROUTE-REFRESH, and RFC 5291
      # section 7 leaves the types 128 to 255 to vendors, so an ORF with no
      # class of its own is a thing that arrives, not a thing to refuse.
      Orf::Unknown.new(s.slice!(0,len+3).is_packed, afi)
    end
  end

  # The hash form names the ORF Type too, so the type picks the class there
  # as it does on the wire. Without this, every hash became a Prefix_orf and
  # the hash of an ORF Type bgp4r does not implement did not round trip: its
  # entry octets went missing.
  def self.from_hash(h)
    case h[:type]
    when nil, ORF::PREFIX, ORF::PREFIX_CISCO
      Prefix_orf.new(h)
    else
      Orf::Unknown.new(h)
    end
  end
end

class Orf_route_refresh < Message
  
  attr_accessor :orfs
  
  # RFC 5291 section 4: the When-to-refresh octet is IMMEDIATE (1) or
  # DEFER (2).
  IMMEDIATE = 1
  DEFER     = 2

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
      self.when = args[0][:when] if args[0][:when]
      [args[0][:orfs]].flatten.compact.each do |orf|
        add(orf.is_a?(Hash) ? Orf.from_hash(orf) : orf)
      end
    else
      @afi, @safi, *orfs = args
      add(*orfs.flatten)
    end
  end
  
  def afi_to_i
    @afi
  end
  
  def safi_to_i
    @safi
  end
  
  def afi
    IANA.afi?(@afi)
  end
  
  def safi
     IANA.safi?(@safi)
  end
  
  def afi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Integer) and (0..0xffff) === val
    @afi=val
  end
  
  def safi=(val)
    raise ArgumentError, "invalid argument" unless val.is_a?(Integer) and (0..0xff) === val
    @safi=val
  end
  
  def when_to_i
    @when
  end

  # RFC 5291 section 4: When-to-refresh is one octet. Any value a single
  # octet holds still encodes, so a router can be watched handling one the
  # RFC does not define.
  def when=(val)
    case val
    when :immediate ; @when=IMMEDIATE
    when :defer     ; @when=DEFER
    when Integer
      raise ArgumentError, "invalid argument" unless (0..0xff) === val
      @when=val
    else
      raise ArgumentError, "invalid argument: #{val.inspect}"
    end
  end

  def when_to_s
    case @when
    when IMMEDIATE ; 'immediate (1)'
    when DEFER     ; 'defer (2)'
    else
      "bogus (#{@when})"
    end
  end
  
  def encode
    # RFC 5291 section 4: AFI, Reserved, SAFI, When-to-refresh, then the
    # ORFs. Default to IMMEDIATE when the caller did not say.
    @when ||= IMMEDIATE
    super([@afi, 0, @safi, @when, @orfs.collect { |o| o.encode }.join].pack('nCCCa*'))
  end
  
  def parse(s)
    # RFC 5291 section 4: the When-to-refresh octet sits between the SAFI
    # and the first ORF. A body too short to hold it carries no ORF either.
    @afi, _, @safi, @when, orfs= super(s).unpack('nCCCa*')
    while orfs and orfs.size>0
      @orfs << Orf.factory(orfs.is_packed, @afi)
    end
  end
  
  def to_hash
    h = {:afi=> @afi, :safi=> @safi}
    h[:when] = @when if @when
    h[:orfs] = @orfs.collect { |orf| orf.to_hash } unless @orfs.empty?
    h
  end
  
  def to_s
    msg = self.encode
    "ORF Route Refresh (#{ROUTE_REFRESH}), length: #{msg.size}\n" +   
    "AFI #{IANA.afi?(@afi)} (#{@afi}), SAFI #{IANA.safi?(@safi)} (#{@safi}), when-to-refresh #{when_to_s}:\n" +
    @orfs.collect { |orf| orf.to_s}.join("\n")
  end
  
  # RFC 5291 section 4: the message carries ORFs, so this takes ORFs. An ORF
  # whose type, action or entries no RFC allows still goes on the wire; what
  # is refused here is only something that is not an ORF at all. That is a
  # caller mistake, not a protocol choice, and no field of the message can
  # hold it. Dropping it to no effect built a message with no ORF, which is
  # 24 octets a router takes and ignores, and the caller heard nothing: the
  # same silent wrong answer new(afi,safi,orf) gave before #101, and the
  # constructor hands its third and later arguments straight to here.
  def add(*args)
    @orfs ||=[]
    args.each do |arg|
      raise ArgumentError, "invalid argument: #{arg.inspect}, expected an ORF" unless arg.is_a?(Orf)
      @orfs << arg
    end
    self
  end
  alias << add
  
end

end
