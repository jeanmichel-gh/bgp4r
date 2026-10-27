#    This file is part of BGP4R.
#
#    BGP4R is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    BGP4R is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with Foobar.  If not, see <http://www.gnu.org/licenses/>.

module Kernel
  alias :require_orig :require
  
  def my_caller(caller)
    caller.split('/')
  end
  
  def require(*args)
    #puts format("%-20s : %s", "require '#{args}'", caller[0])
    require_orig(*args)
  end
end

require 'ipaddr'
require 'logger'

class IPAddr
  alias encode hton

  def self.create(arg)
    if arg.is_a?(String) and arg.is_packed?
      IPAddr.new_ntoh(arg)
    elsif arg.is_a?(Integer)
      IPAddr.new_ntoh([arg].pack('N'))
    elsif arg.is_a?(Array) and arg[0].is_a?(Integer)
      IPAddr.new_ntoh(arg.pack('C*'))
    else
      IPAddr.new(arg)
    end
  end

  def mlen
    @_jme_mlen_ ||= _mlen_
  end

  def _generate_network_inc_
    max_len =  ipv4? ? 32 : 128
    Proc.new { |n| n*(2**(max_len - mlen)) }
  end
  # Newer ipaddr (the one in Ruby 4.0) defines IPAddr#+, returning an
  # IPAddr. bgp4r used to redefine it to return an "a.b.c.d/len" String.
  # That warned on Ruby 4.0 and changed IPAddr for every other library.
  # Only define it when ipaddr lacks it, with the same behavior as ipaddr.
  unless method_defined?(:+)
    def +(offset)
      clone.set(to_i + offset, family)
    end
  end
  
  def increment
    @increment ||= _generate_network_inc_
  end

  # The n-th network of this prefix's length, counting this one as 0, as
  # "a.b.c.d/len" or "x:x::/len". A negative n steps back.
  #
  # An IPv4 address is "fixed length of four octets (32 bits)", RFC 791
  # section 2.3, and "IPv6 addresses are 128-bit identifiers", RFC 4291
  # section 2. A result outside 0..IN4MASK, or 0..IN6MASK, is no address of
  # this family, so both families refuse it with IPAddr::InvalidAddressError.
  # That is what ipaddr's own IPAddr#set raises for an address outside its
  # family, so IPAddr#+ raises it too when it steps off the end, and the two
  # bgp4r operators now agree with each other and with ipaddr.
  #
  # The two families used to disagree. IPv4 wrapped silently through
  # pack('N'), so 255.255.255.0/24 stepped on to 0.0.0.0/24 and 0.0.0.0/0
  # stepped on to itself. IPv6 raised AddressFamilyError, because
  # format("%032x", n) of a value past 2**128 is 33 hex digits and
  # new_ntoh then got 17 octets; under the floor it was worse, since
  # format("%032x", -4) holds ".." and pack('H*') turned that into an octet,
  # so ::/126 stepped back to eeff:ffff:ffff:ffff:ffff:ffff:ffff:fffc/126.
  def nth_network(n)
    x = to_i + increment.call(n)
    max = ipv4? ? IN4MASK : IN6MASK
    unless (0..max) === x
      raise IPAddr::InvalidAddressError,
            "#{self}/#{mlen} stepped by #{n} is outside " \
            "#{IPAddr.new(0, family)}..#{IPAddr.new(max, family)}"
    end
    [IPAddr.new(x, family).to_s, mlen].join("/")
  end

  # ipaddr has &, |, ~, << and >>, but no ^, on Ruby 3.3, 3.4 and 4.0, so
  # this adds an operator rather than redefining one. It is not bitwise xor:
  # it steps whole networks. Prefer nth_network, the name no future ipaddr
  # can take.
  def ^(n)
    nth_network(n)
  end

  private :_generate_network_inc_

  private 
  
  def _mlen_
    m = @mask_addr
    len =  ipv6? ? 128 : 32
    # A prefix of length 0, the default route, has an all zero mask. There
    # is no set bit for the loop below to stop on, so it would shift zero
    # forever. Answer the floor of 0 here instead. RFC 4271 section 4.3
    # encodes a default route as a length octet of 0 and no prefix octets.
    return 0 if m == 0
    loop do
      break if m & 1 > 0
      m = m >> 1
      len += -1
    end
    len
  end

end

class Object
  def to_shex(*args)
    self.respond_to?(:encode) ? self.encode(*args).unpack('H*')[0] : ""
  end
  alias to_s_hexlify to_shex
  def to_shex4(*args)
    self.respond_to?(:encode4) ? self.encode4(*args).unpack('H*')[0] : ""
  end
  def to_shex_len(len, *args)
    s = to_shex(*args)
    "#{s[0..len]}#{s.size>len ? '...' : ''}"
  end
  def to_shex4_len(len, *args)
    s = to_shex4(*args)
    "#{s[0..len]}#{s.size>len ? '...' : ''}"
  end
end

class Array
  alias_method :old_pack, :pack
  def pack(*args)
    s = self.old_pack(*args)
    s.instance_eval { @__is_packed__ = true }
    s
  end
end

class String
  def is_packed?
    defined?(@__is_packed__) and @__is_packed__
  end
  def is_packed
     @__is_packed__ = true 
     self
  end
  alias packed? :is_packed?
  
  def hexlify
    return self unless is_packed? or self.size==0
    l,n,ls,s=0,0,[''],self.dup
    while s.size>0
      l = s.slice!(0,16)
      ls << format("0x%4.4x:  %s", n, l.unpack("n#{l.size/2}").collect { |x| format("%4.4x",x) }.join(' '))
      n+=1
    end
    if l.size%2 >0
      ns = if l.size>1 then 1 else 0 end
      # There used to be a RUBY_VERSION test here, with an else branch that
      # passed l[-1] straight to format. That was for Ruby 1.8, where l[-1]
      # was an Integer. Since 1.9 it is a one character String, which format
      # cannot take, so the branch could not run on any Ruby bgp4r supports.
      ls.last << format("%s%2.2x",' '*ns,l[-1].unpack('C')[0])
    end
    ls
  end
  
end

class Log  < Logger
  private_class_method :new 
  @@logger = nil
  def initialize(s)
    super(s)
    @@time=Time.now
    self.datetime_format = "%M:%S"
    self.level = Logger::INFO
  end 
  def Log.time_reset
    @@time = Time.now
  end
  def Log.create(s=STDERR)
    @@logger ||= new(s)
  end
  def Log.set_filename(s)
    @@logger = new(s)
  end 
  def Log.level=(level)
    return unless (0..4) === level
    @@logger.level=(level)
  end 
  def Log.level
    case @@logger.level
    when Logger::INFO ;  "(#{Logger::INFO }) 'INFO'"
    when Logger::DEBUG ; "(#{Logger::DEBUG }) 'DEBUG'"
    when Logger::WARN ;  "(#{Logger::WARN }) 'WARN'"
    when Logger::ERROR ; "(#{Logger::ERROR }) 'ERROR'"
    when Logger::FATAL ; "(#{Logger::FATAL }) 'FATAL'"
    end
  end
  def Log.clear
    name = Log.filename
    return unless name # logging to a stream such as STDERR: nothing to clear
    @@logger.close
    File.delete(name) if File.exist?(name)
    Log.set_filename(name)
  end
  def Log.filename
    @@logger.instance_eval { @logdev.filename }
  end
  def Log.start(*arg)
    Log.create(*arg)
  end 
  def Log.info(txt)
    @@logger.info(txt) unless @@logger.nil?
  end
  def Log.fatal(txt)
    @@logger.fatal(txt) unless @@logger.nil?
  end
  def Log.error(txt)
    @@logger.error(txt) unless @@logger.nil?
  end
  def Log.debug(txt)
    @@logger.debug(txt) unless @@logger.nil?
  end
  def Log.warn(txt)
    @@logger.warn(txt) unless @@logger.nil?
  end
  def Log.<<(txt)
    elapsed = Time.now - @@time
    @@logger << "<< #{format "%4.6f", elapsed}: #{txt}\n" unless @@logger.nil?
  end
  def Log.>>(txt)
    elapsed = Time.now.to_f - @@time.to_f
    @@logger << ">> #{format "%4.6f", elapsed}: #{txt}\n" unless @@logger.nil?
  end
end 

