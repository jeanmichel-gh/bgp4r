# Runs every unit test under test/unit, at any depth.
# The same command works on a laptop, in Docker and in CI:
#
#   ruby test/run_unit.rb
#
# It sets the load path and working directory itself, so no -I. is needed.

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
Dir.chdir(root)

Dir['test/unit/**/*test.rb'].sort.each { |f| require "./#{f}" }
