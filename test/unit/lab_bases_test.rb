#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of BGP4R.
#
# BGP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# BGP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with BGP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'test/unit'
require 'open3'
require 'tmpdir'
require './test/functional/lab/lab_helper'

# lab/bases.sh: the base images a build needs, tagged before the build,
# so BuildKit does not ask Docker Hub for them (its header says why).
# --list pulls nothing, so these need no Docker.
class LabBasesTest < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)
  BASES = File.join(ROOT, 'lab/bases.sh')

  def list(*args)
    out, status = Open3.capture2(BASES, '--list', *args)
    assert status.success?
    out.split
  end

  def test_args_stages_and_scratch
    Dir.mktmpdir do |dir|
      f = File.join(dir, 'Dockerfile')
      File.write(f, <<~DOCKERFILE)
        ARG RUBY_VERSION=3.4
        ARG GOBGP_IMAGE=jauderho/gobgp:v4.10.0
        FROM --platform=$BUILDPLATFORM node:22-slim AS web
        FROM ruby:${RUBY_VERSION}-slim AS base
        FROM base AS speaker
        from Speaker as lab-node
        FROM ${GOBGP_IMAGE} AS gobgp-cli
        FROM scratch
        FROM ruby:$RUBY_VERSION-slim
      DOCKERFILE
      assert_equal %w[node:22-slim ruby:3.4-slim jauderho/gobgp:v4.10.0], list(f)
      assert_equal %w[node:22-slim ruby:4.0-slim jauderho/gobgp:v3.23.0],
                   list('RUBY_VERSION=4.0', 'GOBGP_IMAGE=jauderho/gobgp:v3.23.0', f)
    end
  end

  def test_our_dockerfiles
    assert_equal %w[ruby jauderho/gobgp], list(File.join(ROOT, 'Dockerfile')).map { _1.split(':').first }
    Dir[File.join(ROOT, 'routescope/labs/*/Dockerfile.*')].each do |f|
      refute_empty list(f), f
    end
  end

  # Every image build in a workflow tags its bases first, in its step or
  # the step before. Not in the test image, which has no .github.
  def test_every_workflow_build_tags_its_bases_first
    workflows = Dir[File.join(ROOT, '.github/workflows/*.yml')]
    omit('no .github here') if workflows.empty?
    workflows.each do |wf|
      lines = File.readlines(wf)
      lines.each_with_index do |line, i|
        next unless line.match?(/\bdocker build\b/) && !line.lstrip.start_with?('#')

        step = lines[0...i].rindex { _1.match?(/^\s*- (name|uses|run):/) }
        before = lines[[step.to_i - 4, 0].max...i].any? { _1.include?('lab/bases.sh') }
        assert before, "#{File.basename(wf)}:#{i + 1} builds without lab/bases.sh before it"
      end
    end
  end

  # Compose topologies build from the root Dockerfile; the fault matrix
  # passes GOBGP_IMAGE as a build arg, from the environment.
  def test_compose_tags_its_bases_with_the_gobgp_image
    lab = LabHelper::Compose.new('fault-matrix', env: { 'GOBGP_IMAGE' => 'jauderho/gobgp:v3.23.0' })
    cmd = lab.bases_command
    assert_equal [BASES, 'GOBGP_IMAGE=jauderho/gobgp:v3.23.0', File.join(ROOT, 'Dockerfile')], cmd
    out, status = Open3.capture2(cmd.first, '--list', *cmd.drop(1))
    assert status.success?
    assert_include out.split, 'jauderho/gobgp:v3.23.0'
  end
end
