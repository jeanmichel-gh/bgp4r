
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
#    RFC 9072 section 2 replaces that one octet Opt Parm Len, and the one
#    octet Parameter Length inside each optional parameter, with two octet
#    fields when the Optional Parameters run past 255 octets. Open#encode
#    and Open#parse have the detail.
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

  # Octets at the end of the Optional Parameters field that are not a
  # parameter. RFC 4271 section 4.2 gives a parameter a 1 octet Parameter
  # Type and a 1 octet Parameter Length, and RFC 9072 section 2 widens the
  # length to two, so fewer octets than that cannot be one and nothing
  # holds them but the message. Kept and written back, the same rule and
  # the same :tail key as an attribute that keeps octets it cannot
  # interpret, and as Orf_route_refresh keeps a leftover of its own.
  attr_reader :tail

  # The Optional Parameters Length that arrived, when it is not the number
  # of octets that followed it. parse reads the parameters to the end of
  # the message body and never used this field, so a peer that sent the
  # wrong length had it quietly corrected by encode. nil on a message
  # built from values, which always writes its own.
  attr_reader :declared_opt_parm_len
  
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

  # True when this OPEN carries the extended Optional Parameters Length
  # of RFC 9072 section 2 rather than the one octet length of RFC 4271.
  # parse sets it, so a message read in the extended form is written
  # back in it whatever its size: section 2 says "an implementation MUST
  # accept an OPEN message that uses the encoding of this specification"
  # even when the parameters are 255 octets or fewer. The writer is
  # there so that form can be sent with any parameter list at all.
  def extended?
    @extended ? true : false
  end

  attr_writer :extended

  # RFC 9072 section 2, Figure 1 "Extended Encoding OPEN Format": when
  # the Optional Parameters run past 255 octets, the one octet Optional
  # Parameters Length becomes a Non-Ext OP Len. octet, which "SHOULD be
  # set to 255 on transmission", and a Non-Ext OP Type octet of 255,
  # which is the type code the document "reserves ... as the 'Extended
  # Length'". After them comes the two octet Extended Optional
  # Parameters Length, "an unsigned integer indicating the total length
  # of the Optional Parameters field in octets".
  #
  # Each parameter inside changes with it. Figure 2 "Extended Parameters
  # Format" in the same section: "The rules for encoding Optional
  # Parameters are unchanged with respect to those given in [RFC4271],
  # except that the Parameter Length field is extended to be a
  # two-octet unsigned integer." bgp4r wrote the one octet length there,
  # which was self consistent and wrong on the wire, so it is passed
  # down now.
  #
  # The form depends on the size and the size depends on the form, so
  # the RFC 4271 encoding is measured first. It is one octet per
  # parameter shorter than the extended one, so if it already runs past
  # 255 octets only the extended form can carry it.
  def encode
    parms = @opt_parms.compact
    extended = extended?
    opt_parms = parms.collect { |cap| cap.encode(:extended => extended) }.join + @tail.to_s
    if !extended and opt_parms.size>255
      extended = true
      opt_parms = parms.collect { |cap| cap.encode(:extended => true) }.join + @tail.to_s
    end
    # The length that arrived when it did not agree with the octets, so a
    # malformed OPEN a negative test captured can be sent again.
    len = @declared_opt_parm_len || opt_parms.size
    s  = [@version, _my_encoded_as_, @holdtime, @bgp_id.hton].pack("Cnna4")
    s += if extended
      [0xff, 0xff, len, opt_parms].pack("CCna*")
    else
      [len, opt_parms].pack("Ca*")
    end
    super s
  end
  
  def bgp_id
    @bgp_id.to_s
  end
  
  def to_s
    msg = self.encode
    notes = []
    notes << "Optional Parameters Length says #{@declared_opt_parm_len}" if @declared_opt_parm_len
    notes << "#{@tail.size} octet#{@tail.size==1 ? '' : 's'} that is not a parameter: " \
             "[#{@tail.unpack('H*')[0]}]" if @tail
    "Open Message (#{OPEN}), length: #{msg.size}\n" +
    "  Version #{@version}, my AS #{_my_encoded_as_}, Holdtime #{@holdtime}s, ID #{@bgp_id}" +
    ([""] + @opt_parms.compact.collect { |cap| cap.to_s } + notes + [""]).join("\n  ") +
    msg.hexlify.join("\n") + "\n"
  end
  
  def find(klass)
    @opt_parms.find { |a| a.is_a?(klass) }
  end
  
  def has?(klass)
     @opt_parms.find { |a| a.is_a?(klass) }
  end
  
  # No leftover and no disagreeing length means neither key, so the hash of
  # an ordinary OPEN is the one it has always been.
  def to_hash
    h = {:version => @version, :my_as => @local_as, :holdtime => @holdtime, :bgp_id => bgp_id }
    unless @opt_parms.empty?
      h[:capabilities] =  @opt_parms.collect { |opt| opt.to_hash }
    end
    h[:tail] = @tail.unpack('H*')[0] if @tail
    h[:opt_parm_len] = @declared_opt_parm_len if @declared_opt_parm_len
    h
  end
  
  private

  def _my_encoded_as_
    @local_as > 0xffff ? AS_TRANS : @local_as
  end
  
  def parse(_s)
    s = super(_s)
    # The octet after the one octet Optional Parameters Length is the
    # Non-Ext OP Type of RFC 9072 section 2, Figure 1, and "On receipt,
    # a value of 255 for this field is the indication that the extended
    # format is in use". That octet alone decides: the Non-Ext OP Len.
    # before it "MUST be ignored on receipt once the use of the extended
    # format is determined positively", so a peer that writes something
    # other than the recommended 255 there is still read correctly.
    # bgp4r used to require 255 in both.
    @extended = s.getbyte(10) == 255
    if @extended
      @version, @local_as, @holdtime, bgp_id, _, _, declared, opt_parms = s.unpack('Cnna4CCna*')
    else
      @version, @local_as, @holdtime, bgp_id, declared, opt_parms = s.unpack('Cnna4Ca*')
    end
    # RFC 4271 section 4.2: "Optional Parameters Length ... indicates the
    # total length of the Optional Parameters field in octets". The
    # parameters are read to the end of the message body rather than to
    # this length, since the message header length already bounds them, so
    # it is only kept here when it disagrees with what followed it.
    @declared_opt_parm_len = declared if declared != opt_parms.size
    while opt_parms.size>0
      # One parameter can carry several capabilities (RFC 5492 section 4).
      parms = Optional_parameter.factory(opt_parms, :extended => @extended)
      if parms.nil?
        # Not a whole parameter header left, so not a parameter: keep the
        # rest as it is.
        @tail = opt_parms.slice!(0, opt_parms.size)
        break
      end
      @opt_parms.concat parms
    end
    @bgp_id = IPAddr.new_ntoh(bgp_id)
  end
   
end

end

load "../../test/unit/messages/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
