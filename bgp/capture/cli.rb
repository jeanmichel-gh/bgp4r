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

require 'bgp/version'
require 'bgp/capture/pcap'
require 'bgp/capture/dissect'
require 'bgp/capture/stream'

module BGP
  module Capture

    # The `bgp4r` umbrella command. `docs/daemon.md` names four commands,
    # `bgp4rd`, `bgp4r-cli`, `bgp4r` and `bgp4r-sim`; this is the third.
    # **Every subcommand that document names exists now**, `capture`,
    # `sim`, `routegen`, `lab new` and `version`, so the usage no longer
    # lists anything as not yet implemented. The rule that got them there
    # one at a time stands for whatever comes next: an executable in a
    # released gem that answers nothing is worse than one that is not
    # there, so each arrived with its program rather than as a stub.
    #
    #   BGP::Capture::CLI.new.start(ARGV)   # => an exit status
    #
    # Output goes to an injected IO so a test reads it as a String rather
    # than capturing a process's stdout.
    #
    # **`sim` and `routegen` require `bgp/sim` in the branch that needs
    # it and not at the top of this file, and `lab` requires `fileutils`
    # the same way.** `bgp4r capture` is what routescope runs in its own
    # container, once per lab, and loading an injector, a Speaker, the
    # route generator or a file copier to dissect a pcap would be work
    # nothing asked for. It is also why this class still lives in
    # `bgp/capture/` while dispatching to two other programs: the file is
    # named after what it is mostly for, and moving it is a rename
    # nothing needs.
    class CLI

      SUBCOMMANDS = %w{capture sim routegen lab version}

      # `docs/routescope-labs.md` section 4: routescope's capture argv is
      # hard coded to `IMAGE capture -i IFACE`, so it passes **no
      # filter** and only displays the string the image says it used.
      # That makes this default part of the contract rather than a
      # convenience, which is why it is a named constant and asserted.
      DEFAULT_FILTER = 'tcp port 179'
      DEFAULT_INTERFACE = 'eth0'

      # `lab/topologies/` as an installed gem and a checkout both see it.
      # The gemspec's `require_paths` is `["."]` and its `s.files` is
      # `git ls-files`, so the topologies are shipped and sit two
      # directories above this file either way: the same arithmetic
      # `exe/bgp4r` does for the load path.
      #
      # **Measured rather than reasoned about, the way that file's header
      # records for `capture`**: on 2026-11-02 the gem was built,
      # installed into a throwaway GEM_HOME, and `bgp4r lab new DIR` run
      # from it, which copied `two-speakers` and committed it. So the
      # gemspec needs no change for this command, and a checkout cannot
      # check it, since from a checkout the path is right whatever
      # rubygems does with the bindir.
      #
      # It can still be absent, in an image that copied `bgp/` alone, so
      # `lab` answers a message naming this path rather than raising.
      TOPOLOGIES = File.expand_path('../../lab/topologies', __dir__)

      # `two-speakers` because of the topologies in the repository when
      # this was written it is the only one that needs nothing but
      # bgp4r: `add-path` and `fault-matrix` each want a GoBGP image and
      # `routegen` is a benchmark rather than a lab somebody edits.
      # `docs/routescope-labs.md` section 8 opens with the same one for
      # the same reason, that it tests the plumbing and not the
      # protocol. A topology added later does not change this, since the
      # name is positional and the default is only what `NAME` omitted
      # means.
      DEFAULT_TOPOLOGY = 'two-speakers'

      # What a Compose topology's own file is called. Read in this order,
      # which is Compose's.
      COMPOSE_FILES = %w{compose.yml compose.yaml docker-compose.yml docker-compose.yaml}

      USAGE = <<-TEXT
Usage: bgp4r SUBCOMMAND [options]

  capture   dissect BGP messages off an interface or a pcap file
  sim       run the route injector, with its HTTP API (also: bgp4r-sim)
  routegen  send one generated range to a peer and exit
  lab new   copy a lab topology into a folder of your own, and git-init it
  version   print the bgp4r version

See docs/daemon.md.
      TEXT

      def initialize(out = $stdout, err = $stderr)
        @out = out
        @err = err
      end

      def start(argv)
        case argv.first
        when 'capture'  then capture(argv[1..-1])
        when 'sim'      then sim(argv[1..-1])
        when 'routegen' then routegen(argv[1..-1])
        when 'lab'      then lab(argv[1..-1])
        when 'version'  then version
        when nil, '-h', '--help'
          @out.print USAGE
          0
        else
          @err.print USAGE
          1
        end
      end

      # `bgp4r sim`, which `bgp4r-sim` is an alias for, and `bgp4r
      # routegen`. Both are the same objects the executables run, so
      # there is one implementation of each and the alias cannot drift
      # from the subcommand.
      def sim(argv)
        require 'bgp/sim/server'
        BGP::Sim::Server.new(@out, @err).start(argv)
      end

      def routegen(argv)
        require 'bgp/sim/routegen'
        BGP::Sim::Routegen.new(@out, @err).start(argv)
      end

      def version
        @out.puts BGP::VERSION
        0
      end

      # The topologies this install carries, **discovered and not
      # listed**, which is the one deliberate difference from `ospfv2
      # lab new`. That command keeps a `CLAB_LABS` table beside its
      # templates, so a template added to the repository is invisible
      # until somebody edits the table too; here a folder under
      # `lab/topologies/` is offered the day it lands, and the usage and
      # the refusal below print what was found rather than a list
      # written down anywhere.
      #
      # `root` is a seam, and it is what lets a test say this reads the
      # filesystem: a test points it at a folder holding a name this
      # repository has never had, and a hard coded table cannot answer
      # that. It also gives the missing-folder case somewhere to be
      # tested from.
      def self.topologies(root = TOPOLOGIES)
        return [] unless File.directory?(root)
        Dir.children(root).select { |n| File.directory?(File.join(root, n)) }.sort
      end

      # Copies a topology folder, leaving out what its own `.gitignore`
      # lists, and keeping each file's mode. The `.gitignore` is how
      # `ospfv2`'s `copy_lab` drops the files a router wrote into the
      # template while the template itself was in use, which can belong
      # to root and are no part of a new lab. A topology without one
      # copies whole, so this reads `.gitignore` only when there is one
      # where ospfv2 reads it unconditionally.
      #
      # **`bgp4r-lab`'s own `.gitignore` is why this is not ospfv2's
      # one-line `fnmatch` against a basename.** That is what was
      # written first, and it was filed as a latent defect because no
      # topology here had a `.gitignore` to expose it. `bgp4r-lab`
      # arrived with one carrying `recordings/` and `clab-*/`, and a
      # basename match compares `recordings/` against `recordings` and
      # never fires, so a lab deployed in the template folder would
      # have had containerlab's own working directory copied into every
      # new lab made from it. That is precisely what ospfv2's filter
      # exists to prevent, so the three shapes that appear in a real
      # file are matched for:
      #
      # * a trailing slash is a **directory** pattern, matched against a
      #   directory's basename, and everything under an excluded
      #   directory is skipped with it;
      # * a pattern holding a slash is matched against the **relative
      #   path**, with `FNM_PATHNAME` so `*` does not cross a separator;
      # * anything else is matched against the basename at any depth,
      #   which is git's rule for a pattern with no slash and is what
      #   ospfv2 already did.
      #
      # **This is not gitignore**, and the gap left is in CLAUDE.md
      # under "Known issues to work on": `!` negation is not read, so a
      # re-include is ignored and the file is left out. Getting the rest
      # right means ordering, `**` and anchoring, which is `git
      # check-ignore` and a git this does not otherwise need.
      #
      # `fileutils` is required here and not at the top of the file, for
      # the reason the class header gives about `bgp/sim`: `bgp4r
      # capture` is what runs in a lab's capture container and it has no
      # business loading a file copier. Measured on 2026-11-02 rather
      # than assumed, since CLAUDE.md records a bundled gem killing a
      # require before a test ran: `Gem::Specification.find_by_name
      # ("fileutils").default_gem?` is true on the Ruby 3.3.6 this was
      # written on, and `bgp/daemon/api.rb` already requires it in
      # shipped code, so this adds no question that was not already
      # open. The local answer is not the CI answer, and CI runs 3.3,
      # 3.4 and 4.0.
      def self.copy_lab(src, dst)
        require 'fileutils'
        gitignore = File.join(src, '.gitignore')
        ignore = if File.file?(gitignore)
                   File.readlines(gitignore, :chomp => true).collect(&:strip).
                     reject { |l| l.empty? || l.start_with?('#') }
                 else
                   []
                 end
        FileUtils.mkdir_p(dst)
        # Parents sort before their children, since a string that is a
        # prefix of another sorts first, so an excluded directory is
        # always seen before anything inside it.
        excluded = []
        Dir.glob('**/*', File::FNM_DOTMATCH, :base => src).sort.each do |rel|
          base = File.basename(rel)
          next if base == '.' || base == '..'
          next if excluded.any? { |d| rel.start_with?(d + '/') }
          from = File.join(src, rel)
          directory = File.directory?(from)
          if ignored?(rel, directory, ignore)
            excluded << rel if directory
            next
          end
          to = File.join(dst, rel)
          if directory
            FileUtils.mkdir_p(to)
          else
            FileUtils.cp(from, to)
            # **The chmod is load-bearing only under a umask other than
            # 022, and that is worth saying because it looks redundant.**
            # Measured on 2026-11-02: `FileUtils.cp` opens the
            # destination with the source's mode, so under an 022 umask
            # a 0755 source already arrives 0755 and this line changes
            # nothing; under 077 it arrives **0700**, because the umask
            # applies to that open, and this line is the whole of what
            # keeps an executable bit. The test for it therefore sets a
            # restrictive umask, since nothing else can see the line.
            File.chmod(File.stat(from).mode & 0o777, to)
          end
        end
      end

      # One `.gitignore` line against one entry. The three shapes are in
      # `copy_lab`'s header with why each is there.
      def self.ignored?(rel, directory, patterns)
        base = File.basename(rel)
        patterns.any? do |pat|
          if pat.end_with?('/')
            directory && File.fnmatch?(pat.chomp('/'), base, File::FNM_DOTMATCH)
          elsif pat.include?('/')
            File.fnmatch?(pat.sub(%r{\A/}, ''), rel,
                          File::FNM_DOTMATCH | File::FNM_PATHNAME)
          else
            File.fnmatch?(pat, base, File::FNM_DOTMATCH)
          end
        end
      end

      # The images a Compose topology builds here rather than pulls, so
      # the message below can name what to build. A value holding `${`
      # is an environment variable with a registry image behind it and
      # one holding `/` is somebody else's, so neither is ours.
      def self.local_images(file)
        File.readlines(file).collect { |l| l[/^\s*image:\s*(\S+)\s*$/, 1] }.compact.
          reject { |i| i.include?('${') || i.include?('/') }.uniq.sort
      end

      # `bgp4r lab new DIR [NAME]`, which `docs/routescope-labs.md`
      # section 6 asks for: it copies a topology folder and git-inits
      # it, because a lab somebody edits in place is a lab whose history
      # is the repository's, and the git init is what makes a saved
      # configuration diffable.
      #
      # **The design wrote it as `--routescope` and NAME replaced that**,
      # which is corrected in section 8 of that document rather than
      # left disagreeing with the code. A flag per template is `ospfv2
      # lab new`'s shape and has a flag's problem: one more topology is
      # one more flag, one more arm of a `fetch` and one more row of a
      # table. A positional name against the discovered folders needs
      # none of them, so the containerlab topology that document designs
      # is `bgp4r lab new DIR bgp4r-lab` and arrives with no change
      # here.
      def lab(argv, root = TOPOLOGIES)
        require 'optparse'
        return lab_help(@err, root, 1) unless argv.first == 'new'
        argv = argv[1..-1]
        git = true
        begin
          OptionParser.new { |o| o.on('--no-git') { git = false } }.parse!(argv)
        rescue OptionParser::ParseError => e
          @err.puts e.message
          return lab_help(@err, root, 1)
        end
        dir = argv.shift
        return lab_help(@err, root, 1) unless dir
        names = CLI.topologies(root)
        if names.empty?
          @err.puts "no lab topologies here: #{root} is not in this install"
          return 1
        end
        name = argv.shift || DEFAULT_TOPOLOGY
        unless names.include?(name)
          @err.puts "no topology #{name}. Found here: #{names.join(', ')}"
          return 1
        end
        src = File.join(root, name)
        dir = File.expand_path(dir)
        if File.exist?(dir) && !(File.directory?(dir) && Dir.empty?(dir))
          @err.puts "#{dir} exists and is not empty"
          return 1
        end
        begin
          CLI.copy_lab(src, dir)
        rescue SystemCallError => e
          parent = File.dirname(dir)
          hint = File.exist?(parent) && !File.writable?(parent) ?
                   " (#{parent} is not writable)" : ''
          @err.puts "cannot make the lab folder: #{e.message}#{hint}"
          return 1
        end
        @out.puts "lab created in #{dir}"
        @out.puts lab_git_init(dir, name) if git
        @out.print lab_start(name, src, dir)
        0
      end

      def lab_help(io, root = TOPOLOGIES, status = 0)
        names = CLI.topologies(root)
        found = names.empty? ? '  (none)' : names.collect { |n| "  #{n}" }.join("\n")
        io.print <<~TEXT
          Usage: bgp4r lab new DIR [NAME] [--no-git]

            DIR        the folder to create. It must not exist, or be empty.
            NAME       the topology to copy (default: #{DEFAULT_TOPOLOGY})
            --no-git   copy it and do not make it a git repository

          Topologies found in #{root}:
          #{found}

          See docs/routescope-labs.md.
        TEXT
        status
      end

      # The lab's commits are configuration snapshots, so the repository
      # carries the lab's own identity, set here and nowhere else: a
      # container with no global git config cannot commit without one,
      # and this is `ospfv2`'s `lab_git_init` for that reason. Every
      # failure is a line of output rather than a non-zero status,
      # because the copy succeeded and a lab with no history is still a
      # lab.
      def lab_git_init(dir, name)
        ok = system('git', '-C', dir, 'init', '-q', :out => File::NULL, :err => File::NULL) &&
             system('git', '-C', dir, 'config', 'user.name', 'lab', :out => File::NULL, :err => File::NULL) &&
             system('git', '-C', dir, 'config', 'user.email', 'lab@configs', :out => File::NULL, :err => File::NULL) &&
             system('git', '-C', dir, 'add', '-A', :out => File::NULL, :err => File::NULL)
        return 'git: not available, the lab folder has no history' unless ok
        if system('git', '-C', dir, 'commit', '-q', '-m',
                  "Lab created from bgp4r lab/topologies/#{name}",
                  :out => File::NULL, :err => File::NULL)
          'git: repository created with a first commit'
        else
          'git: repository created; the first commit failed (set git user.name and user.email, then commit)'
        end
      end

      # How to start it, **worked out from the folder's own files and not
      # from a list**, which is what keeps discovery honest: a table of
      # which topology is which kind is the `CLAB_LABS` table again.
      # A containerlab topology is a `*.clab.yml`, which is
      # containerlab's own convention and what every routescope lab and
      # every one of ospfv2's is; a Compose one is a `compose.yml`.
      #
      # **A copied Compose topology cannot be built where it landed, and
      # that is a real limit rather than a caveat.** All four of today's
      # have `build.context: ../../..`, the repository root, so the copy
      # resolves that context to three directories above wherever it
      # went. The image is named, though, and `docker compose up` builds
      # only when the named image is missing, so building it once in a
      # checkout and running the copy without `--build` works. Said
      # here because a person who follows `lab/README.md` instead will
      # meet it as a build error about a missing Dockerfile.
      def lab_start(name, src, dir)
        readme = File.file?(File.join(dir, 'README.md')) ?
                   "\n#{dir}/README.md says what it shows.\n" : ''
        clab = Dir.glob('*.clab.yml', :base => src).sort.first
        compose = COMPOSE_FILES.find { |f| File.file?(File.join(src, f)) }
        how = if clab
                <<~TEXT

                  #{name} is a containerlab topology. Start it from routescope's Labs
                  panel, or by hand:

                    cd #{dir} && sudo containerlab deploy -t #{clab}
                    cd #{dir} && sudo containerlab destroy -t #{clab}
                TEXT
              elsif compose
                images = CLI.local_images(File.join(src, compose))
                what = images.empty? ? 'the image' : images.join(' and ')
                <<~TEXT

                  #{name} is a Compose topology. Its #{compose} builds
                  #{what} from the bgp4r checkout, with a context three
                  directories up that this copy does not have, so build it in a
                  checkout once and then run the copy without --build:

                    docker compose -f lab/topologies/#{name}/#{compose} build   # in a bgp4r checkout
                    cd #{dir} && docker compose up -d
                    cd #{dir} && docker compose logs -f
                    cd #{dir} && docker compose down
                TEXT
              else
                "\n#{name} holds neither a *.clab.yml nor a " \
                "#{COMPOSE_FILES.first}, so there is nothing here that " \
                "says how to start it.\n"
              end
        how + readme
      end

      # Reads BGP off an interface, a pcap file or standard input, and
      # prints one JSON line per BGP message:
      #
      #   {"capture": {"interface":, "file":, "link":, "filter":, "unit":}}
      #   {"packet": {"seq":, "time":, "flow":, "length":, "hex":,
      #               "summary":, "fields":, "errors":}}
      #   {"error": "..."}   and the exit status is 1
      #
      # The envelope is ospfv2's, which `docs/routescope-labs.md` section 4
      # gives as the contract: a console's decoder pane is generic over
      # that shape, so matching it costs routescope no code.
      #
      # **One key of it means something different here and the header says
      # so**: `unit` is `message`, where ospfv2's unit is a frame. A BGP
      # message can arrive in two frames and two can share one, so a
      # `packet` line is one BGP message, `hex` is that message's own
      # octets, `length` is their count and every offset in `fields` is
      # from the message's first octet. The transport is `flow`, a
      # direction as `src:port > dst:port`, rather than byte offset fields,
      # because the frame headers are not octets of the message.
      def capture(argv)
        require 'json'
        require 'time'
        require 'optparse'
        opts = { :interface => DEFAULT_INTERFACE, :filter => DEFAULT_FILTER,
                 :count => nil, :file => nil }
        OptionParser.new do |o|
          o.on('-i', '--interface IFACE') { |v| opts[:interface] = v }
          o.on('-r', '--read FILE', 'a pcap file, - for stdin') { |v| opts[:file] = v }
          o.on('-f', '--filter EXPR') { |v| opts[:filter] = v }
          o.on('-c', '--count N', Integer) { |v| opts[:count] = v }
        end.parse!(argv)
        @out.sync = true if @out.respond_to?(:sync=)
        io, pid = source(opts)
        reader = Pcap::Reader.new(io)
        link = Dissect::LINKS[reader.link]
        raise ArgumentError, "link type #{reader.link} is not supported" unless link
        @out.puts JSON.generate(:capture => {
                                  :interface => opts[:file] ? nil : opts[:interface],
                                  :file => opts[:file], :link => link.to_s,
                                  :filter => opts[:file] ? nil : opts[:filter],
                                  :unit => 'message' })
        stream = Stream.new
        seq = 0
        reader.each do |rec|
          seg = Dissect.segment(rec.data, :link => link)
          stream.push(seg).each do |msg|
            seq += 1
            d = Dissect.message(msg.octets).to_h
            d[:errors] = msg.errors + d[:errors]
            @out.puts JSON.generate({ :packet =>
              { :seq => seq, :time => rec.time.utc.iso8601(6), :flow => msg.flow,
                :length => msg.octets.bytesize,
                :hex => msg.octets.unpack('H*')[0] }.merge(d) })
          end
          break if opts[:count] and seq >= opts[:count]
        end
        0
      rescue Pcap::Error, ArgumentError, SystemCallError => e
        @out.puts JSON.generate(:error => e.message)
        1
      ensure
        if pid
          begin ; Process.kill('TERM', pid) ; rescue StandardError ; end
          begin ; Process.wait(pid) ; rescue StandardError ; end
        end
      end

      private

      # tcpdump into a pipe, as ospfv2 does, because a pure Ruby packet
      # socket would be a native dependency and the library has one gem
      # and means to keep it. `-U` is what makes a live capture live: it
      # flushes each record rather than filling a buffer first.
      #
      # **The filter is applied here and reported, never taken from the
      # caller of the contract.** `docs/routescope-labs.md` section 4:
      # routescope passes no filter and only displays the string the image
      # says it used, so the default has to be right on its own.
      # **The nine lines from `::IO.pipe` down, and the two that kill the
      # child in `capture`'s ensure, are the only lines in bgp/capture/
      # that no test runs**, which is said here rather than left for a
      # coverage report to raise as a question. They are the live path:
      # tcpdump is not installed in the sandbox this was written in, and
      # spawning it in a unit test would want a privileged interface. The
      # file path beside them is exercised in full, and the one branch a
      # test can reach without tcpdump, a pcap file that is not there, is
      # asserted because of the bug below.
      #
      # **The rescue is around the spawn and nothing else, deliberately.**
      # A method level `rescue Errno::ENOENT` also catches `File.open` of
      # a pcap file that is not there and reports it as tcpdump being
      # missing, which is a confident wrong answer about the one thing
      # the caller got wrong. ospfv2's `capture_source` has that shape and
      # the same fault; found here by a test for a path that does not
      # exist.
      def source(opts)
        return [$stdin.binmode, nil] if opts[:file] == '-'
        return [File.open(opts[:file], 'rb'), nil] if opts[:file]
        r, w = ::IO.pipe
        begin
          pid = Process.spawn('tcpdump', '-U', '-n', '-s', '0', '-w', '-',
                              '-i', opts[:interface], *opts[:filter].split,
                              :out => w, :err => File::NULL)
        rescue Errno::ENOENT
          w.close
          r.close
          raise ArgumentError, 'tcpdump is not installed here'
        end
        w.close
        [r, pid]
      end

    end

  end
end
