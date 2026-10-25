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
