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

# bgp4rd's command line and its configuration file. Nothing here starts
# a session, a socket or a log, which is why `load_config` and
# `with_defaults` are separate from `build`: starting it all is
# test/functional/daemon_test.rb.
#
#   ruby -I. test/unit/daemon/server_test.rb

require 'test/unit'
require 'stringio'
require 'tmpdir'
require 'bgp/daemon/server'

class BGP_Daemon_Server_Test < Test::Unit::TestCase

  def run_server(argv, env = {})
    out, err = StringIO.new, StringIO.new
    status = BGP::Daemon::Server.new(out, err).start(argv, env, :wait => false)
    [status, out.string, err.string]
  end

  def server
    @server ||= BGP::Daemon::Server.new(@out = StringIO.new, @err = StringIO.new)
  end

  CONFIG = <<~YAML
    router_id: 10.0.0.1
    as: 65000
    neighbors:
      - address: 10.0.0.2
        as: 65001
  YAML

  def with_config(text = CONFIG)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'bgp4rd.yml')
      File.write(path, text)
      yield path, dir
    end
  end

  def test_help_is_the_usage_and_a_success
    status, out, err = run_server(['--help'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_match(/Usage: bgp4rd/, out)
    assert_match(/--socket/, out)
  end

  def test_version_prints_the_library_version_and_nothing_else
    status, out, err = run_server(['--version'])
    assert_equal(0, status)
    assert_equal('', err)
    assert_equal("#{BGP::VERSION}\n", out)
  end

  # A daemon with no configuration has nothing to be, so this is the
  # usage and a failure rather than a default.
  def test_no_config_file_is_the_usage_and_a_failure
    status, out, err = run_server([])
    assert_equal(1, status)
    assert_equal('', out)
    assert_match(/Usage: bgp4rd/, err)
  end

  def test_an_unknown_argument_names_itself
    status, _o, err = run_server(['--nonsense'])
    assert_equal(1, status)
    assert_match(/unknown argument "--nonsense"/, err)
  end

  def test_a_missing_config_file_says_so_rather_than_raising
    assert_nil(server.load_config(:config => '/no/such/bgp4rd.yml'))
    assert_match(%r{/no/such/bgp4rd\.yml: no such file}, @err.string)
  end

  def test_a_config_file_that_is_not_a_mapping_says_so
    with_config("- one\n- two\n") do |path|
      assert_nil(server.load_config(:config => path))
      assert_match(/is not a YAML mapping/, @err.string)
    end
  end

  def test_a_config_file_that_is_not_yaml_says_so
    with_config("router_id: 10.0.0.1\n  bad: indent\n") do |path|
      assert_nil(server.load_config(:config => path))
      assert_match(/#{Regexp.escape(path)}/, @err.string)
    end
  end

  def test_a_config_file_reads_back_as_its_keys
    with_config do |path|
      c = server.load_config(:config => path)
      assert_equal(65_000, c['as'])
      assert_equal('10.0.0.1', c['router_id'])
      assert_equal(1, c['neighbors'].size)
    end
  end

  # --state wins over state_file in the file, so one run can point it
  # somewhere else without editing the configuration.
  def test_the_state_flag_wins_over_the_file
    with_config("as: 1\nrouter_id: 1.1.1.1\nneighbors: []\nstate_file: /tmp/in-the-file.json\n") do |path|
      assert_equal('/tmp/in-the-file.json', server.load_config(:config => path)['state_file'])
      assert_equal('/tmp/from-the-flag.json',
                   server.load_config(:config => path, :state => '/tmp/from-the-flag.json')['state_file'])
    end
  end

  # **A daemon is a router, so a table is on unless the file says no.**
  # Speaker#rib? makes one only when the node file asks, because every
  # lab topology written before #231 would otherwise start deciding
  # routes; in a daemon a table is what the program is.
  def test_a_table_is_on_by_default_and_a_file_can_turn_it_off
    assert_equal(true, BGP::Daemon::Server.with_defaults({})['rib'])
    assert_equal(false, BGP::Daemon::Server.with_defaults('rib' => false)['rib'])
    assert_equal(true, BGP::Daemon::Speaker.new(
      BGP::Daemon::Server.with_defaults('as' => 1, 'router_id' => '1.1.1.1', 'neighbors' => [])).rib?)
  end

  def test_with_defaults_changes_nothing_else
    c = { 'as' => 1, 'router_id' => '1.1.1.1', 'neighbors' => [] }
    assert_equal(c, BGP::Daemon::Server.with_defaults(c).reject { |k, _v| k == 'rib' })
  end

  # The gemspec declares them, or `gem install bgp4r` ships a library
  # with no commands.
  #
  # **Read as text and not loaded**, which is #232's finding: the
  # gemspec shells out to `git ls-files`, and the Docker image has
  # neither git nor a .git, so `Gem::Specification.load` answers nil and
  # the next line raises. It failed the three `docker ruby` CI jobs and
  # passed every runner job and every local run.
  # **All four of docs/daemon.md's commands are declared now.** This
  # guard asserted that `bgp4r-sim` was **not**, which was true while it
  # did not exist and is the fourth forward-looking guard in this
  # repository to fire and be re-pointed rather than weakened: the
  # assertion is the same, the truth it measures moved.
  def test_the_gemspec_declares_every_command_that_exists
    root = File.expand_path('../../..', __dir__)
    src = File.read(File.join(root, 'bgp4r.gemspec'))
    line = src[/^\s*s\.executables\s*=.*$/]
    assert_not_nil(line, 's.executables must still be there')
    %w[bgp4r bgp4rd bgp4r-cli bgp4r-sim].each do |cmd|
      assert_match(/"#{Regexp.escape(cmd)}"/, line)
      path = File.join(root, 'exe', cmd)
      assert_equal(true, File.exist?(path), "exe/#{cmd} must exist")
      assert_equal(true, File.executable?(path), "exe/#{cmd} must be executable")
    end
    # And nothing is declared that is not there, which is the half that
    # keeps a released gem from shipping a command that answers nothing.
    line.scan(/"([^"]+)"/).flatten.each do |cmd|
      assert_equal(true, File.exist?(File.join(root, 'exe', cmd)),
                   "the gemspec declares #{cmd} and exe/#{cmd} is not there")
    end
  end

  # **SIGHUP is a reload now**, which is what the candidate
  # configuration bought. This guard said it was not, because `config.*`
  # was a later pull request and a signal that silently did nothing would
  # read as a reload that worked; it is re-pointed rather than taken out,
  # at the thing that would make the old warning true again. The reload
  # itself is tested below over a real file, which is what the text match
  # could never say.
  def test_a_hangup_reloads
    src = File.read(File.expand_path('../../../bgp/daemon/server.rb', __dir__))
    assert_match(/^\s+reload$/, src[/def wait_for_a_signal.*?^      end$/m])
  end

  # A reload is `config.replace` and then `config.commit`, which is what
  # keeps it from drifting from the methods a console calls: the file
  # becomes the candidate and is committed.
  def test_a_reload_commits_the_file_as_it_is_now
    with_a_running_daemon do |server, path|
      write(path, config_text.sub('hold_time: 30', 'hold_time: 90'))
      server.reload
      assert_equal(90, server.speaker.peer('127.0.0.9').config['hold_time'])
      assert_equal(1, server.candidate.history.size)
      assert_match(/SIGHUP/, server.candidate.history.first[:comment])
    end
  end

  # **A reload that cannot be done changes nothing and says why**, which
  # is the whole reason a commit refuses a restart-class key rather than
  # recording it: the running configuration goes on being true.
  def test_a_reload_of_a_key_that_needs_a_restart_changes_nothing
    with_a_running_daemon do |server, path|
      write(path, config_text.sub('router_id: 10.0.0.1', 'router_id: 9.9.9.9'))
      server.reload
      assert_equal('10.0.0.1', server.speaker.router_id)
      assert_equal('10.0.0.1', server.candidate.running['router_id'])
      assert_equal([], server.candidate.history)
      assert_equal(false, server.candidate.changed?, 'the candidate was left dirty')
    end
  end

  def test_a_reload_of_a_file_that_is_gone_changes_nothing
    with_a_running_daemon do |server, path|
      File.unlink(path)
      server.reload
      assert_equal(30, server.speaker.peer('127.0.0.9').config['hold_time'])
      assert_equal([], server.candidate.history)
    end
  end

  # ---- --interact -----------------------------------------------------

  # A peer we dial at 127.0.0.1:1, which refuses at once, so nothing
  # listens and the dialling thread notices the stop within its retry.
  INTERACT_CONFIG = <<~YAML
    as: 65000
    router_id: 10.0.0.1
    neighbors:
      - address: 127.0.0.1
        port: 1
        as: 65001
        connect: true
        retry: 1
  YAML

  # Starts with --interact and a prompt that runs the block in place of
  # irb. Every start logs to its own file and the logger is put back,
  # since `Log` is the process's one logger.
  #
  # **The directory outlives the start and goes in teardown**, so a test
  # can ask whether leaving removed the socket. A first draft removed it
  # with the start, and the socket's absence was then true of every run.
  def interacting(config = INTERACT_CONFIG, log: true, irb: false, &prompt)
    require 'tmpdir'
    @dir = Dir.mktmpdir
    path = File.join(@dir, 'bgp4rd.yml')
    write(path, config)
    @sock = File.join(@dir, 'd.sock')
    @logfile = File.join(@dir, 'd.log')
    @out, @err = StringIO.new, StringIO.new
    @server = BGP::Daemon::Server.new(@out, @err, :interact => prompt || ->(_c) {},
                                                  :load_irb => irb)
    argv = ['-f', path, '-s', @sock, '--interact']
    argv += ['-l', @logfile] if log
    @server.start(argv, {})
  ensure
    @server.stop if @server
    Log.set_filename(STDERR)
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  # The prompt opens on the daemon's own Api, the socket answers while it
  # is open, and leaving stops the daemon and removes the socket. The
  # request goes over the real socket, because that it answers **while**
  # the prompt runs is the claim.
  def test_interact_opens_the_prompt_and_the_socket_still_answers
    seen = {}
    status = interacting do |console|
      seen[:api] = console.api_server
      seen[:info] = BGP::Daemon::Client.new(@sock).call('api.info')
      seen[:socket] = File.socket?(@sock)
    end
    assert_equal(0, status)
    assert_same(@server.api, seen[:api], 'the prompt is on the daemon\'s own Api')
    assert_equal(BGP::VERSION, seen[:info]['version'])
    assert(seen[:socket])
    assert_equal(false, File.exist?(@sock), 'leaving removed the socket')
    assert(@server.speaker.stopping?, 'leaving stopped the speaker')
    assert_match(/bgp4rd: socket #{Regexp.escape(@sock)}, so bgp4r-cli works/, @out.string)
    assert_match(/bgp4rd: stopping, Cease 6\/2 to 0 peers/, @out.string)
  end

  # Leaving goes through the console's stop, which is what sends the
  # Cease, and an exception out of the prompt still leaves that way.
  def test_leaving_by_an_exception_still_ceases_and_stops
    stopped = []
    assert_raise(RuntimeError) do
      interacting do |console|
        console.define_singleton_method(:stop) { stopped << :console ; super() }
        raise 'out of the prompt'
      end
    end
    assert_equal([:console], stopped)
    assert(@server.speaker.stopping?)
  end

  def test_at_a_prompt_the_log_goes_to_a_file_unless_one_is_named
    interacting(log: false)
    logfile = File.join(Dir.tmpdir, "bgp4rd-#{Process.pid}.log")
    assert_match(/logging to #{Regexp.escape(logfile)}/, @out.string)
    assert(File.exist?(logfile))
  ensure
    File.delete(logfile) if logfile && File.exist?(logfile)
  end

  def test_a_named_log_is_kept_at_a_prompt
    interacting
    assert_no_match(/logging to/, @out.string)
  end

  # A missing irb is said before the file is read, so nothing starts.
  def test_a_missing_irb_is_said_before_anything_starts
    BGP::Daemon::Console.singleton_class.send(:alias_method, :real_load_irb, :load_irb)
    BGP::Daemon::Console.define_singleton_method(:load_irb) { raise LoadError, BGP::Prompt::IRB_MISSING }
    assert_equal(1, interacting(irb: true))
    assert_match(/irb cannot be loaded/, @err.string)
    assert_nil(@server.speaker)
  ensure
    BGP::Daemon::Console.singleton_class.send(:alias_method, :load_irb, :real_load_irb)
  end

  def test_the_usage_names_interact
    _status, out, _err = run_server(['--help'])
    assert_match(/--interact/, out)
  end

  # A mark that does not read is said at start-up, and not on the first
  # route somebody makes by hand.
  def test_a_mark_that_does_not_read_is_refused_at_start
    status = interacting(INTERACT_CONFIG + "mark:\n  large: ['65000:1:1']\n")
    assert_equal(1, status)
    assert_match(/bgp4rd: mark: unknown key\(s\) large/, @err.string)
    assert_nil(@server.speaker)
  end

  private

  def config_text
    <<~YAML
      as: 65000
      router_id: 10.0.0.1
      listen_address: 127.0.0.1
      port: 17931
      neighbors:
        - address: 127.0.0.9
          as: 65001
          hold_time: 30
    YAML
  end

  def write(path, text)
    File.open(path, 'w') { |f| f.print text }
  end

  def with_a_running_daemon
    require 'tmpdir'
    dir = Dir.mktmpdir
    path = File.join(dir, 'bgp4rd.yml')
    write(path, config_text)
    server = BGP::Daemon::Server.new(StringIO.new, StringIO.new)
    opts = { :config => path, :socket => File.join(dir, 'd.sock') }
    config = BGP::Daemon::Server.with_defaults(server.load_config(opts))
    assert_not_nil(server.build(config, opts))
    yield server, path
  ensure
    server.stop if server
    FileUtils.remove_entry(dir) if dir
  end

end
