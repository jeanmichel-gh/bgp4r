#!/usr/bin/env ruby
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

#
# A generic bgp4r speaker for the lab, driven by one YAML file per node.
#
#   ruby -I. lab/speaker.rb lab/topologies/two-speakers/r1.yml
#
# It peers with the neighbors in its file, announces its routes, and keeps
# a JSON file with the state of each session and the routes it received.
# Tests read that file. See lab/README.md for the YAML keys.
#
# With a rib, originate, export or fib block it is a router as well: the
# tables of bgp/rib/ are wired in behind those keys, so a route learned
# from one neighbor is decided and passed on to another with the export
# rules applied. Without any of them nothing here builds a table, so a
# node file that worked before this sends the same octets it sent before.
#
# **The machinery moved into the library and this file is its command
# line.** `BGP::Daemon::Speaker` in bgp/daemon/speaker.rb holds the
# sessions, the configuration and the recording, because `bgp4rd` needs
# the same things and `lab/` is not on an installed gem's load path. That
# file's header has the decision and the two options it rejected. The
# three constants below are the same classes under their old names, so
# every topology and every test that names `Lab::Speaker` keeps working.

$LOAD_PATH.unshift File.expand_path('..', __dir__)
require 'bgp/daemon/speaker'
require 'yaml'

module Lab
  Recorder = BGP::Daemon::Recorder
  Peer     = BGP::Daemon::Peer
  Speaker  = BGP::Daemon::Speaker

  def self.main(argv)
    $stdout.sync = true # docker logs shows lines as they happen
    abort "usage: ruby -I. lab/speaker.rb NODE.yml" unless argv.size == 1
    Speaker.new(YAML.safe_load(File.read(argv[0]))).run
  rescue ArgumentError, KeyError => e
    abort "lab/speaker.rb: #{e.message}"
  end
end

Lab.main(ARGV) if $0 == __FILE__
