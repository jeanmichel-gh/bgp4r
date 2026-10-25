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
# Stages:
#   base     Ruby, the dev and test gems, the bgp4r source, a non-root user
#   test     runs the unit suite (the default command)
#   speaker  runs a bgp4r script, for labs: docker run bgp4r-speaker my_peer.rb

ARG RUBY_VERSION=3.4

FROM ruby:${RUBY_VERSION}-slim AS base
WORKDIR /app

# Dev and test gems only. The library itself has no runtime gems.
COPY Gemfile ./
RUN bundle install --jobs 4

COPY . .

# BGP listens on TCP 179. A non-root user can still bind it: Docker sets
# net.ipv4.ip_unprivileged_port_start=0 in a container's own network
# namespace. With --network host the host's setting applies instead.
RUN useradd --create-home --uid 1000 bgp && chown -R bgp:bgp /app
USER bgp

FROM base AS test
CMD ["ruby", "test/run_unit.rb"]

FROM base AS speaker
EXPOSE 179
ENTRYPOINT ["ruby", "-I/app"]
