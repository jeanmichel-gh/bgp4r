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


require 'observer'
require 'thread'
require 'timeout'
require 'bgp/common'
require 'bgp/messages/message'


module BGP
  module IO

    class Output < Queue
      include Observable
      def initialize(session, holdtime, *obs)
        @session, @holdtime = session, holdtime
        obs.each { |o| add_observer(o) }
        @continue = true
        super()
      end
      attr_reader :thread
      attr_writer :holdtime
      def start
        @thread = Thread.new(@session, @holdtime) do |s, h|
          Thread.current['name']='BGP IO Ouput'
          Log.debug "#{self} #{Thread.current} started" 
          begin
            while @continue
              obj = deq
              break unless @continue
              s.write obj.respond_to?(:encode) ? obj.encode : obj
            end
          rescue IOError, Errno::ECONNRESET, Errno::EBADF => e
            changed and notify_observers(:ev_conn_reset, e)
          ensure
            Log.debug "Exiting #{Thread.current['name']}"
          end
        end
      end
      def exit
        @continue = false
        enq('you\'re done dude!')
      end
    end

    class Input
      include Observable
      def initialize(session, holdtime, *obs)
        @session, @holdtime = session, holdtime
        obs.each { |o| add_observer(o) }
      end
      attr_reader :thread
      attr_writer :holdtime
      def recv_msg(s)
        loop do
          if @buf.size<18 or @buf.size <@len
            recv = s.recv(4100) 
            @buf += recv unless recv.nil?
            break unless @continue
          end
          if @buf.size>18
            @len, @type=@buf[16,3].unpack('nC')
            if @len<=@buf.size
              bgp_message = @buf.slice!(0,@len) 
              return bgp_message
            end 
          end
        end
      end
      
      def start
        @thread = Thread.new(@session, @holdtime) do |s, h|
          Thread.current['name']='BGP IO Input'
          Log.debug "#{self} #{Thread.current} started"
          @buf = ''
          @continue = true
          @len=0
          begin
            while @continue
              begin
                Timeout::timeout(h) do |_h| 
                  message, type = recv_msg(s)
                  break unless @continue
                  changed and notify_observers(:ev_msg, @type, message)
                end
              rescue Timeout::Error => e
                changed and notify_observers(:ev_holdtime_expire, e)
                @continue = false
              end
            end
          rescue IOError, Errno::ECONNRESET, Errno::EBADF => e
            changed and notify_observers(:ev_conn_reset, e)
          end
          Log.debug "Exiting #{Thread.current['name']}"
        end 
      end
    end
  end
end