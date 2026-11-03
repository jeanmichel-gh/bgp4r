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

require './test/features'

# Generates docs/running-tests.md: every command that runs part of this
# suite, the flags that turn logging on, and what each feature's tests
# are. `ruby test/features_doc.rb > docs/running-tests.md` writes it.
#
# **It is generated because the parts a reader would check are counts**,
# and CLAUDE.md's rule is that a count in prose is a count that will be
# wrong. Every file list and every total here is read out of
# `test/features.rb` and off the disk, and
# `test/unit/features_test.rb` asserts that the file on disk is what this
# produces. So a feature added without regenerating fails the suite,
# which is the same arrangement `rake to_hash:status` has with
# `test/unit/to_hash_catalog.rb`.
#
# The prose is here rather than in the document for the same reason: a
# document half generated and half written by hand is a document whose
# halves drift, and this file's own header is where that is recorded.
# Timings are comments in the sense that matters: each says when it was
# measured and on what, because a runner is not this machine.
module FeaturesDoc

  # Measured on 2026-11-03, Ruby 3.3.6, in the sandbox this was written
  # in. Stated so a reader can tell a slow machine from a hung test, and
  # dated because neither number is a promise.
  MEASURED = '2026-11-03'

  TIER_TIMES = {
    :unit       => '21s',
    :functional => '18s',
    :lab        => '10s to 400s per group',
  }.freeze

  module_function

  def document
    [header, tiers, feature_table, features_detail, logging, environment,
     by_hand, footer].join
  end

  def header
    <<~MD
      # Running the tests

      **Generated. Do not edit.** `test/features_doc.rb` writes it from
      `test/features.rb`, and `test/unit/features_test.rb` fails the unit
      suite when the two disagree:

      ```
      ruby test/features_doc.rb > docs/running-tests.md
      ```

      This is the map of what to run and how to see what happened.
      `docs/protocol-testing.md` is the other half: how to build the
      messages no RFC allows and what three routers do with them.

    MD
  end

  def tiers
    <<~MD
      ## The three tiers

      Every test is in one of three tiers, and they cost very different
      amounts. Measured #{MEASURED}:

      | Tier | What it needs | Files | Time | Command |
      |---|---|---:|---|---|
      | unit | Ruby | #{Dir['test/unit/**/*_test.rb'].size} | #{TIER_TIMES[:unit]} | `ruby test/run_unit.rb` |
      | functional | a loopback socket | #{Dir['test/functional/*_test.rb'].size} | #{TIER_TIMES[:functional]} | one file at a time, below |
      | lab | gobgpd, FRR, Docker or root | #{Dir['test/functional/lab/*_test.rb'].size} | #{TIER_TIMES[:lab]} | `ruby test/run_lab.rb GROUP` |

      **The first two tiers together are under a minute and need nothing
      installed.** That is worth knowing before reaching for a lab test.
      The unit suite is #{TIER_TIMES[:unit]}. Every functional test
      together is #{TIER_TIMES[:functional]}, on loopback, with no router
      binary and no Docker.

      ```
      ruby test/run_unit.rb                       # the whole unit suite
      ruby -I. test/unit/path_attributes/origin_test.rb   # one unit file
      ruby test/run_unit.rb && for f in test/functional/*_test.rb; do \\
        [ "$f" = test/functional/live_feed_test.rb ] || ruby -I. "$f"; done
      ```

      `-I.` is needed for a single file and not for `run_unit.rb`, which
      sets the load path itself. **Run a file you changed both ways**, on
      its own and in the suite: a missing `require` passes in the suite
      and fails alone, and a top-level `include` does the opposite.

      ### The one file to never run

    MD
      .+ Features::NEVER.map { |k, v| "`test/#{k}.rb` #{v}.\n" }.join +
    <<~MD

      `run_feature.rb` refuses it by name. Nothing stops `ruby -I.` on it.

    MD
  end

  def feature_table
    out = +<<~MD
      ## By feature

      `test/features.rb` tags every test file with the BGP feature it
      exercises, which is a second axis over the same files: the tree is
      laid out by source file, and `test/lab_groups.rb` groups the lab
      tests by the binary they need. Features are tags and they overlap,
      because about a quarter of the files carry two or more.

      ```
      ruby test/run_feature.rb                 # this table
      ruby test/run_feature.rb FEATURE         # every tier of one feature
      ruby test/run_feature.rb FEATURE --unit  # the tier that needs nothing
      ruby test/run_feature.rb FEATURE --list  # the files, and what they need
      ruby test/run_feature.rb --area families # every feature of one area
      ```

    MD
    Features.areas.each do |area|
      out << "### #{area}\n\n#{Features::AREAS[area]}.\n\n"
      out << "| Feature | unit | func | lab | What |\n|---|---:|---:|---:|---|\n"
      Features.in_area(area).each do |name|
        f = Features.feature(name)
        out << format("| `%s` | %d | %d | %d | %s |\n", name,
                      Features.files(name, :unit).size,
                      Features.files(name, :functional).size,
                      Features.files(name, :lab).size,
                      f[:about])
      end
      out << "\n"
    end
    out
  end

  # One block per feature: what to read, what to run, and what the lab
  # tier wants. **The unit and functional files are counted and not
  # listed**, because `run_feature.rb FEATURE --list` prints them and a
  # few hundred lines of paths in a document is output rather than
  # documentation. The lab files are listed, because what each needs
  # decides whether a person can run it at all.
  def features_detail
    out = +<<~MD
      ## What each feature covers

      `ruby test/run_feature.rb FEATURE --list` prints the files, with
      what each needs. These are the parts that are not in that list.

    MD
    Features.names.each do |name|
      f = Features.feature(name)
      u = Features.files(name, :unit).size
      n = Features.files(name, :functional).size
      lab = Features.files(name, :lab)
      out << "### `#{name}`\n\n#{f[:about]}.\n\n"
      out << "- RFC: #{f[:rfc]}\n" if f[:rfc]
      out << "- Read first: `#{f[:doc]}`\n" if f[:doc]
      out << "- #{u} unit file(s)" + (n.zero? ? "\n" : ", #{n} functional\n")
      unless lab.empty?
        out << "- lab:\n"
        lab.each do |p|
          need = Features.needs(p)
          out << "  - `#{File.basename(p, '.rb')}`" \
                 "#{need && need != 'nothing' ? ", needs #{need}" : ''}\n"
        end
      end
      out << "\n```\nruby test/run_feature.rb #{name}\n```\n\n"
    end
    out
  end

  def logging
    <<~MD
      ## Turning logging on

      ### For a test run

      `BGP4R_LOG` turns the library's log on for a test, on standard
      error, so a failure can be read instead of bisected:

      ```
      BGP4R_LOG=debug ruby test/run_unit.rb 2> /tmp/bgp4r.log
      BGP4R_LOG=debug ruby test/run_feature.rb evpn
      BGP4R_LOG=debug ruby test/run_lab.rb local
      ```

      `debug`, `info` or `warn`, with `2` and `1` for the first two. An
      unknown value warns and changes nothing.

      **A single file needs `-rtest/log_on`**, because the three runners
      are what install the switch and `ruby -I. <one file>` goes through
      none of them:

      ```
      BGP4R_LOG=debug ruby -I. -rtest/log_on test/functional/rib_router_test.rb
      ```

      At `debug` that is about a thousand lines for one functional test,
      each message decoded and in hex, which is the form a line can be
      lifted out of and pasted into a test as a fixture.

      **Two limits.** A test that silences the log itself wins, which
      `test/functional/sim_test.rb` and `test/unit/daemon/candidate_test.rb`
      do on purpose. And an object handed its own logger writes there
      instead, which is what `bgp/logging.rb` is for.

      ### For the programs

      **The flags are the same on every program that has them.** `-l` says
      where, `-d` says how much:

      | Flag | Means |
      |---|---|
      | `-l FILE`, `--log FILE` | write the log there |
      | `-l -`, or no `-l` at all | write it to standard output |
      | `-d`, `--debug` | log every message as well, which is level `debug` |

      `bgp4rd`, `bgp4r-sim` and `bgp4r routegen` all take both. `bgp4r-cli`
      and `bgp4r capture` take neither, on purpose: the client prints the
      daemon's answer and `capture` prints one JSON object per message, so
      in both the output *is* the product.

      With no `-d` the level comes from the `log_level` key in the YAML,
      which is `debug`, `info` or `warn` and defaults to `info`. There is
      no `--log-level` flag.

      ```
      ruby -I. exe/bgp4rd -f lab/topologies/bgp4r-lab/rtr/bgp4rd.yml \\
        -s /tmp/d.sock -l - -d
      ruby -I. exe/bgp4r-sim examples/sim.yml --api 127.0.0.1:8080 -l - -d
      ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 -l - -d
      ```

      **There is no `examples/bgp4rd.yml`.** `bgp4r-sim` has
      `examples/sim.yml` and the daemon has no minimal example at all, so
      the only configuration to copy is the lab one above, which expects
      three neighbours on addresses a laptop does not have. The daemon
      starts and answers its socket regardless.

      `LAB_LOG_LEVEL` overrides the YAML for every speaker, daemon and
      injector in a run, which is how a lab is turned up without editing
      a node file:

      ```
      LAB_LOG_LEVEL=debug ruby test/run_lab.rb local
      LAB_LOG_LEVEL=debug ruby -I. lab/speaker.rb lab/topologies/two-speakers/r1.yml
      LAB_LOG_LEVEL=debug docker compose -f lab/topologies/two-speakers/compose.yml up
      ```

      Three lab scenarios print both speakers' logs when a test fails, so
      a failure in `routegen`, `speaker_router` or `two_speakers` needs no
      flag at all to be readable.

      ### Reading a running daemon's log

      `bgp4rd` keeps its last 2000 lines in front of the real destination,
      so a console can ask for them without a file:

      ```
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.log
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.log '{"count":500}'
      ```

      `count` defaults to 100 and is clamped to 2000. The level is a live
      configuration key, so a running daemon can be turned up and down:

      ```
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock config.load '{"lines":["set log_level debug"]}'
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock config.commit
      ```

      A log line is for a person. An event carries a kind and a data hash
      a program switches on, and is a separate stream:

      ```
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock events.subscribe
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock events.subscribe '{"since":42}'
      curl 127.0.0.1:8080/api/events?since=42
      ```

    MD
  end

  def environment
    <<~MD
      ## Environment variables

      The library and the four executables read none of these. Every one
      is read by a test, a lab harness or a node file, so none of them
      changes what goes on the wire.

      | Variable | Default | What it does |
      |---|---|---|
      | `LAB_LOG_LEVEL` | the node file's `log_level`, else `info` | `debug`, `info` or `warn` for every speaker in a run |
      | `BGP4R_LOG` | unset | `debug` or `info` turns logging on for a unit or functional run |
      | `BGP4R_SOCKET` | `/run/bgp4r/bgp4rd.sock` | the control socket, for `bgp4rd` and `bgp4r-cli` |
      | `BGP4R_SIM_API` | `127.0.0.1:8080` | where `bgp4r-sim`'s HTTP API listens |
      | `RIB_MODEL_STEPS` | `400` | steps in the RIB model check in `rib/table_test` |
      | `ROUTEGEN_COUNT` | the node file's `count` | overrides every `generate` block's prefix count |
      | `ROUTEGEN_PER_UPDATE` | the node file's `per_update` | overrides prefixes per UPDATE |
      | `FAULT_SETTLE` | `2` | seconds the fault matrix waits per case |
      | `GOBGPD`, `GOBGP` | `gobgpd`, `gobgp` | where the GoBGP binaries are |
      | `FRR_BGPD`, `VTYSH` | `/usr/lib/frr/bgpd`, `vtysh` | where FRR's binaries are |
      | `GOBGP_IMAGE` | a 4.x image | the container image for the Compose fault matrix |
      | `LAB_REQUIRE_DOCKER` | unset | `1` fails instead of omitting when Docker is missing |
      | `LAB_REQUIRE_GOBGPD` | unset | `1` fails instead of omitting when `gobgpd` is missing |
      | `LAB_REQUIRE_FRR` | unset | `1` fails instead of omitting when FRR is missing |
      | `LAB_REQUIRE_NETNS` | unset | `1` fails instead of omitting without CAP_NET_ADMIN |

      **The four `LAB_REQUIRE_*` are what CI sets**, so a job that was
      meant to measure a router fails rather than passing with every case
      omitted. Set them by hand when a run that printed no failures also
      printed no assertions.

    MD
  end

  def by_hand
    <<~MD
      ## Driving it by hand

      The suite is one way in. These are the others, and each is the
      shortest path to watching something happen.

      ### Send a router many routes

      The oldest tool here, and still the quickest demonstration:

      ```
      ruby -I. examples/routegen examples/routegen.yml
      ROUTEGEN_LOG_LEVEL=debug ruby -I. examples/routegen examples/routegen.yml
      ```

      The same thing through the modern path, which reads a node file and
      takes the flags above:

      ```
      ruby -I. exe/bgp4r routegen --peer 10.0.0.2 --peer-as 65002 \\
        --count 200000 --per-update 127
      ```

      ### Drive a session from outside

      `bgp4r-sim` starts silent on purpose: nothing is announced until the
      API asks, so a baseline nobody configured is a baseline an assertion
      can rest on.

      ```
      ruby -I. exe/bgp4r-sim examples/sim.yml --api 127.0.0.1:8080 -l - &
      curl 127.0.0.1:8080/api/status
      curl -X POST -H 'X-BGP4R: routescope' \\
           -d '{"prefixes":["10.1.0.0/24"],"med":100}' \\
           127.0.0.1:8080/api/announce
      curl -X POST -H 'X-BGP4R: routescope' \\
           -d '{"case":"origin_value","prefixes":["10.3.1.0/24"]}' \\
           127.0.0.1:8080/api/fault
      curl 127.0.0.1:8080/api/sent
      ```

      `/api/fault` takes any name from `BGP::Fault::CATALOG`. To see them:

      ```
      ruby -I. -e 'require "bgp4r"; require "bgp/fault"; puts BGP::Fault.names'
      ```

      ### Run a router and ask it questions

      ```
      ruby -I. exe/bgp4rd -f /etc/bgp4r/bgp4rd.yml -s /tmp/d.sock -l - &
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock -c 'show bgp summary'
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock -c 'show bgp' --style junos
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock show.rib --pretty
      ruby -I. exe/bgp4r-cli -s /tmp/d.sock route.originate '{"prefixes":["10.255.0.0/24"]}'
      ```

      ### Read BGP off a wire

      No interface and no root for a file:

      ```
      ruby -I. exe/bgp4r capture -r a.pcap
      tcpdump -U -n -s 0 -w - -i eth1 tcp port 179 | ruby -I. exe/bgp4r capture -r -
      sudo ruby -I. exe/bgp4r capture -i eth1
      ```

      ### Start a lab of your own

      ```
      ruby -I. exe/bgp4r lab new                  # the topologies it found
      ruby -I. exe/bgp4r lab new /tmp/my-lab add-path
      ```

      Every Compose topology here builds with `context: ../../..`, so a
      copy cannot build its own image where it landed. Build it once in a
      checkout and run the copy without `--build`.

      ### What the library knows

      Three registries answer for themselves, so nothing about them needs
      to be written down:

      ```
      ruby -I. -e 'require "bgp4r"; p BGP::Attr.registrations.size'
      ruby -I. -e 'require "bgp4r"; p BGP::Extended_community::FACTORY.size'
      ruby -I. test/unit/to_hash_status.rb
      ruby -I. test/unit/to_hash_status.rb pending
      ```

    MD
  end

  def footer
    tagged = Features.present.size - Features.untagged.size
    <<~MD
      ## The guard

      `test/unit/features_test.rb` holds this document and the registry to
      the tree. It fails the unit suite when a test file carries no
      feature, when a feature names a file that is not there, and when
      this document is not what `test/features_doc.rb` generates. So a new
      test file has to be tagged before the suite is green again, which is
      the same arrangement `test/unit/lab_groups_test.rb` has with the CI
      matrix.

      #{tagged} of #{Features.present.size} test files are tagged. The
      remainder, if any, is what the guard names.
    MD
  end

end

print FeaturesDoc.document if $PROGRAM_NAME == __FILE__
