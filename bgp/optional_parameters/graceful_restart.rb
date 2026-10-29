#--
# Copyright 2010, 2026 Jean-Michel Esnault.
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

require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM::CAP
  
class Graceful_restart < BGP::OPT_PARM::Capability 
  
  def initialize(*args)
    if args.size>1
      @restart_state, @restart_time = args
      @tuples = []
      super(OPT_PARM::CAP_GR)
    elsif args.size==1 and args[0].is_a?(Hash)
      # Its own hash, and the inner one alone. Neither was read: a Hash
      # went to parse, which called slice! on it, so this capability had
      # no hash build path at all.
      h = args[0]
      h = h[:capability] if h.key?(:capability)
      @restart_state, @restart_time = h[:restart_state].to_i, h[:restart_time].to_i
      @tuples = []
      super(OPT_PARM::CAP_GR)
      [h[:families]].flatten.compact.each { |f| add(f[:afi], f[:safi], f[:flags].to_i) }
    else
      parse(*args)
    end
  end
  
  def add(afi,safi,af_flags=0)
    @tuples << [_afi(afi), _safi(safi), af_flags]
  end

  def parse(s)
    @tuples = []
    o1, families = super(s).unpack('na*')
    @restart_state = o1 >> 12
    @restart_time = o1 & 0xfff
    while families.size>0
      @tuples << families.slice!(0,4).unpack('nCC')
    end
  end


  def encode(extended: false)
    s = []
    s << [(@restart_state << 12) + @restart_time].pack('n')
    s << @tuples.collect { |af| af.pack('nCC') }
    super s.join, :extended => extended
  end
  # Everything the capability carries. RFC 4724 section 3, "Graceful
  # Restart Capability": Restart Flags (4 bits), Restart Time in seconds
  # (12 bits), then per family Address Family Identifier (16 bits),
  # Subsequent Address Family Identifier (8 bits) and Flags for Address
  # Family (8 bits). The key is :restart_state because that is what this
  # class has always called the Restart Flags field, whose most
  # significant bit section 3 defines as the Restart State (R).
  #
  # It used to inherit Capability's bare {:code=>64}, so the restart
  # state, the restart time and every family were lost together.
  def to_hash
    super.merge(:capability => {
      :restart_state => @restart_state, :restart_time => @restart_time,
      :families => @tuples.collect { |afi, safi, flags|
        { :afi => afi, :safi => safi, :flags => flags } } })
  end

  def to_s
    s = []
    s <<  "\n    Graceful Restart Extension (#{CAP_GR}), length: #{encode.size}"
    s <<  "    Restart Flags: #{restart_flag}, Restart Time #{@restart_time}s"
    s = s.join("\n  ")
    super + (s + (['']+@tuples.collect { |af| address_family(*af)}).join("\n        "))
  end

  # The restart time is what a peer acts on, so the brief form keeps it
  # rather than the capability's name alone.
  def to_s_brief
    "Graceful Restart #{@restart_time}s"
  end

  def method_missing(name, *args, &block)
    if name.to_s =~ /^(.+)_forwarding_state_(.+)/
      state = $2
      afi_safi = $1
      afi, *safi = afi_safi.to_s.split('_')
      _afi  = IANA.afi?(afi.to_sym)
      _safi = IANA.safi?((safi.join('_')).to_sym)
      if state == 'preserved'
        _state = 0x80
      elsif state == 'not_preserved'
        _state = 0
      else
        super
      end
      if _afi and _safi
        add _afi,_safi, _state
      else
        super
      end
    else
      super
    end
  end
  
  private
  
  def address_family(afi, safi, flags)
    "AFI #{IANA.afi_s(afi)}, SAFI #{IANA.safi_s(safi)}, #{address_family_flags(flags)}"
  end
  
  def restart_flag
    if @restart_state == 0
      '[none]'
    else
      "0x#{@restart_state}"
    end
  end
  
  def address_family_flags(flags)
    if flags & 0x80 == 0
      "Forwarding state not preserved (0x#{flags.to_s(16)})"
    elsif flags & 0x80 == 0x80
      "Forwarding state preserved (0x#{flags.to_s(16)})"
    else
      "Flags (0x#{flags.to_s(16)}"
    end
  end
  
  def _afi(val)
    IANA.afi(val)
  end
  
  def _safi(val)
    IANA.safi(val)
  end
  
end
end

load "../../test/unit/optional_parameters/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0


