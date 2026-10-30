require 'rake/testtask'
Rake::TestTask.new do |t|
  t.libs << `pwd`.chomp
  t.test_files = FileList['test/unit/**/*test.rb']
  t.verbose = true
end
task default: :test

# Which #to_hash read back and which do not. Printed from
# test/unit/to_hash_catalog.rb, which the suite measures against the
# library, so neither list can be stale without a test failing first.
# There is deliberately no document holding these numbers.
namespace :to_hash do

  desc 'Every class measured for its #to_hash round trip, grouped by verdict'
  task :status do
    $LOAD_PATH.unshift File.expand_path(__dir__)
    require 'test/unit/to_hash_catalog'
    require 'test/unit/to_hash_status'
    print ToHashStatus.status
  end

  desc 'The #to_hash round trips still marked to fix'
  task :pending do
    $LOAD_PATH.unshift File.expand_path(__dir__)
    require 'test/unit/to_hash_catalog'
    require 'test/unit/to_hash_status'
    print ToHashStatus.pending
  end

end
