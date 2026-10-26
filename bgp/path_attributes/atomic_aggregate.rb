#--
# Copyright 2008, 2009, 2026 Jean-Michel Esnault.
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


require 'bgp/path_attributes/attribute'

module BGP

  class Atomic_aggregate < Attr
    def initialize(arg=nil)
      # RFC 4271 section 4.3: ATOMIC_AGGREGATE is well-known discretionary,
      # so the Transitive bit is set and the Optional bit is not.
      @flags, @type=WELL_KNOWN_DISCRETIONARY, ATOMIC_AGGREGATE
      if arg.is_a?(String) and arg.is_packed?
        parse(arg)
      elsif arg.nil?
      else
        raise ArgumentError, "invalid argument, #{arg.class} #{arg}"
      end
    end
    def to_hash
      {}
    end

    private

    # Keep the flags received, so an attribute parsed from the wire is
    # encoded back as it came, odd flags included.
    def parse(s)
      @flags, @type, _ = super(s)
    end
  end

  Attr.register(ATTR::ATOMIC_AGGREGATE, Atomic_aggregate, :atomic_aggregate) { Atomic_aggregate.new }

end

load "../../test/unit/path_attributes/#{ File.basename($0.gsub(/.rb/,'_test.rb'))}" if __FILE__ == $0
