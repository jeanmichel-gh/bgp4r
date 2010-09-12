#--
# Copyright 2008, 2009 Jean-Michel Esnault.
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

require 'bgp/path_attribute'
require 'bgp/nlri'
require 'timeout'

module BGP

  class UnknownBgpCapability < RuntimeError
  end

  class UnknownBgpMessage < RuntimeError
  end

  module OPT_PARM

    CAPABILITY = 2
    
    #TODO module CAP
    #TODO module CAP::ORF
    
    CAP_MBGP = 1
    CAP_ROUTE_REFRESH = 2
    CAP_ORF = 3
    CAP_AS4 = 65
    CAP_ROUTE_REFRESH_CISCO = 128
    CAP_ORF_CISCO = 130
    
    ORF_NLRI = 1
    ORF_COMMUNITIES = 2
    ORF_EXTENDED_COMMUNITIES = 3
    ORF_PREFIX_LIST = 129    

    ##########################################################
    # BGP OPEN OPTION PARAMETERS                             #
    ##########################################################

    class Optional_parameter

      def initialize(parm_type)
        @parm_type=parm_type
      end

      def encode(value)
        [@parm_type, value.size, value].pack('CCa*')
      end

      def parse(s)
        @parm_type, len = s.slice!(0,2).unpack('CC')
        s.slice!(0,len).is_packed
      end

      def self.factory(s)
        parm_type, len = s.unpack('CC')
        opt_parm = s.slice!(0,len+2).is_packed
        case parm_type
        when CAPABILITY
          Capability.factory(opt_parm)
        else
          raise RuntimeError, "Optional parameter type '#{parm_type}' not implemented"
        end
      end

    end
  end


  class Capability < OPT_PARM::Optional_parameter
    include OPT_PARM
    def initialize(code)
      super(OPT_PARM::CAPABILITY)
      @code=code
    end
    def encode(value='')
      super([@code,value.size, value].pack('CCa*'))
    end
    def parse(_s)
      s = super(_s)
      @code, len = s.slice!(0,2).unpack('CC')
      s.slice!(0,len).is_packed
    end
    def to_s
      "Option Capabilities Advertisement (#{@parm_type}): [#{to_shex}]"
    end
    def self.factory(s)
      code = s.slice(2,1).unpack('C')[0]
      case code
      when CAP_AS4
        As4_cap.new(s)
      when CAP_MBGP
        Mbgp_cap.new(s)
      when CAP_ROUTE_REFRESH, CAP_ROUTE_REFRESH_CISCO
        Route_refresh_cap.new(code)
      when CAP_ORF,CAP_ORF_CISCO
        Orf_cap.new(s)
      else
        raise UnknownBgpCapability, "Capability (#{code}), length: #{s.size} not implemented: [#{s.unpack('H*')[0]}]" 
      end
    end
    def to_hash(h={})
      if h.empty?
        {:code=> @code}
      else
        {:code=> @code, :capability=> h}
      end
    end
  end

  class Mbgp_cap < Capability

    def self.ipv4_unicast
      Mbgp_cap.new(1,1)
    end
    
    def self.ipv4_multicast
      Mbgp_cap.new(1,2)      
    end
    
    def self.ipv6_unicast
      Mbgp_cap.new(2,2)      
    end
    
    def self.ipv6_multicast
      Mbgp_cap.new(2,2)      
    end

    def initialize(afi,safi=nil)
      if safi.nil? and afi.is_a?(String) and afi.is_packed?
        parse(afi)
      else
        super(OPT_PARM::CAP_MBGP)
        self.safi, self.afi = safi, afi
      end
    end
    
    def afi=(val)
      @afi = if val.is_a?(Fixnum)
        val
      elsif val == :ipv4
        1
      elsif val == :ipv6
        2
      end
    end
    
    def safi=(val)
      @safi = if val.is_a?(Fixnum)
        val
      elsif val == :unicast
        1
      elsif val == :multicast
        2
      end
    end

    def encode
      super([@afi,0,@safi].pack('nCC'))
    end

    def parse(s)
      @afi, ignore, @safi = super(s).unpack('nCC')
    end

    def to_s
      super + "\n    Multiprotocol Extensions (#{CAP_MBGP}), length: 4" +
      "\n      AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi})"
    end

    def to_hash
      super({:afi => @afi, :safi => @safi, })
    end
  end

  class As4_cap < Capability
    def initialize(s)
      if s.is_a?(String) and s.is_packed?
        parse(s)
      else
        super(OPT_PARM::CAP_AS4)
        @as=s
      end
    end
    
    def encode
      super([@as].pack('N'))
    end

    def parse(s)
      @as = super(s).unpack('N')[0]
    end

    def to_s
      "Capability(#{CAP_AS4}): 4-octet AS number: " + @as.to_s
    end

    def to_hash
      super({:as => @as})
    end
  end

  class Route_refresh_cap < Capability 
    def initialize(code=OPT_PARM::CAP_ROUTE_REFRESH)
      super(code)
    end

    def encode
      super()
    end

    def to_s
      super + "\n    Route Refresh #{@code==128 ? "(Cisco) " : ""}(#{@code}), length: 2"
    end

    def to_hash
      super()
    end
  end

  class Orf_cap < Capability

    class Entry
      
      def initialize(*args)
        if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
          parse(args[0])
        elsif args[0].is_a?(Hash) 
        else
          @afi, @safi, *@types = *args
        end
      end
      
      def encode
        [@afi, 0, @safi, @types.size,@types.collect { |e| e.pack('CC')}.join].pack('nCCCa*')
      end
      
      def parse(s)
        @afi, __, @safi, n = s.slice!(0,5).unpack('nCCC')
        @types=[]
        types = s.slice!(0, 2*n)
        while types.size>0
          @types<< types. slice!(0,2).unpack('CC')
        end
      end
      
      def to_s
        "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi}): #{@types.inspect}"
      end
    end

    def initialize(*args)
      @entries=[]
      if args.size==1 and args[0].is_a?(String) and args[0].is_packed?
        parse(args[0])
      else
        super(OPT_PARM::CAP_ORF)
      end
    end

    def add(entry)
      @entries << entry
    end

    def encode
      super(@entries.collect { |e| e.encode }.join)
    end

    def parse(s)
      entries = super(s)
      while entries.size>0
        @entries << Entry.new(entries)
      end
    end

    def to_s
      super + "\n    Outbound Route Filtering (#{@code}), length: #{encode.size}" +
      (['']+@entries.collect { |e| e.to_s }).join("\n      ")
    end

  end

   # http://www.iana.org/assignments/bgp-parameters/bgp-parameters.xhtml#bgp-parameters-1
  module MESSAGE

    OPEN          = 1
    UPDATE        = 2
    NOTIFICATION  = 3
    KEEPALIVE     = 4
    ROUTE_REFRESH = 5

    def encode(message='')
      len = message.size+19
      [[255]*16,len,@msg_type,message].flatten.pack('C16nCa*')
    end

    def parse(s)
      len, @msg_type, message = s[16..-1].unpack('nCa*')
      message.is_packed
    end

  end

  class Message
    include MESSAGE
    def self.factory(_s, as4byte=false)
      s = [_s].pack('a*')
      s.slice(18,1).unpack('C')[0]
      case s.slice(18,1).unpack('C')[0]
      when OPEN
        Open.new(s)
      when UPDATE
        Update.new(s, as4byte)
      when KEEPALIVE
        Keepalive.new
      when NOTIFICATION
        Notification.new(s)
      when ROUTE_REFRESH
        if s.size > 23  
          Orf_route_refresh.new(s)
        else
          Route_refresh.new(s)
        end
      else
        puts "don't know what kind of bgp messgage this is #{s.slice(18,1).unpack('C')}"
      end
    end
    def self.keepalive
      Keepalive.new.encode
    end
    def self.route_refresh(afi,safi)
      Route_refresh.new(afi,safi).encode
    end    
  end

  # KEEPALIVE Message Format
  # 
  #    BGP does not use any TCP-based, keep-alive mechanism to determine if
  #    peers are reachable.  Instead, KEEPALIVE messages are exchanged
  #    between peers often enough not to cause the Hold Timer to expire.  A
  #    reasonable maximum time between KEEPALIVE messages would be one third
  #    of the Hold Time interval.  KEEPALIVE messages MUST NOT be sent more
  #    frequently than one per second.  An implementation MAY adjust the
  #    rate at which it sends KEEPALIVE messages as a function of the Hold
  #    Time interval.
  # 
  #    If the negotiated Hold Time interval is zero, then periodic KEEPALIVE
  #    messages MUST NOT be sent.
  # 
  #    A KEEPALIVE message consists of only the message header and has a
  #    length of 19 octets.
  #
  
  class Keepalive < Message
    def initialize
      @msg_type=KEEPALIVE
    end

    def to_s
      "Keepalive Message (#{MESSAGE::KEEPALIVE}), length: 19" + ", [#{self.to_shex[32..-1]}]"
    end
  end

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
      "Open Message (#{MESSAGE::OPEN}), length: #{msg.size}\n" +
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
      "Route Refresh (#{MESSAGE::ROUTE_REFRESH}), length: #{msg.size}\n" +   "AFI #{IANA.afi(@afi)} (#{@afi}), SAFI #{IANA.safi(@safi)} (#{@safi})"
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
      "ORF Route Refresh (#{MESSAGE::ROUTE_REFRESH}), length: #{msg.size}\n" +   
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
      s = "Notification (#{MESSAGE::NOTIFICATION}), length: #{msg.size}: "
      s += "#{Notification.code_to_s(@code)} (#{@code}), #{Notification.code_to_s(@code, @subcode)} (#{@subcode}) " 
      s += "\ndata: [#{@data}]" if @data.size>0
      s
    end

  end

 #  s = 'ffffffffffffffffffffffffffffffff0050020000002f40010101400304c0a80105800404000000644005040000006440020402010064c0080c051f00010137003b0af50040200a0a0a0a2020202020'
 #  m = Message.factory([s].pack('H*'))
 #  puts m.to_s(true, :tcpdump)
 #  puts m.to_s(true, :default)
 #  puts m.to_s(false, :default)

end

load "../test/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


