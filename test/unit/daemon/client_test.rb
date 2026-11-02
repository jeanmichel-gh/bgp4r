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

# Where the client looks for the socket, and what it says when it cannot
# reach one. Talking to a real daemon is test/functional/daemon_test.rb.
#
#   ruby -I. test/unit/daemon/client_test.rb

require 'test/unit'
require 'tmpdir'
require 'fileutils'
require 'bgp/daemon/client'

class BGP_Daemon_Client_Test < Test::Unit::TestCase

  C = BGP::Daemon::Client

  # **The order is the recorded requirement that there is no root in the
  # ordinary case**: /run/bgp4r is where an installed daemon running as
  # root puts it, and /run needs root to write, so an unprivileged
  # standalone run falls back to the user's own runtime directory and
  # then to the temporary one. Both ends compute it the same way, so
  # neither has to be told.
  def test_the_candidates_are_run_then_the_runtime_directory_then_tmp
    assert_equal(['/run/bgp4r', '/x/bgp4r', '/tmp/bgp4r'],
                 C.candidates('XDG_RUNTIME_DIR' => '/x', 'TMPDIR' => '/no/such/place'))
  end

  def test_the_runtime_directory_is_left_out_when_it_is_not_set
    assert_equal(['/run/bgp4r', '/tmp/bgp4r'], C.candidates({}))
  end

  # The first candidate whose parent this process may write wins. The
  # list is an argument because on a machine running as root the first
  # one always wins and nothing else would ever be reached.
  def test_the_first_writable_candidate_wins
    Dir.mktmpdir do |dir|
      unwritable = File.join(dir, 'nowhere', 'deeper')
      assert_equal(File.join(dir, 'bgp4rd.sock'),
                   C.default_socket({}, [unwritable, dir]))
      assert_equal('/run/bgp4r/bgp4rd.sock', C.default_socket({}, [unwritable]),
                   'with nowhere to put it, the documented path still says where to look')
    end
  end

  # No require 'tmpdir' in the library, which Conventions says to check
  # before requiring a standard library: the same environment variables
  # Dir.tmpdir reads, with the same /tmp fallback.
  def test_the_temporary_directory_is_read_without_requiring_tmpdir
    assert_equal('/tmp', C.tmp_dir({}))
    assert_equal('/tmp', C.tmp_dir('TMPDIR' => '/no/such/place'))
    Dir.mktmpdir { |dir| assert_equal(dir, C.tmp_dir('TMPDIR' => dir)) }
    assert_equal([], File.read(File.expand_path('../../../bgp/daemon/client.rb', __dir__))
                          .scan(/^require 'tmpdir'$/))
  end

  def test_a_directory_is_writable_when_it_exists_or_its_parent_does
    Dir.mktmpdir do |dir|
      assert_equal(true, C.writable_parent?(dir))
      assert_equal(true, C.writable_parent?(File.join(dir, 'not-yet')))
      assert_equal(false, C.writable_parent?(File.join(dir, 'not', 'yet')))
    end
  end

  # The argument wins over the environment and the environment over the
  # default, so a lab sets one variable for every command.
  def test_the_socket_comes_from_the_argument_then_the_environment
    assert_equal('/a/b.sock', C.new('/a/b.sock', 'BGP4R_SOCKET' => '/c/d.sock').path)
    assert_equal('/c/d.sock', C.new(nil, 'BGP4R_SOCKET' => '/c/d.sock').path)
  end

  def test_no_daemon_says_so_and_names_the_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'gone.sock')
      e = assert_raise(C::Error) { C.new(path, {}).call('api.info') }
      assert_match(/cannot reach bgp4rd at #{Regexp.escape(path)}/, e.message)
      assert_match(/is it running\?/, e.message)
    end
  end

  # A socket that answers something that is not JSON is a wrong answer
  # and not a missing one, so it says which.
  #
  # **The fake reads the request line before answering**, which is the
  # fix for a race this test shipped with: closing the socket as soon as
  # the answer was written could beat the client's own write, so the
  # write raised EPIPE and the client answered "lost the connection"
  # instead. It failed about half the time, measured over fifteen runs
  # each way, and it failed the same way against #234's code, so it is a
  # fault in the test and not in the Client. The test two below already
  # reads first, and says why.
  def test_an_answer_that_is_not_json_says_so
    Dir.mktmpdir do |dir|
      path = File.join(dir, 's.sock')
      server = UNIXServer.new(path)
      t = Thread.new { s = server.accept ; s.gets ; s.write("not json\n") ; s.close }
      e = assert_raise(C::Error) { C.new(path, {}).call('api.info') }
      assert_match(/not JSON/, e.message)
      t.join
      server.close
    end
  end

  # A daemon that takes the request and then goes away without
  # answering. **It reads the line first on purpose**: a server that
  # closes before the request is written may make the write raise EPIPE
  # instead, which answers "lost the connection", and which of the two
  # happens is the kernel's choice about a socket buffer and not
  # something a test should depend on.
  def test_a_daemon_that_closes_without_answering_says_so
    Dir.mktmpdir do |dir|
      path = File.join(dir, 's.sock')
      server = UNIXServer.new(path)
      t = Thread.new { s = server.accept ; s.gets ; s.close }
      e = assert_raise(C::Error) { C.new(path, {}).call('api.info') }
      assert_match(/closed the connection/, e.message)
      t.join
      server.close
    end
  end

end
