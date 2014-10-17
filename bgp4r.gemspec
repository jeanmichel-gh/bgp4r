Gem::Specification.new do |s|
  s.name = "bgp4r"
  s.version = "0.0.18"
  s.email = "jesnault@gmail.com"
  s.authors = ["Jean-Michel Esnault"]
  s.date = "2014-09-23"
  s.description = "Best way to play with BGP protocol using ruby"
  s.summary = "Best way to play with BGP protocol using ruby"
  s.homepage = "http://github.com/jesnault/bgp4r"
  s.rdoc_options = ["--quiet", "--title", "bgp4r", "--line-numbers"]
  s.require_paths = ["."]
  s.required_ruby_version = Gem::Requirement.new(">= 1.8.6")
  s.required_rubygems_version = '>= 1.3.6'
  s.files =  `git ls-files -z`.split("\x0")
  s.test_files = `git ls-files test -z`.split("\x0")
  s.extra_rdoc_files = ["LICENSE.txt","README.rdoc"] + `git ls-files bgp -z`.split("\x0")
end

