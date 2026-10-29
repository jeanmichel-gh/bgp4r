#--
# Copyright 2026 Jean-Michel Esnault.
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

module BGP
  module Rib
    class Fib

      # One Fib operation as an iproute2 command line.
      #
      # Building the command line and running it are separate on purpose:
      # argv is a pure function of the operation and the options, so every
      # command this would run is asserted in a unit test with no kernel
      # involved, on a machine with no iproute2 and as a user who could
      # not write a routing table anyway. Running them is the only impure
      # part of the FIB side.
      #
      # Every form here was checked against iproute2 6.1.0 in a network
      # namespace rather than recalled:
      #
      #   ip -n NS route replace P via N dev D table T proto bgp
      #   ip -n NS route del P table T proto bgp
      #   ip -n NS route show table T proto bgp
      #   ip -n NS route flush table T proto bgp
      #
      # What that measurement settled, and why each is used:
      #
      # replace rather than add, because replace on a prefix the table
      # does not have adds it, and on one it does have changes the next
      # hop in a single command. So one action covers both a new route and
      # a changed one, and re-running it is harmless, which matters for a
      # table that may be re-synced.
      #
      # **replace takes over a route of the same prefix that something
      # else owns**, and that is the price of it. Linux holds one route per
      # prefix in a table whatever the proto: `ip route add` for a prefix
      # already there answers "File exists" regardless of proto, and
      # replace overwrites it and marks it proto bgp, after which the flush
      # on the way out removes it. Measured, not assumed. So a table shared
      # with another daemon is only safe where the prefixes do not overlap;
      # give the FIB a table of its own otherwise, which is what table: has
      # no default for.
      #
      # proto on the flush is what protects the rest of a shared table: it
      # removes the routes this marked and nothing else, and a test proves
      # that by failing without it. proto on a del is a narrower guard,
      # since a del names one prefix and the kernel will not hold two
      # protos for it anyway; it is kept because it costs nothing and makes
      # the removal name exactly what this owns.
      #
      # dev is optional. The kernel resolves via against its connected
      # routes and picks the device itself, which is what a real FIB
      # wants. dev is there for a next hop the kernel cannot resolve,
      # which is the ordinary case in a test namespace.
      #
      # ip -n NS rather than ip netns exec NS ip, which is one process
      # rather than two and has been in iproute2 for years.
      class IpRoute

        DEFAULT_PROTO = 'bgp'

        # What running one command came to. output is stdout and stderr
        # together, because the interesting half of an `ip` failure is on
        # stderr and a caller wants it in the log beside the command.
        Result = Struct.new(:argv, :status, :output) do
          def ok? ; status.zero? ; end
          def command ; argv.join(' ') ; end
          def to_s
            ok? ? "ok: #{command}" :
                  "failed (#{status}): #{command}: #{output.to_s.strip}"
          end
        end

        attr_reader :table, :proto, :netns, :dev, :bin

        # table has no default, deliberately. Every other option here can
        # be wrong without much happening; a route written to the main
        # table changes where the machine sends its own traffic. Requiring
        # the number means nobody reaches the main table without naming
        # it. Any table is accepted once named, including the main one:
        # this refuses no value, it just will not pick one.
        # runner: something that takes an argv Array and answers a Result.
        # Given one, nothing here runs a process, which is how the unit
        # tests check what would be run without a kernel, root or iproute2.
        # It is useful outside the tests too: a runner is where `sudo`, a
        # remote shell, or a dry run that only logs would go.
        def initialize(table:, proto: DEFAULT_PROTO, netns: nil, dev: nil,
                       bin: 'ip', runner: nil)
          raise ArgumentError, 'table: is required' if table.nil?
          @table = table.to_s
          @proto = proto.to_s
          @netns = netns
          @dev = dev
          @bin = bin
          @runner = runner
        end

        # The command line for one operation, as an Array for Open3 and
        # friends, so nothing here is handed to a shell.
        def argv(op)
          raise ArgumentError, 'nothing to do' if op.nil?
          op.install? ? install_argv(op) : remove_argv(op)
        end

        # ip route show, narrowed to the routes this put there. Reading
        # the table back is how a test sees what the kernel made of a
        # command, and how a resync would find what is already there.
        #
        # The family is a separate argument here, where argv reads it off
        # the prefix, because a show has no prefix to read: ip shows one
        # family at a time, so a table holding both takes two commands.
        def show_argv(ipv6: false)
          base_argv(ipv6) + ['route', 'show'] + table_argv + proto_argv
        end

        # Removes every route this put in the table and nothing else,
        # which is what a FIB owes the machine on the way out.
        def flush_argv(ipv6: false)
          base_argv(ipv6) + ['route', 'flush'] + table_argv + proto_argv
        end

        # Runs one operation, and the three commands above, each answering
        # a Result. This is the only part of the FIB side that is not pure.
        def run(op) ; execute(argv(op)) ; end
        def show(ipv6: false) ; execute(show_argv(:ipv6 => ipv6)) ; end
        def flush(ipv6: false) ; execute(flush_argv(:ipv6 => ipv6)) ; end

        def to_s
          s = "ip route, table #{@table}, proto #{@proto}"
          s += ", netns #{@netns}" if @netns
          s += ", dev #{@dev}" if @dev
          s
        end

        private

        # IO.popen rather than Open3, which would read better. Open3 is a
        # default gem today, and Conventions in CLAUDE.md says to check that
        # before requiring one, because Ruby keeps moving these to bundled
        # gems where they fail to load under Bundler unless declared:
        # `observer` went in 3.4 and `logger` in 4.0. IO.popen is core, needs
        # no require, and does the whole job in a line, so the library keeps
        # its one runtime gem.
        #
        # The argv Array form never reaches a shell, so a prefix is an
        # argument and not a string anything has to quote. err: [:child,
        # :out] folds stderr in, since that is where `ip` says what went
        # wrong. $? is the child's status after the block.
        # ::IO and not IO. This file is inside module BGP, and bgp/io.rb
        # defines BGP::IO, so a bare IO resolves to that one through the
        # lexical scope and never reaches core Ruby: the error is
        # "undefined method `popen' for module BGP::IO". Same family as the
        # const_defined? trap in Conventions.
        def execute(argv)
          return @runner.call(argv) if @runner
          output = ::IO.popen(argv, :err => [:child, :out]) { |io| io.read }
          Result.new(argv, $?.exitstatus, output.to_s)
        rescue SystemCallError => e
          # No iproute2 on the machine at all, which is a failure like any
          # other rather than an exception the caller has to handle. The
          # status is one no exiting process produces.
          Result.new(argv, -1, e.message)
        end

        def install_argv(op)
          argv = base_argv(self.class.ipv6?(op.prefix))
          argv += ['route', 'replace', op.prefix.to_s]
          argv += ['via', op.next_hop.to_s]
          argv += ['dev', @dev.to_s] if @dev
          argv + table_argv + proto_argv
        end

        # No via and no dev on a del: the prefix, the table and the proto
        # name the route, and naming a next hop that has since changed
        # would mean matching nothing. See the class comment on what the
        # proto here does and does not buy.
        def remove_argv(op)
          base_argv(self.class.ipv6?(op.prefix)) +
            ['route', 'del', op.prefix.to_s] + table_argv + proto_argv
        end

        # ip takes the family and the namespace before the subcommand,
        # and -6 is needed because a v6 prefix with no -6 is rejected
        # rather than guessed.
        def base_argv(ipv6)
          argv = [@bin]
          argv += ['-6'] if ipv6
          argv += ['-n', @netns.to_s] if @netns
          argv
        end

        def table_argv ; ['table', @table] ; end
        def proto_argv ; ['proto', @proto] ; end

        # A prefix is v6 if it has a colon in it. The Loc-RIB keys on
        # prefix strings, so there is no address object here to ask.
        def self.ipv6?(prefix)
          prefix.to_s.include?(':')
        end

      end
    end
  end
end
