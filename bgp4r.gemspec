
spec = Gem::Specification.new do |s|
  s.name = 'bgp4r'
  s.version = '0.0.3'
  s.authors = ['Jean-Michel Esnault']
  s.email = "jesnault@gmail.com"
  s.summary = "A BGP-4 Ruby Library"
  s.description = "BGP4R is a ruby BGP library to create,  send, and receive  BGP messages in an  object oriented manner"
  s.platform = Gem::Platform::RUBY
  s.executables = []
  s.files = %w( README.rdoc LICENSE.txt COPYING ) + Dir["bgp/**/*"] + Dir["test/**/*"] + ["examples/**/*"]
  s.test_files = Dir["test/**/*"]
  s.has_rdoc = true
  s.rdoc_options = ["--quiet", "--title", "A BGP-4 Ruby Library", "--line-numbers"]
  s.require_path = '.'
  s.required_ruby_version = ">= 1.8.6"
  s.homepage = "http://github.com/jesnault/bgp4r/tree/master"
  s.rubyforge_project = 'bgp4r'
end
