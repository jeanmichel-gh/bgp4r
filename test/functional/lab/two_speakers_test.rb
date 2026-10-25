# lab/topologies/two-speakers in Docker Compose.
#
#   ruby -I. test/functional/lab/two_speakers_test.rb
#
# Builds the speaker image, starts the topology, runs the checks, and
# takes it down. Skipped when docker compose is not available.

require_relative 'two_speakers_scenario'

class LabTwoSpeakersComposeTest < Test::Unit::TestCase
  include TwoSpeakersScenario

  def self.startup
    return unless LabHelper::Compose.available?
    @@lab = LabHelper::Compose.new('two-speakers')
    @@lab.down
    @@lab.up
  end

  def self.shutdown
    @@lab.down if defined?(@@lab)
  end

  def setup
    unless defined?(@@lab)
      flunk('docker compose is not available') if ENV['LAB_REQUIRE_DOCKER'] == '1'
      omit('docker compose is not available')
    end
    @lab = @@lab
  end

  def teardown
    super if defined?(@@lab)
  end

  def r1_addr ; '10.10.0.1' ; end
  def r2_addr ; '10.10.0.2' ; end
end
