
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
require 'bgp/optional_parameters/capability'
require 'ipaddr'

module BGP

class Open < Message
  
  include OPT_PARM
  
  AS_TRANS=23456
  
  attr_reader :version, :local_as, :holdtime, :opt_parms
  
  def initialize(*args)
    @opt_parms=[]
    if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
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
    opt_parms = @opt_parms.compact.collect { |cap| cap.encode }.join
    s  = [@version, _my_encoded_as_, @holdtime, @bgp_id.hton].pack("Cnna4")
    s += if opt_parms.size>255
      [0xffff, opt_parms.size, opt_parms].pack("nna*")
    else
      [opt_parms.size, opt_parms].pack("Ca*")
    end
    super s
  end
  
  def bgp_id
    @bgp_id.to_s
  end
  
  def to_s
    msg = self.encode
    "Open Message (#{OPEN}), length: #{msg.size}\n" +
    "  Version #{@version}, my AS #{_my_encoded_as_}, Holdtime #{@holdtime}s, ID #{@bgp_id}" +
    ([""] + @opt_parms.compact.collect { |cap| cap.to_s } + [""]).join("\n  ") +
    msg.hexlify.join("\n") + "\n"
  end
  
  def find(klass)
    @opt_parms.find { |a| a.is_a?(klass) }
  end
  
  def has?(klass)
     @opt_parms.find { |a| a.is_a?(klass) }
  end
  
  def to_hash
    h = {:version => @version, :my_as => @local_as, :holdtime => @holdtime, :bgp_id => bgp_id }
    unless @opt_parms.empty?
      h[:capabilities] =  @opt_parms.collect { |opt| opt.to_hash }
    end
    h
  end
  
  private

  def _my_encoded_as_
    @local_as > 0xffff ? AS_TRANS : @local_as
  end
  
  def parse(_s)
    s = super(_s)
    if s[9,2].unpack('CC') == [255,255]
      @version, @local_as, @holdtime, bgp_id, _, opt_parm_len, opt_parms = s.unpack('Cnna4nna*')
    else
      @version, @local_as, @holdtime, bgp_id, opt_parm_len, opt_parms = s.unpack('Cnna4Ca*')
    end
    while opt_parms.size>0
      @opt_parms << Optional_parameter.factory(opt_parms)
    end
    @bgp_id = IPAddr.new_ntoh(bgp_id)
  end
   
end

end

load "../../test/unit/messages/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
