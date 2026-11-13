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

require 'test/unit'
require 'bgp/daemon/api'
require 'bgp/daemon/cli'

# docs/bgp4r-cli.md against the program it describes: the methods in its
# tables are the ones the daemon answers, both ways, its operator
# commands are bgp4r-cli's, and the lab images it describes put the
# commands on the PATH and the socket in the environment.
class TestBgp4rCliDoc < Test::Unit::TestCase
  ROOT = File.expand_path('../../..', __dir__)
  SOCKET = '/run/bgp4r/bgp4rd.sock'

  def read(path) = File.read(File.join(ROOT, path), :encoding => 'UTF-8')
  def doc = read('docs/bgp4r-cli.md')

  # The first cell of every table row, split on commas, where it is
  # backticked names.
  def first_cells
    doc.lines.grep(/\A\| `/).collect { |l| l.split('|')[1].scan(/`([^`]+)`/).flatten }
  end

  def test_every_method_the_daemon_answers_has_a_row_and_every_row_is_a_method
    documented = first_cells.flatten.grep(/\A[a-z_]+\.[a-z_]+\z/)
    assert_operator documented.size, :>=, 30, 'the tables were read'
    assert_equal BGP::Daemon::Api.names.sort, documented.sort
  end

  def test_every_operator_command_is_listed
    listed = first_cells.flatten.grep(/\A(show|clear|config|enable|disable|monitor) /)
    assert_equal BGP::Daemon::CLI::COMMANDS.sort, listed.sort
  end

  # The guide says `cli` and `bgp4r-cli` work with no -s in a lab node.
  # Each image that runs bgp4rd in a containerlab lab has to make that
  # true, and the socket has to be the one the topologies pass to bgp4rd.
  def test_the_lab_images_put_the_client_on_the_path_and_the_socket_in_the_environment
    images = ['Dockerfile', 'routescope/labs/rr-lab/Dockerfile.node', 'routescope/labs/bgp4r-lab/Dockerfile.node',
              'routescope/labs/fwd-lab/Dockerfile.node']
    images.each do |f|
      text = read(f)
      text = text[text.index('AS lab-node')..] if f == 'Dockerfile'
      assert_match(%r{^RUN for c in bgp4r bgp4rd bgp4r-cli bgp4r-sim; do ln -s /app/exe/\$c /usr/local/bin/\$c; done \\$}, text, f)
      assert_match(%r{^ && ln -s /app/exe/bgp4r-cli /usr/local/bin/cli$}, text, f)
      assert_match(/^ENV BGP4R_SOCKET=#{Regexp.escape(SOCKET)}$/, text, f)
    end
    %w[rr-lab/rr-lab.clab.yml bgp4r-lab/bgp4r-lab.clab.yml fwd-lab/fwd-lab.clab.yml].each do |t|
      cmds = read("routescope/labs/#{t}").lines.grep(/cmd: exe\/bgp4rd /)
      assert_not_empty cmds, t
      cmds.each { |c| assert_include c, "-s #{SOCKET}", t }
    end
    assert_include doc, SOCKET
  end
end
