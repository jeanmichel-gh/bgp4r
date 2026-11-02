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

require 'socket'

module BGP
  module Daemon

    # Talks to `bgp4rd` over its Unix socket: writes one request line,
    # reads one reply line. See `bgp/daemon/api.rb` for the envelope and
    # where it comes from.
    #
    # It is the other half of the socket and nothing else, so
    # `bgp/daemon/cli.rb` can be tested against a real daemon and a test
    # can call one method without a command line.
    class Client

      # Where `bgp4rd` puts its socket with no `--socket`.
      #
      # **`$XDG_RUNTIME_DIR` is the fallback and the reason is that an
      # unprivileged standalone run must work with no arguments beyond
      # the configuration file.** `/run/bgp4r` needs root to create, and
      # the recorded requirement is no root in the ordinary case, so a
      # path under the user's own runtime directory is tried next and the
      # temporary directory last. Both ends compute it the same way,
      # which is why it is here and not in either program.
      DEFAULT_DIR    = '/run/bgp4r'
      DEFAULT_SOCKET = 'bgp4rd.sock'

      # The first of the directories below whose parent this process may
      # write, with /run/bgp4r when none of them is: a path that cannot
      # be created still names the place to look, which reads better
      # than a client with no path at all.
      #
      # `dirs` is the seam the tests use, because on a machine running
      # as root the first candidate is always writable and the fallbacks
      # are unreachable otherwise.
      def self.default_socket(env = ENV, dirs = nil)
        dir = (dirs || candidates(env)).find { |d| writable_parent?(d) }
        File.join(dir || DEFAULT_DIR, DEFAULT_SOCKET)
      end

      # Where to look, in order.
      def self.candidates(env = ENV)
        [DEFAULT_DIR,
         env['XDG_RUNTIME_DIR'] && File.join(env['XDG_RUNTIME_DIR'], 'bgp4r'),
         File.join(tmp_dir(env), 'bgp4r')].compact
      end

      # The temporary directory, without `require 'tmpdir'`.
      #
      # Conventions says to check that a standard library is still a
      # default gem before requiring it, and records it biting twice. The
      # one value wanted here is read from the same environment variables
      # `Dir.tmpdir` reads, with the same `/tmp` fallback, which needs no
      # require and adds no method to a core class.
      def self.tmp_dir(env = ENV)
        %w[TMPDIR TMP TEMP].each do |name|
          v = env[name]
          return v if v && !v.empty? && File.directory?(v) && File.writable?(v)
        end
        '/tmp'
      end

      # A directory this process can create or already write.
      def self.writable_parent?(dir)
        return File.writable?(dir) if File.directory?(dir)
        parent = File.dirname(dir)
        File.directory?(parent) && File.writable?(parent)
      end

      # Raised for anything the caller can read and act on: no daemon, no
      # permission, or the daemon's own error message.
      class Error < StandardError ; end

      attr_reader :path

      def initialize(path = nil, env = ENV)
        @path = path || env['BGP4R_SOCKET'] || Client.default_socket(env)
        @id   = 0
        @sock = nil
      end

      # Calls one method and returns its result, or raises Error with the
      # daemon's own message.
      def call(method, params = {})
        require 'json'
        connect
        @id += 1
        @sock.write("#{JSON.generate(:id => @id, :method => method, :params => params)}\n")
        line = @sock.gets or raise Error, 'bgp4rd closed the connection'
        reply = JSON.parse(line)
        raise Error, reply['error'] if reply['error']
        reply['result']
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        @sock = nil
        raise Error, 'lost the connection to bgp4rd'
      rescue JSON::ParserError => e
        raise Error, "bgp4rd answered something that is not JSON: #{e.message[0, 120]}"
      end

      def close
        @sock.close if @sock && !@sock.closed?
        @sock = nil
      end

      private

      def connect
        @sock ||= UNIXSocket.new(@path)
      rescue Errno::ENOENT, Errno::ECONNREFUSED
        raise Error, "cannot reach bgp4rd at #{@path}: is it running?"
      rescue Errno::EACCES
        raise Error, "permission denied on #{@path}: the socket is mode 0660"
      end

    end

  end
end
