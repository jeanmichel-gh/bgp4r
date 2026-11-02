require File.expand_path('bgp/version', __dir__)

Gem::Specification.new do |s|
  s.name = "bgp4r"
  s.version = BGP::VERSION
  s.email = "jesnault@gmail.com"
  s.authors = ["Jean-Michel Esnault"]
  s.date = "2014-10-23"
  s.description = "Best way to play with BGP protocol using ruby"
  s.summary = "Best way to play with BGP protocol using ruby"
  s.homepage = "http://github.com/jesnault/bgp4r"
  s.rdoc_options = ["--quiet", "--title", "bgp4r", "--line-numbers"]
  s.require_paths = ["."]
  # docs/daemon.md names four commands and all four exist: `bgp4r`, the
  # umbrella, with `capture`, `sim`, `routegen` and `version`; `bgp4rd`,
  # the daemon, with the read side of its control API; `bgp4r-cli`, its
  # client; and `bgp4r-sim`, the route injector, which is an alias for
  # `bgp4r sim` so that a container command reads plainly.
  s.bindir = "exe"
  s.executables = ["bgp4r", "bgp4rd", "bgp4r-cli", "bgp4r-sim"]
  s.required_ruby_version = Gem::Requirement.new(">= 1.8.6")
  s.required_rubygems_version = '>= 1.3.6'
  # logger ships with Ruby, but Ruby 4.0 made it a bundled gem, so it
  # must be declared. It is the only runtime dependency.
  s.add_dependency 'logger'
  s.files =  `git ls-files -z`.split("\x0")
  s.test_files = `git ls-files test -z`.split("\x0")
  s.extra_rdoc_files = ["LICENSE.txt","README.rdoc"] + `git ls-files bgp -z`.split("\x0")
end

