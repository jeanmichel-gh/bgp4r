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

require 'bgp/daemon/client'

module BGP
  module Daemon

    # The operator commands of `bgp4r-cli`, and its prompt:
    #
    #   r1> show bgp 10.0.0.0/8
    #   r1> sh b s
    #   r1> show ?
    #   r1> clear help
    #
    # docs/design/bgp4r-cli-shell.md is the design. Its shape is
    # ospf-cli's, in ospfv2's lib/ospfv2/command_line/shell.rb, so a
    # person types the same way on an ospfd node and a bgp4rd node. It is
    # a second shell of that shape and not a shared one, because the two
    # repositories do not depend on each other.
    #
    # **One path for every way a command arrives.** `-c`, the bare words
    # on the command line and the prompt all call `execute`, which
    # returns a Result and prints nothing. So a test reads a String, and
    # the three cannot disagree.
    #
    # **The grammar is a table, not a parser.** Each node is a keyword or
    # an argument (PEER, PREFIX), with a line of help and, where the
    # words so far are a whole command, the method that runs it. A word
    # may be any unique prefix of a keyword. Where a node takes both a
    # keyword and an argument, as `show bgp` does, the keyword is tried
    # first: `show bgp s` is the summary, and no prefix starts with a
    # letter past f.
    #
    # `reline` is required only when the prompt opens on a terminal. It
    # is in Ruby's standard library, so `logger` stays the only runtime
    # gem, and `bgp4r-cli -c` loads no more than it did.
    class Shell

      # One node of the grammar. `word` is the keyword, or nil for an
      # argument, which is then named by `arg` (:peer, :prefix) and shown
      # as `name`. An argument with `rest` takes every word after it too,
      # as `config set PATH... VALUE` does.
      Node = Struct.new(:word, :arg, :name, :help, :action, :children, :rest) do
        def label = word || name
        def keywords = children.select(&:word)
        def argument = children.find(&:arg)
      end

      def self.kw(word, help, action = nil, children = [])
        Node.new(word, nil, nil, help, action, children)
      end

      def self.arg(arg, name, help, action = nil, children = [])
        Node.new(nil, arg, name, help, action, children)
      end

      def self.rest(arg, name, help, action)
        Node.new(nil, arg, name, help, action, [], true)
      end

      # The `bgp` words, under `show bgp` and under `show ip bgp`, the
      # IOS form. Built twice rather than shared, so each node has one
      # parent and `commands` lists both forms.
      def self.show_bgp
        kw('bgp', 'the Loc-RIB, as a router prints it', :routes, [
          kw('summary', 'the router, and one line per neighbor', :summary),
          kw('neighbors', 'every neighbor, in detail', :neighbors, [
            arg(:peer, 'PEER', 'one neighbor, in detail', :neighbors, [
              kw('received-routes', 'what PEER sent, as received', :received),
              kw('advertised-routes', 'what went to PEER, and what did not and why', :advertised)
            ])
          ]),
          arg(:prefix, 'PREFIX', 'one prefix, in detail', :routes)
        ])
      end

      def self.clear_bgp
        kw('bgp', 'a BGP session', nil, [
          arg(:peer, 'PEER', 'reset the session with PEER, an address', :clear, [
            kw('soft', 'keep the session up', nil, [
              kw('in', 'ask PEER to send its routes again: a ROUTE-REFRESH', :refresh)
            ])
          ])
        ])
      end

      GRAMMAR = kw('', '', nil, [
        kw('show', 'what the daemon holds', nil, [
          show_bgp,
          kw('ip', 'the IOS form: show ip bgp is show bgp', nil, [show_bgp]),
          kw('fib', 'what the daemon put in the kernel table', :fib),
          kw('link-state', 'BGP-LS routes, sent and received', :link_state),
          kw('configuration', 'the running configuration, as set lines', :configuration, [
            kw('candidate', 'the candidate configuration', :candidate)
          ]),
          kw('log', "the daemon's last log lines, oldest first", :log)
        ]),
        kw('clear', 'reset something', nil, [
          clear_bgp,
          kw('ip', 'the IOS form: clear ip bgp is clear bgp', nil, [clear_bgp])
        ]),
        kw('enable', 'let a stopped session come back', nil, [
          kw('bgp', 'a BGP session', nil, [
            arg(:peer, 'PEER', 'the neighbor, an address', :enable)
          ])
        ]),
        kw('disable', 'end a session and keep it down', nil, [
          kw('bgp', 'a BGP session', nil, [
            arg(:peer, 'PEER', 'the neighbor, an address', :disable)
          ])
        ]),
        kw('monitor', 'watch something as it happens, until Ctrl-C', nil, [
          kw('events', 'the daemon\'s events, one line each', :monitor)
        ]),
        kw('config', 'the candidate configuration: change it, check it, commit it', nil, [
          kw('show', 'the running configuration, as set lines', :configuration, [
            kw('candidate', 'the candidate configuration', :candidate)
          ]),
          kw('set', 'set a value in the candidate', nil, [
            rest(:line, 'PATH... VALUE', 'as in show configuration: neighbors 10.0.10.1 hold_time 60',
                 :config_set)
          ]),
          kw('delete', 'delete a value or a subtree from the candidate', nil, [
            rest(:line, 'PATH...', 'as in show configuration: neighbors 10.0.10.1 hold_time', :config_delete)
          ]),
          kw('compare', 'the lines the candidate changes', :config_compare),
          kw('check', 'check the candidate, and say what a commit would do', :config_check),
          kw('commit', 'apply the candidate', :config_commit, [
            kw('comment', 'with a comment the history keeps', nil, [
              rest(:comment, 'TEXT', 'the comment', :config_commit)
            ])
          ]),
          kw('discard', 'make the candidate the running configuration again', :config_discard),
          kw('history', 'the commits, newest first, numbered as rollback takes them', :config_history),
          kw('rollback', 'load an older configuration into the candidate', nil, [
            arg(:number, 'N', '0 is the running configuration, 1 the one before the last commit',
                :config_rollback)
          ])
        ])
      ]).freeze

      # Words the prompt answers that are not commands of the daemon.
      BUILTINS = { 'help' => 'this list; `? ` or `help` after words lists what follows',
                   'exit' => 'leave', 'quit' => 'leave' }.freeze

      # Every whole command, with its arguments by name: `show bgp
      # PREFIX`. What `-c` refuses with, and what docs/bgp4r-cli.md lists.
      def self.commands(node = GRAMMAR, path = [])
        out = []
        out << path.join(' ') if node.action
        node.children.each { |c| out.concat(commands(c, path + [c.label])) }
        out
      end

      COMMANDS = commands.freeze

      # The methods that answer many lines rather than one, so they are
      # printed as they arrive until Ctrl-C.
      #
      # **The client's own list and not `Api::STREAM_METHODS`.** This file
      # requires `bgp/daemon/client` and nothing else, so `bgp4r-cli`
      # loads a socket and a JSON parser rather than the whole library and
      # a Speaker, and `events.unsubscribe` is in the server's list and
      # is not something a caller starts. cli_test.rb holds this list
      # inside the server's so the two cannot disagree about a name.
      STREAMS = %w[events.subscribe].freeze

      # A method's parameters, from the words after its name: one JSON
      # object, or `key=value` words. A value that reads as an integer,
      # `true`, `false` or `null` becomes that, one that starts with `[`
      # or `{` is JSON, and any other is a string, so
      # `peer=10.0.10.1` needs no quotes.
      def self.params(words)
        require 'json'
        return {} if words.empty?
        if words[0].start_with?('{', '[')
          params = JSON.parse(words.join(' '))
          raise Refused, 'the parameters are a JSON object, or key=value words' unless params.is_a?(Hash)
          return params
        end
        words.each_with_object({}) do |w, h|
          key, text = w.split('=', 2)
          raise Refused, "#{w.inspect} is not key=value" if text.nil? || key.empty?
          h[key] = convert(text)
        end
      rescue JSON::ParserError => e
        raise Refused, "the parameters are not JSON: #{e.message[0, 120]}"
      end

      def self.convert(text)
        case text
        when /\A-?\d+\z/ then text.to_i
        when 'true' then true
        when 'false' then false
        when 'null' then nil
        when /\A[\[{]/ then JSON.parse(text)
        else text
        end
      end

      # What `execute` answers. `text` is printed as it is, `error` is a
      # message without a prefix, and `exit` says the person asked to
      # leave.
      Result = Struct.new(:text, :error, :exit)

      class Refused < StandardError ; end

      attr_reader :hostname

      # `out` is where a stream prints as it goes, since a stream does not
      # return until it is stopped. `grammar` is for the tests.
      def initialize(client, style: 'ios', hostname: 'bgp4r', out: $stdout, grammar: GRAMMAR)
        @client = client
        @grammar = grammar
        @style = style
        @hostname = hostname
        @out = out
      end

      def prompt = "#{@hostname}> "

      # Runs one line and answers a Result. The daemon's refusal is an
      # error and not an exception, so the prompt stays up after one.
      def execute(line)
        line = line.to_s.strip
        return Result.new('', nil) if line.empty? || line.start_with?('#')
        return Result.new(help(line.chomp('?')), nil) if line.end_with?('?')
        words = line.split
        if words.size == 1 && %w[exit quit].include?(words[0])
          return Result.new('', nil, true)
        end
        return Result.new(help_text(@grammar, true), nil) if words == ['help']
        return Result.new(api(words), nil) if words[0].include?('.')
        node, args, helped = walk(words, line)
        return Result.new(help_text(node, false), nil) if helped
        raise Refused, incomplete(words, node) unless node.action
        Result.new(send(node.action, args, words), nil)
      rescue Refused, Client::Error => e
        Result.new('', e.message)
      end

      # A method by name, at the prompt as on the command line: the
      # result as indented JSON, or a stream line by line.
      def api(words)
        params = Shell.params(words[1..])
        return stream(words[0], params) { |line| JSON.generate(line) } if STREAMS.include?(words[0])
        "#{JSON.pretty_generate(@client.call(words[0], params))}\n"
      end

      # Prints each line the daemon streams, through the block, until the
      # daemon ends it or Ctrl-C does. A line the block answers nil for is
      # not printed. After Ctrl-C the stream is ended with
      # `events.unsubscribe`, so the daemon keeps no subscriber, and the
      # connection is closed, so a line still on its way cannot answer
      # the next command.
      def stream(method, params)
        @client.stream(method, params) do |line|
          text = yield(line)
          @out.puts(text) if text
        end
        ''
      rescue Interrupt
        @client.unsubscribe
        @client.close
        ''
      end

      # The words that can complete `partial`, with `before` the line up
      # to it. For PEER they are the configured neighbors, read from the
      # daemon on each Tab; PREFIX is not completed.
      def completions(before, partial)
        words = before.split
        node = words.empty? ? @grammar : walk(words, before).first
        found = node.keywords.collect(&:word)
        found.concat(BUILTINS.keys) if node.equal?(@grammar)
        found.concat(peers) if node.argument && node.argument.arg == :peer
        found.select { |w| w.start_with?(partial) }
      rescue Refused, Client::Error
        []
      end

      # The prompt loop. On a terminal it edits lines with `reline` and
      # keeps the session's history; otherwise it reads one command per
      # line, which is what the tests drive. Answers go to `output`, and
      # errors too, after `% `, as a router prints them.
      #
      # Ctrl-C drops the connection, since a reply may still be on its
      # way, and the next command opens a new one. Ctrl-D, `exit` and
      # `quit` leave.
      def interactive(input = $stdin, output = $stdout)
        reader = input.is_a?(IO) && input.tty? ? reline(input, output) : nil
        prefill = nil
        loop do
          line = reader ? reader.call(prefill) : input.gets
          break if line.nil?
          prefill = line.strip.end_with?('?') ? line.strip.chomp('?') : nil
          r = execute(line)
          output.print(r.text)
          output.puts("% #{r.error}") if r.error
          @client.close if r.error
          break if r.exit
        rescue Interrupt
          output.puts
          @client.close
          prefill = nil
        end
      end

      private

      # Follows `words` down the grammar and answers the node reached,
      # the arguments met on the way, and whether the last word asked for
      # help. Refuses what is not a command. Once a `rest` argument has
      # started, every word after it is the argument's, `help` and
      # keywords too, so `?` is the only way to ask there.
      def walk(words, line)
        node, args = @grammar, {}
        words.each_with_index do |w, i|
          if node.rest
            args[node.arg] << ' ' << w
            next
          end
          if w == 'help' && i == words.size - 1 && help_word?(node)
            return [node, args, true]
          end
          node, value = step(node, w, words[0..i], line)
          value = +value if value
          args[node.arg] = value if node.arg
        end
        [node, args, false]
      end

      # `help` is help where the grammar wants a keyword, or an argument
      # `help` cannot be: an address or a prefix. Where it could be the
      # argument, as `config rollback help` could, it is the argument,
      # and `?` asks instead.
      def help_word?(node)
        !node.keywords.empty? || node.argument.nil? || !fits?(node.argument, 'help')
      end

      def step(node, w, upto, line)
        exact = node.keywords.find { |k| k.word == w }
        return [exact, nil] if exact
        prefixed = node.keywords.select { |k| k.word.start_with?(w) }
        return [prefixed[0], nil] if prefixed.size == 1
        if prefixed.size > 1
          raise Refused, "#{upto.join(' ').inspect} is ambiguous: #{prefixed.collect(&:word).join(', ')}"
        end
        return [node.argument, w] if node.argument && fits?(node.argument, w)
        raise Refused, unknown(node, upto)
      end

      # PEER is an address and PREFIX an address with or without a
      # length, checked here so a word that is neither is refused with
      # what fits, rather than sent to the daemon. N and the rest are the
      # daemon's to check.
      def fits?(argument, w)
        case argument.arg
        when :peer then address?(w) && !w.include?('/')
        when :prefix then address?(w)
        else true
        end
      end

      def address?(w)
        require 'ipaddr'
        IPAddr.new(w)
        true
      rescue IPAddr::Error
        false
      end

      # What fits where the word did not: the words that may follow the
      # ones before it. At the start of a line that is the command words,
      # and a method name.
      def unknown(node, upto)
        before = upto[0..-2].join(' ')
        choices = node.children.collect(&:label)
        if before.empty?
          return "#{upto.last.inspect} is not a command. A command starts with #{choices.join(', ')}, " \
                 'or is a method name with a dot, such as show.peers. ? lists them'
        end
        what = node.argument && { :peer => 'an address', :prefix => 'a prefix' }[node.argument.arg]
        why = what ? ", and #{upto.last.inspect} is not #{what}" : ''
        "#{upto.join(' ').inspect} is not a command#{why}. After #{before.inspect} comes #{choices.join(', ')}"
      end

      def incomplete(words, node)
        "#{words.join(' ').inspect} is not a whole command. After it comes #{node.children.collect(&:label).join(', ')}"
      end

      # `?` at the end of a line. After a space, or alone, it lists what
      # may follow the words; against a word, the keywords that word may
      # be the start of.
      def help(line)
        words = line.split
        partial = line.empty? || line.end_with?(' ') ? nil : words.pop
        node = words.empty? ? @grammar : walk(words, line).first
        return help_text(node, node.equal?(@grammar)) unless partial
        rows = node.keywords.select { |k| k.word.start_with?(partial) }.collect { |k| [k.word, k.help] }
        if node.equal?(@grammar)
          rows.concat(BUILTINS.select { |w, _| w.start_with?(partial) }.to_a)
        end
        rows << [node.argument.name, node.argument.help] if rows.empty? && node.argument
        rows << [node.name, 'more words'] if rows.empty? && node.rest
        raise Refused, "nothing here starts with #{partial.inspect}" if rows.empty?
        table(rows)
      end

      def help_text(node, top)
        rows = node.children.collect { |c| [c.label, c.help] }
        rows << [node.name, 'more words'] if node.rest
        rows.concat(BUILTINS.to_a) if top
        rows << ['METHOD', 'a method by name, as show.peers or peer.stop peer=10.0.10.1'] if top
        rows << ['<cr>', 'run it'] if node.action
        table(rows)
      end

      def table(rows)
        width = rows.collect { |r| r[0].size }.max
        rows.collect { |w, h| format("  %-*s  %s\n", width, w, h) }.join
      end

      def peers
        Array(@client.call('show.peers')).collect { |p| p['address'].to_s }
      end

      def reline(input, output)
        require 'reline'
        Reline.input = input
        Reline.output = output
        Reline.completion_append_character = ' '
        Reline.completer_word_break_characters = " \t"
        Reline.completion_proc = lambda do |partial|
          completions(Reline.line_buffer.to_s[0, Reline.point.to_i - partial.size], partial)
        end
        lambda do |prefill|
          Reline.pre_input_hook = prefill ? -> { Reline.insert_text(prefill) } : nil
          Reline.readline(prompt, true)
        end
      end

      # ==================================================================
      # The commands. Each takes the arguments and the words, and answers
      # the text to print.

      # `show bgp` and `show bgp PREFIX`, rendered by the daemon through
      # bgp/rib/show.rb's three styles. bgp4r-cli does not render them
      # itself: `Show` takes a Rib::Table and the Table is in the daemon,
      # and a second renderer here would be two copies of three vendor
      # styles.
      def routes(args, _words)
        params = { 'style' => @style }
        params['prefix'] = args[:prefix] if args[:prefix]
        @client.call('show.text', params).to_s
      end

      # `show bgp summary`, in the shape of the command every router has.
      # It is rendered here, because `Show` has **no** summary form: there
      # is no vendor sample behind one. The columns are this file's own.
      def summary(_args, _words)
        s = @client.call('show.status')
        sum = s['summary'] || {}
        out = +''
        out << format("BGP router identifier %s, local AS number %s\n", s['router_id'], s['as'])
        out << format("%d peer(s), %d established, %d prefix(es) in the Loc-RIB\n\n",
                      sum['peers'].to_i, sum['established'].to_i, sum['rib'].to_i)
        out << format("%-20s %-8s %-14s %10s %8s %8s %s\n",
                      'Neighbor', 'AS', 'State', 'Up/Down', 'PfxRcd', 'PfxSnt', 'Description')
        Array(s['peers']).each do |p|
          out << format("%-20s %-8s %-14s %10s %8s %8s %s\n",
                        p['address'], p['remote_as'], p['state'],
                        p['uptime'] ? "#{p['uptime']}s" : 'never',
                        p['received'] || 0, p['sent'] || 0, p['description'])
        end
        out
      end

      # `show fib`, what this daemon put in the kernel's forwarding table,
      # and what it did not: a prefix it skipped with the reason, and a
      # prefix the kernel refused with its error. The layout is this
      # file's own, as the summary's is. Every page of `show.fib` is read,
      # so a large table prints whole rather than its first page.
      #
      # It is bgp4rd's account and not the kernel's. `ip route show table
      # N` is the other question, and the header names the table to ask.
      def fib(_args, _words)
        rows, offset, info = [], 0, {}
        loop do
          page = @client.call('show.fib', 'offset' => offset)
          info = page['fib'] || {}
          rows.concat(Array(page['rows']))
          offset = page['next_offset'] or break
        end
        return "No FIB: this daemon has no fib: block, so it installs nothing.\n" unless info['configured']
        out = +''
        out << format("FIB: %s, %d route(s) installed\n\n", info['backend'], rows.size)
        out << format("%-20s %s\n", 'Prefix', 'Next hop')
        rows.each { |r| out << format("%-20s %s\n", r['prefix'], r['next_hop']) }
        skipped = Array(info['skipped'])
        unless skipped.empty?
          out << "\nNot installed:\n"
          skipped.each { |r| out << format("%-20s %s\n", r['prefix'], r['reason']) }
        end
        failed = Array(info['failed'])
        unless failed.empty?
          out << "\nRefused by the kernel:\n"
          failed.each { |r| out << format("%-20s %s\n", r['prefix'], r['error']) }
        end
        out
      end

      # `show link-state`, the rows of `show.link_state` as a table: what
      # this daemon sent as a BGP-LS Producer, under peer `-`, and what it
      # received, per peer. Every page is read. The layout is this
      # file's own, as the summary's is.
      def link_state(_args, _words)
        rows, offset = [], 0
        loop do
          page = @client.call('show.link_state', 'offset' => offset)
          rows.concat(Array(page['rows']))
          offset = page['next_offset'] or break
        end
        return "No BGP-LS routes.\n" if rows.empty?
        out = +''
        out << format("%d BGP-LS route(s)\n\n", rows.size)
        line = "%-15s %-6s %-5s %-7s %-20s %-20s %6s %s\n"
        out << format(line, 'Peer', 'Type', 'Proto', 'Area', 'Local', 'Remote or prefix', 'Metric', 'Node')
        rows.each do |r|
          node = [r['route_type'], r['name'], *Array(r['flags']), *Array(r['areas'])].compact.join(' ')
          out << format(line, r['peer'] || '-', r['type'], proto(r['protocol_id']), r['area'] || '-', r['local'],
                        r['remote'] || r['prefix'], r['metric'], node).sub(/ +\n\z/, "\n")
        end
        out
      end

      # RFC 9552 section 5.2, Table 2: 1 and 2 are IS-IS's levels, 3 is
      # OSPFv2. Any other prints as its number.
      def proto(pid)
        { 1 => 'L1', 2 => 'L2', 3 => 'OSPF' }.fetch(pid, pid.to_s)
      end

      # `show configuration`, bgp4rd's own configuration in the set lines
      # `bgp/daemon/config.rb` defines, so a person reads what a driver
      # diffs. `show.configuration` with no `format` answers YAML
      # instead, which is the form the file is in.
      def configuration(_args, _words)
        @client.call('show.configuration', 'format' => 'set').to_s
      end

      def candidate(_args, _words)
        @client.call('show.configuration', 'format' => 'set', 'candidate' => true).to_s
      end

      # ==================================================================
      # `config`: each command is one config.* method, and the set and
      # delete lines are passed as they are, for bgp/daemon/config.rb to
      # read and refuse. The texts are this file's own, as the summary's
      # columns are. `set` and `delete` print nothing when they work, as a
      # router's do.

      def config_set(args, _words) = load_line("set #{args[:line]}")

      def config_delete(args, _words) = load_line("delete #{args[:line]}")

      def load_line(line)
        r = @client.call('config.load', 'lines' => [line])
        errors = Array(r['errors'])
        raise Refused, errors.join('; ') unless errors.empty?
        ''
      end

      def config_compare(_args, _words)
        lines = Array(@client.call('config.compare'))
        return "No changes: the candidate is the running configuration.\n" if lines.empty?
        lines.collect { |l| "#{l}\n" }.join
      end

      # `config.commit` with `check` answers the changes and, under
      # `warnings`, what applying them would do to a session.
      def config_check(_args, _words)
        r = commit_call('check' => true)
        changes = Array(r['changes'])
        return "Check passed: no changes to commit.\n" if changes.empty?
        out = +"Check passed: #{changes.size} change(s) to commit.\n"
        changes.each { |l| out << "  #{l}\n" }
        Array(r['warnings']).each { |w| out << "Note: #{w}\n" }
        out
      end

      def config_commit(args, _words)
        params = {}
        params['comment'] = args[:comment] if args[:comment]
        r = commit_call(params)
        changes = Array(r['changes'])
        return "Nothing to commit: the candidate is the running configuration.\n" if changes.empty?
        out = +"Committed #{changes.size} change(s).\n"
        changes.each { |l| out << "  #{l}\n" }
        Array(r['warnings']).each { |w| out << "Warning: #{w}\n" }
        out
      end

      def commit_call(params)
        r = @client.call('config.commit', params)
        raise Refused, "commit refused: #{Array(r['errors']).join('; ')}" unless r['ok']
        r
      end

      def config_discard(_args, _words)
        @client.call('config.discard')
        "Discarded: the candidate is the running configuration again.\n"
      end

      # Row i of `config.history` is rollback i, docs/daemon.md says, so
      # the rows are numbered from 0.
      def config_history(_args, _words)
        rows = Array(@client.call('config.history'))
        return "No commits yet.\n" if rows.empty?
        out = format("%-3s %-25s %-8s %s\n", '#', 'Time', 'Changes', 'Comment')
        rows.each_with_index do |r, i|
          out << format("%-3d %-25s %-8s %s\n", i, r['time'], r['changes'], r['comment']).sub(/ +\n\z/, "\n")
        end
        out
      end

      # N goes to the daemon as a number when it is one, and as it was
      # typed when it is not, so the daemon's refusal names it.
      def config_rollback(args, _words)
        n = args[:number] =~ /\A\d+\z/ ? args[:number].to_i : args[:number]
        r = @client.call('config.rollback', 'number' => n)
        how = r['changed'] ? 'it differs from the running configuration; config compare shows how' :
                             'it is the same as the running configuration'
        "Rollback #{r['rollback']} is the candidate now: #{how}.\n"
      end

      # ==================================================================
      # Neighbors. The layouts are this file's own, as the summary's
      # columns are; no vendor sample is behind them.

      # `show bgp neighbors [PEER]`: one block per neighbor, every field
      # `show.peers` answers, so nothing it knows is hidden. A PEER that
      # is not configured is refused with the ones that are.
      def neighbors(args, _words)
        rows = Array(@client.call('show.peers'))
        if args[:peer]
          rows = rows.select { |r| r['address'] == args[:peer] }
          raise Refused, no_peer(args[:peer]) if rows.empty?
        end
        return "No neighbors are configured.\n" if rows.empty?
        rows.collect { |r| neighbor(r) }.join("\n")
      end

      def no_peer(peer)
        "no neighbor #{peer.inspect} is configured; this bgp4rd has #{peers.join(', ')}"
      end

      HEAD = %w[address remote_as type state].freeze

      def neighbor(r)
        out = +format("BGP neighbor %s, remote AS %s, %s, %s\n", r['address'], r['remote_as'], r['type'], r['state'])
        rest = r.reject { |k, _| HEAD.include?(k) }
        width = rest.keys.collect(&:size).max.to_i
        rest.each { |k, v| out << format("  %-*s  %s\n", width, k, field(k, v)) }
        out
      end

      def field(key, value)
        return '-' if value.nil?
        return "#{value}s" if key == 'uptime'
        return value.collect { |c| capability(c) }.join(', ') if key == 'capabilities' && value.is_a?(Array)
        value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
      end

      def capability(c)
        return c.to_s unless c.is_a?(Hash)
        detail = (c['capability'] || {}).collect { |k, v| "#{k}=#{v}" }
        ([c['name'] || c['code']] + detail).join(' ')
      end

      # `show bgp neighbors PEER received-routes`, the Adj-RIB-In of one
      # peer, every page. `*>` marks the path that is the best.
      def received(args, _words)
        rows, = pages('show.adj_in', args[:peer])
        out = +"#{rows.size} path(s) received from #{args[:peer]}\n"
        out << route_table(rows) { |r| r['best'] ? '*>' : '* ' }
      end

      # `show bgp neighbors PEER advertised-routes`, the Adj-RIB-Out, and
      # beside it what was not sent and why, and what was sent by hand.
      def advertised(args, _words)
        rows, first = pages('show.adj_out', args[:peer])
        out = +"#{rows.size} path(s) advertised to #{args[:peer]}\n"
        out << route_table(rows) { '  ' }
        skipped = Array((first['skipped'] || {})['rows'])
        unless skipped.empty?
          out << "\nNot advertised:\n"
          skipped.each { |r| out << format("  %-20s %s\n", r['prefix'], r['reason']) }
        end
        hand = Array((first['hand'] || {})['rows'])
        unless hand.empty?
          out << "\nSent by hand, not in the Adj-RIB-Out:\n"
          hand.each { |r| out << format("  %-20s %-10s %s\n", r['prefix'], r['verb'], r['at']) }
        end
        out
      end

      # Every page of a per-peer view, and the first page, which carries
      # what is beside the rows. A peer that is not configured is the
      # daemon's to refuse.
      def pages(method, peer)
        rows, offset, first = [], 0, nil
        loop do
          page = @client.call(method, 'peer' => peer, 'offset' => offset)
          first ||= page
          rows.concat(Array(page['rows']))
          offset = page['next_offset'] or break
        end
        [rows, first]
      end

      ORIGIN = { 'igp' => 'i', 'egp' => 'e', 'incomplete' => '?' }.freeze

      def route_table(rows)
        return "\n" if rows.empty?
        line = "%-2s %-20s %-16s %8s %8s %s\n"
        out = +"\n"
        out << format(line, '', 'Network', 'Next Hop', 'Metric', 'LocPrf', 'Path')
        rows.each do |r|
          path = [r['as_path'], ORIGIN.fetch(r['origin'].to_s, r['origin'].to_s)].reject { |x| x.to_s.empty? }
          out << format(line, yield(r), r['prefix'], r['next_hop'], r['med'], r['local_pref'],
                        path.join(' ')).sub(/ +\n\z/, "\n")
        end
        out
      end

      # `clear bgp PEER soft in`, a ROUTE-REFRESH, RFC 2918: the session
      # stays up and PEER sends its routes again.
      def refresh(args, _words)
        r = @client.call('peer.refresh', 'peer' => args[:peer])
        format("Asked %s to send its routes again (ROUTE-REFRESH, AFI %s SAFI %s)\n", r['peer'], r['afi'], r['safi'])
      end

      # `disable bgp PEER` and `enable bgp PEER`, which are peer.stop and
      # peer.start.
      def disable(args, _words)
        r = @client.call('peer.stop', 'peer' => args[:peer])
        format("Disabled %s: was %s, now %s, and it stays down until enable bgp %s\n",
               r['peer'], r['was'], r['state'], r['peer'])
      end

      def enable(args, _words)
        r = @client.call('peer.start', 'peer' => args[:peer])
        format("Enabled %s: now %s%s\n", r['peer'], r['state'],
               r['connect'] == false ? ', and it is passive, so it comes back when the peer dials' : '')
      end

      # `show log`, the daemon's last log lines, oldest first.
      def log(_args, _words)
        Array(@client.call('show.log')['lines']).collect { |l| "#{l}\n" }.join
      end

      # `monitor events`: each event on one line, time, kind, peer and
      # message, until Ctrl-C. Keepalives and the first result line are
      # not printed; `events.subscribe` at the prompt prints them all.
      def monitor(_args, _words)
        @out.puts 'Watching events. Ctrl-C stops.'
        stream('events.subscribe', {}) do |line|
          e = line['event'] or next
          [e['time'], e['kind'], e['peer'], e['message']].compact.join(' ')
        end
      end

      # `clear bgp PEER`, which resets one session. The line it prints is
      # this file's own, as the summary's columns are.
      def clear(args, _words)
        r = @client.call('peer.clear', 'peer' => args[:peer])
        format("Cleared %s: was %s, now %s\n", r['peer'], r['was'], r['state'])
      end

    end

  end
end
