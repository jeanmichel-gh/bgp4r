# Runs every lab test under test/functional/lab: the loopback speaker test
# and one Docker Compose test per topology.
#
#   ruby test/run_lab.rb
#
# Compose tests are skipped when Docker is not available, unless
# LAB_REQUIRE_DOCKER=1 is set, as in CI.

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
Dir.chdir(root)

Dir['test/functional/lab/*_test.rb'].sort.each { |f| require "./#{f}" }
