require 'rake'
require 'rake/rdoctask'
require 'rake/testtask'
require "rake/clean"

task "default" => 'test'

CLEAN.include ["*.gem", "pkg", "rdoc"]

PKG_NAME      = 'bgp4r'
PKG_VERSION   = '0.0.1'
AUTHORS       = ['Jean-Michel Esnault']
EMAIL         = "jean-michel@esnault.us"
TITLE         = "A ruby BGP library."
RDOC_FILES    = %w( README.rdoc LICENSE.txt COPYING )
PKG_FILES     = RDOC_FILES + Dir["{bgp,test}/**/*"]
RDOC_OPTIONS  = ["--quiet", "--title", TITLE, "--line-numbers", "--inline-source"]

Rake::TestTask.new do |t|
  t.libs = ['.']
  t.pattern = "test/*test.rb"
  t.warning = true
end

Rake::RDocTask.new do |t|
  t.rdoc_dir = 'rdoc'
  t.rdoc_files.include("lib/*.rb")
  t.options =  RDOC_OPTIONS
  t.options << '--fileboxes'
end

require 'rake/gempackagetask'

spec = Gem::Specification.new do |s|
  s.name = PKG_NAME
  s.version = PKG_VERSION
  s.authors = AUTHORS
  s.email = EMAIL
  s.rubyforge_project = PKG_NAME
  s.summary = TITLE
  s.description = s.summary
  s.platform = Gem::Platform::RUBY
  s.executables = []
  s.files = PKG_FILES
  s.test_files = []
  s.has_rdoc = true
  s.extra_rdoc_files = RDOC_FILES
  s.rdoc_options = RDOC_OPTIONS
  s.require_path = '.'
  s.required_ruby_version = ">= 1.8.6"
end

Rake::GemPackageTask.new(spec) do |pkg|
  pkg.gem_spec = spec
  pkg.need_tar = true
end

namespace :gem do

  desc "Run :package and install the .gem locally"
  task :install => [:gem, :package] do
    sh %{sudo gem install --local pkg/#{PKG_NAME}-#{PKG_VERSION}.gem}
  end

  desc "Like gem:install but without ri or rdocs"
  task :install_fast => [:gem, :package] do
    sh %{sudo gem install --local pkg/#{PKG_NAME}-#{PKG_VERSION}.gem --no-rdoc --no-ri}
  end

  desc "Run :clean and uninstall the .gem"
  task :uninstall => :clean do
    sh %{sudo gem uninstall #{PKG_NAME}}
  end

end
