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

# What is exercised and what is not, per path attribute and per address
# family. Printed from test/coverage_matrix.rb, which derives everything
# but its interop verdicts from the library itself, so a family wired in,
# an attribute registered or a fault case added shows up with no edit.
# Same rule as to_hash above: no document holds these numbers.
namespace :coverage do

  desc 'Per attribute and per family: fault cases, lab tests, what each router vouches for'
  task :matrix do
    $LOAD_PATH.unshift File.expand_path(__dir__)
    require 'test/coverage_matrix'
    print CoverageMatrix.report
  end

end
