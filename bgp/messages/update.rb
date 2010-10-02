
# UPDATE Message Format
#  
#     UPDATE messages are used to transfer routing information between BGP
#     peers.  The information in the UPDATE message can be used to
#     construct a graph that describes the relationships of the various
#     Autonomous Systems.  By applying rules to be discussed, routing
#  
#  
#  
#  Rekhter, et al.             Standards Track                    [Page 14]
#  
#  RFC 4271                         BGP-4                      January 2006
#  
#  
#     information loops and some other anomalies may be detected and
#     removed from inter-AS routing.
#  
#     An UPDATE message is used to advertise feasible routes that share
#     common path Copyright 2008, 2009 to a peer, or to withdraw multiple unfeasible
#     routes from service (see 3.1).  An UPDATE message MAY simultaneously
#     advertise a feasible route and withdraw multiple unfeasible routes
#     from service.  The UPDATE message always includes the fixed-size BGP
#     header, and also includes the other fields, as shown below (note,
#     some of the shown fields may not be present in every UPDATE message):
#  
#        +-----------------------------------------------------+
#        |   Withdrawn Routes Length (2 octets)                |
#        +-----------------------------------------------------+
#        |   Withdrawn Routes (variable)                       |
#        +-----------------------------------------------------+
#        |   Total Path Attribute Length (2 octets)            |
#        +-----------------------------------------------------+
#        |   Path Attributes (variable)                        |
#        +-----------------------------------------------------+
#        |   Network Layer Reachability Information (variable) |
#        +-----------------------------------------------------+
#  

require 'bgp/messages/message'

module BGP

class Update < Message
  def as4byte?
    @as4byte ||= false
  end
  def initialize(*args)
    if args[0].is_a?(String) and args[0].is_packed?
      @as4byte=false
      parse(*args)
    elsif args[0].is_a?(self.class)
      parse(args[0].encode, *args[1..-1])
    else
      @msg_type=UPDATE
      set(*args)
    end
  end
  
  def set(*args)
    args.each { |arg|
      if arg.is_a?(Withdrawn)
        self.withdrawn=arg
      elsif arg.is_a?(Path_attribute)
        self.path_attribute = arg
      elsif arg.is_a?(Nlri)
        self.nlri = arg
      end
    }
  end
  
  def withdrawn=(val)
    @withdrawn=val if val.is_a?(Withdrawn)
  end
  
  def nlri=(val)
    @nlri=val if val.is_a?(Nlri)
  end
  
  def path_attribute=(val)
    @path_attribute=val if val.is_a?(Path_attribute)
  end
  
  #TODO refactor out passing an argument to encode...
  def encode(as4byte=@as4byte)
    withdrawn, path_attribute, nlri = '', '', ''
    withdrawn = @withdrawn.encode(false) if defined? @withdrawn and @withdrawn
    path_attribute = @path_attribute.encode(as4byte) if defined?(@path_attribute) and @path_attribute
    nlri = @nlri.encode if defined? @nlri and @nlri
    super([withdrawn.size, withdrawn, path_attribute.size, path_attribute, nlri].pack('na*na*a*'))
  end
  
  def encode4
    encode(true)
  end
  
  attr_reader :path_attribute, :nlri, :withdrawn
  
  # CHANGED ME: NO DEFAULT HERE, the factory calling us has to tell what it is giving us.
  def parse(s, as4byte=false)
    @as4byte=as4byte
    update = super(s)
    len = update.slice!(0,2).unpack('n')[0]
    self.withdrawn=Withdrawn.new(update.slice!(0,len).is_packed) if len>0
    len = update.slice!(0,2).unpack('n')[0]
    enc_path_attribute = update.slice!(0,len).is_packed
    self.path_attribute=Path_attribute.new(enc_path_attribute, as4byte) if len>0
    self.nlri = Nlri.new(update) if update.size>0
  end
  
  def <<(val)
    if val.is_a?(Attr)
      @path_attribute ||= Path_attribute.new
      @path_attribute << val
    elsif val.is_a?(String)
      begin 
        Nlri.new(val)
        @nlri ||=Nlri.new
        @nlri << val
      rescue => e
      end
    elsif val.is_a?(Nlri)
      val.to_s.split.each { |n| self << n }
    end
  end

  def to_s(as4byte=@as4byte, fmt=:tcpdump)
    msg = encode(as4byte)
    # if as4byte
    #   msg = self.encode(true)
    # else
    #   msg = self.encode
    # end
    s = []
    s << @withdrawn.to_s if defined?(@withdrawn) and @withdrawn
    s << @path_attribute.to_s(fmt, as4byte) if defined?(@path_attribute) and @path_attribute
    s << @nlri.to_s if defined?(@nlri) and @nlri
    "Update Message (#{MESSAGE::UPDATE}), #{as4byte ? "4 bytes AS, " : ''}length: #{msg.size}\n  " + s.join("\n") + "\n" + msg.hexlify.join("\n") + "\n"
  end
  
  def self.withdrawn(u)
    if u.nlri and u.nlri.size>0
      Update.new(Withdrawn.new(*(u.nlri.nlris.collect { |n| n.to_s})))
    elsif u.path_attribute.has?(Mp_reach)
      pa = Path_attribute.new
      pa << u.path_attribute[ATTR::MP_REACH].new_unreach
      Update.new(pa)
    end
  end
end

end