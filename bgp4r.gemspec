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
  # docs/daemon.md names four commands. This is the one that exists:
  # `bgp4r capture` and `bgp4r version`. bgp4rd, bgp4r-cli and bgp4r-sim
  # are later pieces of work and are deliberately not declared, because
  # an executable in a released gem that answers nothing is worse than
  # one that is not there.
  s.bindir = "exe"
  s.executables = ["bgp4r"]
  s.required_ruby_version = Gem::Requirement.new(">= 1.8.6")
  s.required_rubygems_version = '>= 1.3.6'
  # logger ships with Ruby, but Ruby 4.0 made it a bundled gem, so it
  # must be declared. It is the only runtime dependency.
  s.add_dependency 'logger'
  s.files =  `git ls-files -z`.split("\x0")
  s.test_files = `git ls-files test -z`.split("\x0")
  s.extra_rdoc_files = ["LICENSE.txt","README.rdoc"] + `git ls-files bgp -z`.split("\x0")
end

