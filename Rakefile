require 'rake/testtask'
Rake::TestTask.new do |t|
  t.libs << `pwd`.chomp
  t.test_files = FileList['test/unit/*test.rb']
  t.verbose = true
end
task default: :test

