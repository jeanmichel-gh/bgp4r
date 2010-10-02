
# OPEN Message Format
# 
#    After a TCP connection is established, the first message sent by each
#    side is an OPEN message.  If the OPEN message is acceptable, a
#    KEEPALIVE message confirming the OPEN is sent back.
# 
#    In addition to the fixed-size BGP header, the OPEN message contains
#    the following fields:
# 
#        0                   1                   2                   3
#        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#        +-+-+-+-+-+-+-+-+
#        |    Version    |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |     My Autonomous System      |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |           Hold Time           |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                         BGP Identifier                        |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        | Opt Parm Len  |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
#        |                                                               |
#        |             Optional Parameters (variable)                    |
#        |                                                               |
#        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
# 
# 
require 'bgp/messages/message'

module BGP

class Open < Message

  include OPT_PARM
  
  attr_reader :version, :local_as, :holdtime, :opt_parms

  def initialize(*args)
    if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
      @opt_parms=[] # FIMXE: should not have ot init here
      parse(args[0])
    elsif args[0].is_a?(self.class)
      parse(args[0].encode, *args[1..-1])
    else
      @msg_type=OPEN
      @version, @local_as, @holdtime, bgp_id, *@opt_parms=args
      @bgp_id = IPAddr.new(bgp_id)
    end
  end

  def <<(arg)
    raise ArgumentError, "arg is not an Optional_parameter" unless arg.is_a?(Optional_parameter)
    @opt_parms << arg
  end

  def encode
    opt_parms = @opt_parms.flatten.compact.collect { |cap| cap.encode }.join
    super([@version, @local_as, @holdtime, @bgp_id.hton, opt_parms.size, opt_parms].pack('Cnna4Ca*'))
  end

  def parse(s)
    @version, @local_as, @holdtime, bgp_id, opt_parm_len, opt_parms = super(s).unpack('Cnna4Ca*')
    while opt_parms.size>0
      begin
        @opt_parms << Optional_parameter.factory(opt_parms)
      rescue UnknownBGPCapability => e
        puts "#{e}"
      end
    end
    @bgp_id = IPAddr.new_ntoh(bgp_id)
  end
  
  def bgp_id
    @bgp_id.to_s
  end
  
  def to_s
    msg = self.encode
    "Open Message (#{OPEN}), length: #{msg.size}\n" +
    "  Version #{@version}, my AS #{@local_as}, Holdtime #{@holdtime}s, ID #{@bgp_id}" + 
    ([""] + @opt_parms.compact.collect { |cap| cap.to_s } + [""]).join("\n  ") +
    msg.hexlify.join("\n") + "\n"
  end
  
  def find(klass)
    @opt_parms.find { |a| a.is_a?(klass) }
  end
  
  def has?(klass)
     @opt_parms.find { |a| a.is_a?(klass) }.nil? ? false : true
  end
  
  def to_hash
    h = {:version => @version, :my_as => @local_as, :holdtime => @holdtime, :bgp_id => bgp_id }
    unless @opt_parms.empty?
      h[:capabilities] =  @opt_parms.collect { |opt| opt.to_hash }
    end
    h
  end
end

end