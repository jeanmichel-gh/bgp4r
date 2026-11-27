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

# bgp4r image. The Ruby version is a build argument:
#
#   docker build --target test --build-arg RUBY_VERSION=4.0 -t bgp4r-test .
#   docker run --rm bgp4r-test
#
# The lab-node stage takes bfd4r, a sibling checkout, as a named build
# context, since the gem is not published (isis takes datalink-socket so):
#
#   docker build --target lab-node --build-context bfd4r=../bfd4r -t bgp4r-lab:latest .
#
# Stages:
#   base         Ruby, the dev and test gems, the bgp4r source, a non-root user
#   test         runs the unit suite (the default command)
#   speaker      runs a bgp4r script, for labs: docker run bgp4r-speaker my_peer.rb
#   lab-node     speaker plus iproute2 and bfd4r, as root, for a containerlab
#                node; it needs the bfd4r build context, below
#   capture      the bgp4r command with tcpdump, for `bgp4r capture -i IFACE`
#   gobgp-cli    the router image, only as a source for the gobgp binary
#   conformance  speaker plus the gobgp client, for the fault matrix topology

ARG RUBY_VERSION=3.4

# The image the conformance stage takes the gobgp client from. The default
# matches the router in lab/topologies/fault-matrix/compose.yml, and that
# topology passes its own value through, so the client and the router it
# queries are always the same version. It is declared here, above the first
# stage, because a FROM can only use an ARG declared before the first FROM.
ARG GOBGP_IMAGE=jauderho/gobgp:v4.10.0

FROM ruby:${RUBY_VERSION}-slim AS base
WORKDIR /app

# Dev and test gems only. The library itself has no runtime gems.
# Not the console group: irb needs erb, which compiles a native
# extension, and this image has no compiler. See the Gemfile.
COPY Gemfile ./
ENV BUNDLE_WITHOUT=console
# bfd4r is not bundled here: Bundler would load its gemspec, which runs
# git, and the image has none. lab-node puts it on RUBYLIB. See Gemfile.
ENV BFD4R_ON_RUBYLIB=1
RUN bundle install --jobs 4

COPY . .

# BGP listens on TCP 179. A non-root user can still bind it: Docker sets
# net.ipv4.ip_unprivileged_port_start=0 in a container's own network
# namespace. With --network host the host's setting applies instead.
RUN useradd --create-home --uid 1000 bgp && chown -R bgp:bgp /app
USER bgp

FROM base AS test
CMD ["ruby", "test/run_unit.rb"]

# The speaker stage runs any program in the tree, so it is also the
# injector and the daemon: its entrypoint takes a path, which is what a
# Compose topology passes.
#
#   docker run --rm -v $PWD/sim.yml:/lab/sim.yml bgp4r-speaker \
#     exe/bgp4r-sim /lab/sim.yml --api 0.0.0.0:8080
#   docker run --rm -v $PWD/bgp4rd.yml:/etc/bgp4r/bgp4rd.yml bgp4r-speaker \
#     exe/bgp4rd -f /etc/bgp4r/bgp4rd.yml
#   docker run --rm -v $PWD/rtr.yml:/lab/rtr.yml bgp4r-speaker \
#     exe/bgp4r-rtr /lab/rtr.yml
#   docker run --rm bgp4r-speaker exe/bgp4r-bmp --api 0.0.0.0:8080
#
# **No stage of its own for either**, deliberately: a stage whose only
# difference is a default command is a stage that can go stale, and
# neither program needs a package the base image lacks. The injector's
# API is reached with `docker exec`, which needs no published port, and
# that is the recorded reason it binds the loopback.
FROM base AS speaker
EXPOSE 179 323
ENTRYPOINT ["ruby", "-I/app"]

# The containerlab node image: the speaker stage plus iproute2, as root.
#
#   docker build --target lab-node --build-context bfd4r=../bfd4r -t bgp4r-lab:latest .
#
# `routescope/labs/bgp4r-lab` is the one topology that needs it, and the
# two things it adds are both things the `speaker` stage cannot be given
# from a topology file.
#
# * **iproute2**, because a containerlab topology sets a node's addresses
#   with `exec: ip addr add ...` and there is no `ip` in the speaker
#   image. `bgp/rib/ip_route.rb` shells out to the same binary, so a
#   `fib:` key in a node file needs it too.
# * **ping and traceroute**, because `routescope/labs/fwd-lab` checks that
#   packets follow the routes a `fib:` key installs, and a person in a
#   node's shell wants the same two commands.
# * **root**, because `BGP::Daemon::Api#start` does `mkdir_p` on the
#   socket's directory and the default is `/run/bgp4r`, which uid 1000
#   cannot create. routescope's `Drivers::Bgp4rd` hard-codes that path
#   for a containerlab node, since `Containerlab#node` passes no
#   `socket:` option through, so the daemon has to be able to bind there.
#
# The four Compose topologies stay on `speaker` and are untouched: they
# set their addresses through Compose rather than with `ip`, and nothing
# in them opens a control socket.
#
# Built and run by `.github/workflows/capture.yml`, which deploys
# bgp4r-lab on it, first on 2026-11-03.
FROM speaker AS lab-node
USER root
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iputils-ping traceroute \
    && rm -rf /var/lib/apt/lists/*
# A shell in the node types the commands by name, and the client finds
# the daemon's socket with no -s: `bgp4r-cli -c 'show bgp'`, or `cli`
# for short. docs/bgp4r-cli.md is the guide to that shell.
RUN for c in bgp4r bgp4rd bgp4r-cli bgp4r-sim bgp4r-rtr bgp4r-bmp; do ln -s /app/exe/$c /usr/local/bin/$c; done \
 && ln -s /app/exe/bgp4r-cli /usr/local/bin/cli
ENV BGP4R_SOCKET=/run/bgp4r/bgp4rd.sock

# bfd4r, for `bfd: true` on a neighbor: bfdd4r, bfd4r-cli and
# with-bfdd4r on PATH, and its root on RUBYLIB, which is its require
# path, so bgp4rd can `require 'bfd/client'`. bfd4r has no runtime gem.
#
# **with-bfdd4r is the entrypoint**: it starts bfdd4r in the background,
# again a second after it fails, and then execs what the node runs, so a
# lab's `cmd: exe/bgp4rd ...` is unchanged. bfdd4r is one per network
# namespace and a second one exits quietly. routescope's
# docs/design/bfd-clients.md, "How bfdd4r starts in a container".
COPY --from=bfd4r bfd/ /bfd4r/bfd/
COPY --from=bfd4r bfd4r.rb /bfd4r/
COPY --from=bfd4r exe/ /bfd4r/exe/
ENV RUBYLIB=/bfd4r \
    PATH=/bfd4r/exe:$PATH
ENTRYPOINT ["with-bfdd4r", "ruby", "-I/app"]

# The capture image. Its entrypoint is the bgp4r command, so the argv
# routescope hard-codes works unchanged:
#
#   docker run --rm --network container:NAME --cap-add NET_RAW \
#     --cap-add NET_ADMIN bgp4r-capture capture -i eth1
#
# That argv is Transport::Docker#capture_command in routescope, where the
# subcommand `capture` and the flag `-i` are not configurable, so the
# entrypoint has to take them. docs/routescope-labs.md section 4 has it.
#
# tcpdump is the one thing added. The library has no runtime gem but a
# packet socket in pure Ruby would be a native dependency, so the capture
# spawns tcpdump into a pipe, as ospfv2's does.
#
# This helper opens a packet socket in the router network namespace.
# Run as root with only the requested NET_RAW/NET_ADMIN capabilities;
# switching to the bgp user loses the effective capabilities for tcpdump.
FROM base AS capture
USER root
RUN apt-get update && apt-get install -y --no-install-recommends tcpdump \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["ruby", "-I/app", "exe/bgp4r"]
CMD ["capture", "-i", "eth0"]

# The speaker plus the gobgp client, so a script can read GoBGP's RIB:
#
#   lab/fault_matrix.rb --rib-command 'gobgp -u 10.30.0.2 global rib'
#
# Without a RIB answer the matrix cannot tell RFC 7606 treat-as-withdraw
# from attribute-discard, because both keep the session up. The client
# talks gRPC on port 50051 to whatever host -u names, so it needs no
# Docker socket and no shell in the router.
#
# The binary is copied out of the router image rather than downloaded, so
# there is nothing to fetch and no version to keep in step by hand.
# BuildKit builds only the stages the target needs, so --target test and
# --target speaker never pull the router image.
FROM ${GOBGP_IMAGE} AS gobgp-cli

FROM speaker AS conformance
COPY --from=gobgp-cli /usr/local/bin/gobgp /usr/local/bin/gobgp
