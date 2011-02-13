require 'rake'
require 'rake/rdoctask'
require 'rake/testtask'
require "rake/clean"

task "default" => 'test'

CLEAN.include ["*.gem", "pkg", "rdoc"]

begin
  require 'jeweler'
  Jeweler::Tasks.new do |s|
    s.name = 'bgp4r'
    s.authors = ['Jean-Michel Esnault']
    s.email = "bgp4r@esnault.org"
    s.summary = "A BGP-4 Ruby Library"
    s.description = "BGP4R is a BGP-4 ruby library to create,  send, and receive  BGP messages in an  object oriented manner"
    s.platform = Gem::Platform::RUBY
    s.executables = []
    s.files = %w( README.rdoc LICENSE.txt COPYING bgp4r.rb bgp4r.gemspec ) + Dir["bgp/**/*"] + Dir["test/**/*"] + ["examples/**/*"]
    s.test_files = Dir["test/**/*"]
    s.require_path = '.'
    s.required_ruby_version = ">= 1.8.6"
    s.homepage = "http://github.com/jesnault/bgp4r/tree/master"
    s.rubyforge_project = 'bgp4r'
  end
rescue LoadError
  puts "Jeweler not available. Install it with: sudo gem install jeweler"
end

# These are new tasks
begin
  require 'rake/contrib/sshpublisher'
  namespace :rubyforge do

    desc "Release gem and RDoc documentation to RubyForge"
    task :release => ["rubyforge:release:gem", "rubyforge:release:docs"]

    namespace :release do
      desc "Publish RDoc to RubyForge."
      task :docs => [:rdoc] do
        config = YAML.load(
            File.read(File.expand_path('~/.rubyforge/user-config.yml'))
        )

        host = "#{config['username']}@rubyforge.org"
        remote_dir = "/var/www/gforge-projects/the-perfect-gem/"
        local_dir = 'rdoc'

        Rake::SshDirPublisher.new(host, remote_dir, local_dir).upload
      end
    end
  end
rescue LoadError
  puts "Rake SshDirPublisher is unavailable or your rubyforge environment is not configured."
end

Rake::TestTask.new do |t|
  t.libs = ['.']
  t.pattern = "test/**/*test.rb"
  t.warning = true
end

Rake::RDocTask.new do |rdoc|
  files = ['README.rdoc', 'LICENSE.txt', 'COPYING', 'bgp/**/*.rb', 'doc/**/*.rdoc', 'test/*.rb']
  rdoc.rdoc_files.add(files)
  rdoc.main = 'README.rdoc'
  rdoc.title = 'Bgp4r'
  rdoc.rdoc_dir = 'rdoc'
  rdoc.options << '--line-numbers' << '--inline-source' 
  rdoc.options << '--quiet' << "--title" << "A BGP-4 Ruby Library"
  rdoc.options << '--fileboxes'
end

require 'rake/gempackagetask'

namespace :gem do

  desc "Run :package and install the .gem locally"
  task :install => [:gem, :package] do
    sh %{sudo gem install --local pkg/bgp4r-#{PKG_VERSION}.gem}
  end

  desc "Like gem:install but without ri or rdocs"
  task :install_fast => [:gem, :package] do
    sh %{sudo gem install --local pkg/bgp4r-#{PKG_VERSION}.gem --no-rdoc --no-ri}
  end

  desc "Run :clean and uninstall the .gem"
  task :uninstall => :clean do
    sh %{sudo gem uninstall bgp4r}
  end

end
