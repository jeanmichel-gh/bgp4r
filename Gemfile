source 'https://rubygems.org'
# Runtime: declared in bgp4r.gemspec too. Ruby 4.0 made logger a bundled gem.
gem 'logger'
# BFD: bgp4rd's `bfd: true` asks bfdd4r for sessions through bfd4r's
# BFD::Client (bgp/daemon/bfd.rb). bfd4r is the owner's own gem and is
# not published, so it comes by path from a checkout beside this one, as
# isis takes datalink-socket. bgp4r.gemspec declares it too.
#
# **Not in the Docker image**, which sets BFD4R_ON_RUBYLIB: Bundler
# loads a path gem's gemspec, bfd4r's runs `git ls-files`, and the image
# has no git (CLAUDE.md, "A test must not load bgp4r.gemspec"). The
# lab-node stage copies bfd4r in and puts it on RUBYLIB instead, which is
# isis's own Dockerfile's way.
gem 'bfd4r', path: '../bfd4r' unless ENV['BFD4R_ON_RUBYLIB']
# Dev and test
gem 'rake'
gem 'test-unit'
# The prompt of `bgp4r routegen --interact`. Not a runtime dependency:
# the library never loads it, and the console says what to do when it
# is missing. Ruby 4.0 made it a bundled gem, so under Bundler it loads
# only when named here.
#
# **A group of its own, because the Docker image cannot build it.** irb
# depends on rdoc, which depends on erb, and erb compiles a native
# extension. The slim Ruby image has no compiler, so `bundle install`
# failed there with every docker job and the compose lab red. The
# Dockerfile sets BUNDLE_WITHOUT=console. A container runs plain `ruby`,
# not `bundle exec`, so Ruby's own copy of irb still loads in one.
group :console do
  gem 'irb'
end
