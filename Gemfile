source 'https://rubygems.org'
# Runtime: declared in bgp4r.gemspec too. Ruby 4.0 made logger a bundled gem.
gem 'logger'
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
