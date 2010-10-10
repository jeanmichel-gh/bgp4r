#--
# Copyright 2010 Jean-Michel Esnault.
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

require 'bgp4r'
require 'bgp/optional_parameters/capability'

module BGP::OPT_PARM
  module CAP
  end
end

module BGP
  
  class Capability < Message
    
    class Revision
      
      class <<self
        
        def advertise(seqn, cap)
          new :unset, :unset, :advertise, seqn, cap
        end
        def advertise_ack_request(seqn, cap)
          new :unset, :set, :advertise, seqn, cap
        end
        def advertise_ack_response(seqn, cap)
          new :set, :unset, :advertise, seqn, cap
        end
        def remove(seqn, cap)
          new :unset, :unset, :remove, seqn, cap
        end
        def remove_ack_request(seqn, cap)
          new :unset, :set, :remove, seqn, cap
        end
        def remove_ack_response(seqn, cap)
          new :set, :unset, :remove, seqn, cap
        end
       
      end
      
      def initialize(*args)
        if args.size> 1
          init_ack_bit, ack_request_bit, action_bit, seqn, cap = args
          @o1 = 0
          @o1 |= 0x80  if init_ack_bit    == :set
          @o1 &= ~0x80  if init_ack_bit    == :unset
          @o1 |= 0x40  if ack_request_bit == :set
          @o1 &= ~0x40  if ack_request_bit == :unset
          @o1 |= 1     if action_bit      == :remove
          @o1 &= ~1    if action_bit      == :advertise
          @seqn = seqn
          @cap = cap
        elsif args.size==1 && args.is_a?(String)
      else
        parse args[0]
      end
      end
      
      def encode
        [@o1,@seqn, @cap.encode].pack('CNa*')
      end
      
      def parse(s)
        @o1, @seqn, @code, len = s.slice!(0,8).unpack('CNCn')
        cap_value = s.slice!(0,len)
        @cap = BGP::OPT_PARM::Capability.dynamic_factory([@code,len,cap_value].pack('Cna*'))
      end
      
      def to_s
        format('0x%08d  %-9s  %3s (0x%02x)  %s', @seqn, action_to_s, ack_to_s, @o1, cap_to_s)
      end
      
      def initiated?
        ! acknowledged?
      end
      
      def acknowledged?
        @o1 & 0x80 > 1
      end
      
      def ack_requested?
        @o1& 0x40 > 1
      end
      
      def advertise?
        !remove?
      end
      
      def remove?
        @o1 & 1 == 1
      end

      def init_ack_to_s
        initiated? ? '' : '(ack)'
      end
      
      private
      
      def ack_to_s
        if ack_requested?
          'Req'
        elsif acknowledged?
          'Rsp'
        end
      end

      def action_to_s
        advertise? ? 'Advertise' : 'Withdraw'
      end

      def cap_to_s
        @cap.to_s_brief
      end
      
      def seqn_to_s
        format('0x%08x', @seqn)
      end
      
    end
    
    def initialize(*args)
      @tuples =[]
      if args.size==1 and args[0].is_a?(String)
        parse args[0]
      else
        @msg_type=CAPABILITY
        add *args
      end
    end

    def add(*revisions)
      [revisions].flatten.find_all { |r| r.is_a?(Capability::Revision)}.each { |r| @tuples << r }
    end
    
    alias << add

    def encode
      super @tuples.collect { |r| r.encode }.join
    end

    def parse(s)
      revisions = super(s)
      while revisions.size>0
        @tuples << BGP::Capability::Revision.new(revisions)
      end
    end
    
    def to_s
      msg = self.encode
      "Capability (#{CAPABILITY}), length: #{msg.size}\n" +
      "  Seqn        Action     Ack bits    Capability\n  " + 
        @tuples.collect { |t| t.to_s}.join("\n  ")
    end
    
  end
end
