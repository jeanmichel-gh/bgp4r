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

require 'bgp/sim/guide'

module BGP

  # The parts of an irb prompt that do not depend on what is behind it:
  # loading irb, `verbs`, `guide`, `received`, `last`, `watch` and the
  # tap that puts every message a session reads into `received`.
  #
  #   class Console
  #     include BGP::Prompt
  #     VERBS = "..."
  #     def initialize(out)
  #       initialize_prompt(out)
  #     end
  #   end
  #
  # `BGP::Sim::Console` includes it, and the daemon's prompt will. **It
  # is outside bgp/sim/ on purpose**: a daemon that wants a prompt must
  # not load the injector to get one, so this file requires nothing but
  # the guide renderer, which is plain Ruby over docs/console.md. A test
  # loads it alone in a child process and checks that.
  #
  # **No method here is named after an irb command**, which wins over a
  # method of the same name. That is why the list is `verbs` and the
  # document is `guide`, and not `help`.
  #
  # A host class provides VERBS, the text `verbs` prints, and may
  # override `banner`, the line printed when the prompt opens.
  module Prompt

    # How many received messages `received` keeps.
    KEEP = 200

    # The message printed when irb cannot be loaded. Ruby 4.0 made irb
    # a bundled gem, so under Bundler it loads only when the Gemfile
    # names it, which is the trap CLAUDE.md records for `base64`.
    IRB_MISSING = 'irb cannot be loaded. Ruby 4.0 made it a bundled gem, ' \
                  "so under Bundler add gem 'irb' to the Gemfile, or run " \
                  'without bundle exec.'

    # The kinds `received` and `last` filter on, by the message's
    # class. :all is every kind, keepalives included.
    KINDS = %i[update keepalive notification open route_refresh malformed other].freeze

    # What a person usually wants: everything but keepalives, which
    # arrive every holdtime/3 seconds and push the rest out of view.
    DEFAULT_KINDS = (KINDS - %i[keepalive]).freeze

    # One message in, from one peer, at one time. `kind` is one of
    # KINDS, and `inspect` is the one line `to_s` prints, so a list of
    # these reads in irb the way `received` used to print it.
    Received = Struct.new(:at, :peer, :message) do
      def to_s
        format('%s %s %s', at.strftime('%H:%M:%S.%L'), peer, Prompt.describe(message))
      end
      alias_method :inspect, :to_s

      # irb prints a result through pp and not inspect, so both say it.
      def pretty_print(q) ; q.text(to_s) ; end

      def kind ; Prompt.kind(message) ; end
      def msg ; message ; end
    end

    # What `received` answers: an Array of Received, oldest first, that
    # irb prints one line per message. `messages` is the objects.
    class List < Array
      def messages ; collect(&:message) ; end

      # How many prefixes the UPDATEs in the list announce, and how many
      # they withdraw, in either field. What a generated feed is checked
      # against, since one UPDATE carries many.
      def prefixes ; sum { |r| Prompt.prefix_count(r.message) } ; end
      def withdrawn ; sum { |r| Prompt.withdrawn_count(r.message) } ; end

      def inspect
        empty? ? '(none)' : collect(&:to_s).join("\n")
      end
      alias_method :to_s, :inspect

      # irb prints a result through pp, which would otherwise show every
      # field of every message. One line each, as `received` printed.
      def pretty_print(q) ; q.text(inspect) ; end
    end

    # The observer on one Neighbor. A separate object, so an Observable
    # sees `update` and nothing else of the prompt.
    class Tap
      def initialize(prompt, address)
        @prompt, @address = prompt, address
      end

      def update(msg)
        @prompt.received_from(@address, msg)
      end
    end

    # Requires irb, or raises LoadError with IRB_MISSING.
    def self.load_irb
      require 'irb'
    rescue LoadError
      raise LoadError, IRB_MISSING
    end

    # Which of KINDS a message is. The ORF form of RFC 5291 is its own
    # class and not a Route_refresh, so it is named too.
    def self.kind(msg)
      case msg
      when BGP::Update then :update
      when BGP::Keepalive then :keepalive
      when BGP::Notification then :notification
      when BGP::Open then :open
      when BGP::Route_refresh, BGP::Orf_route_refresh then :route_refresh
      when Exception then :malformed
      else :other
      end
    end

    # The kinds and the count a call to `received` or `last` asked for,
    # in either order: `received 20`, `received :update`, `received
    # 5, :keepalive`, `received :all`. An unknown kind is refused with
    # the list, rather than matching nothing.
    def self.selection(args, count)
      kinds = []
      args.each do |a|
        case a
        when Integer then count = a
        when :all then kinds.concat(KINDS)
        when Symbol, String
          k = a.to_sym
          raise ArgumentError, "no kind #{a.inspect}; the kinds are #{(KINDS + [:all]).join(', ')}" unless KINDS.include?(k)
          kinds << k
        else raise ArgumentError, "#{a.inspect} is neither a count nor a kind"
        end
      end
      [kinds.empty? ? DEFAULT_KINDS : kinds.uniq, count]
    end

    # One line about a message, for `received` and `watch`.
    def self.describe(msg)
      case msg
      when BGP::Update
        format('Update, %d prefixes, %d withdrawn', prefix_count(msg), withdrawn_count(msg))
      when BGP::Message then msg.class.name.split('::').last
      when Exception then "malformed: #{msg.message}"
      else msg.to_s
      end
    end

    # How many prefixes one UPDATE carries, in either field: the RFC
    # 4271 section 4.3 NLRI, and the MP_REACH_NLRI of RFC 4760 section
    # 3, which is what a generated IPv6 range would use.
    def self.prefix_count(msg)
      return 0 unless msg.is_a?(BGP::Update)
      n = msg.nlri ? msg.nlri.size : 0
      pa = msg.path_attribute
      n += pa[:mp_reach].nlris.size if pa && pa.has?(BGP::Mp_reach)
      n
    end

    # How many prefixes one UPDATE withdraws, in either field, which
    # is what a withdrawal feed counts.
    def self.withdrawn_count(msg)
      return 0 unless msg.is_a?(BGP::Update)
      n = msg.withdrawn ? msg.withdrawn.size : 0
      pa = msg.path_attribute
      n += pa[:mp_unreach].nlris.size if pa && pa.has?(BGP::Mp_unreach)
      n
    end

    # So a host answers `Console.load_irb` and `Console.describe`, which
    # is how its callers already ask.
    module ClassMethods
      def load_irb ; Prompt.load_irb ; end
      def describe(msg) ; Prompt.describe(msg) ; end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    # The state the methods below share. A host calls it from its own
    # initialize, before anything can tap a session.
    def initialize_prompt(out = $stdout, keep = KEEP)
      @out, @keep = out, keep
      @received = []
      @lock = Mutex.new
      @watch = false
      @tapped = {}
    end

    # Opens irb on this object and returns when the person exits.
    def interact
      Prompt.load_irb
      @out.puts banner
      instance_eval { binding }.irb(show_code: false)
      nil
    end

    # The line printed when the prompt opens.
    def banner
      "'verbs' lists what to type, exit quits."
    end

    def verbs
      @out.print self.class::VERBS
      nil
    end

    # docs/console.md, rendered: the whole guide, or the section whose
    # number or heading matches key. Through a pager on a terminal.
    def guide(key = nil)
      g = Sim::Guide.new(File.read(Sim::Guide::PATH, :encoding => 'UTF-8'), terminal?)
      text = key.nil? ? g.to_s : g.section(key)
      text ||= "No section #{key.inspect}. The sections are:\n#{g.contents}"
      page(text)
      nil
    rescue Errno::ENOENT
      @out.puts "#{Sim::Guide::PATH} is not there; the guide ships with a checkout or the gem."
      nil
    end

    # The last messages in, as a List: an Array of Received, oldest
    # first, with keepalives left out unless asked for.
    #
    #   received                     the last 10, keepalives left out
    #   received 50, :all            the last 50 of anything
    #   received :update             the last 10 UPDATEs
    #   received :keepalive          only the keepalives
    #   received peer: '10.0.0.2'    from one peer
    #   received.last.message        the object, also .msg
    #   received(:update).messages   the objects
    def received(*args, peer: nil)
      kinds, count = Prompt.selection(args, 10)
      List.new(select_received(kinds, peer).last(count))
    end

    # The last message in, as an object, keepalives left out unless
    # asked for: `last`, `last :keepalive`, `last :all`, `last
    # peer: '10.0.0.2'`.
    def last(*args, peer: nil)
      kinds, = Prompt.selection(args, 1)
      r = select_received(kinds, peer).last
      r && r.message
    end

    def watch ; @watch = true ; end
    def quiet ; @watch = false ; true ; end
    def watching? ; @watch ; end

    # Called by a Tap, on the session's reader thread.
    def received_from(address, msg)
      r = Received.new(Time.now, address, msg)
      @lock.synchronize do
        @received << r
        @received.shift while @received.size > @keep
      end
      @out.puts r if @watch
    end

    private

    def select_received(kinds, peer)
      all = @lock.synchronize { @received.dup }
      all.select { |r| kinds.include?(r.kind) && (peer.nil? || r.peer == peer) }
    end

    # Puts a Tap on the Neighbor under a peer, once per Neighbor. A
    # Neighbor is a new object on every reconnect, so a host calls this
    # as each session comes up. Anything answering `neighbor` and
    # `address` will do, which is a Daemon::Speaker::Peer.
    def tap(peer)
      n = peer.neighbor
      return if n.nil?
      @lock.synchronize do
        return if @tapped.key?(n.object_id)
        @tapped[n.object_id] = true
      end
      n.add_observer(Tap.new(self, peer.address))
    end

    # True when the output is a person's terminal, which is when the
    # guide gets colour and a pager.
    def terminal?
      @out.respond_to?(:tty?) && @out.tty?
    end

    # Text through $PAGER, or less, on a terminal; printed otherwise, or
    # when no pager runs. `::IO`, since `IO` here is BGP::IO. LESS gets
    # F, R and X so a short section prints and returns, colour shows,
    # and the screen is not cleared.
    def page(text)
      return @out.print(text) unless terminal?
      env = { 'LESS' => ENV.fetch('LESS', 'FRX') }
      ::IO.popen(env, ENV.fetch('PAGER', 'less'), 'w') { |io| io.print(text) }
    rescue Errno::EPIPE
      nil # the person quit the pager before the end
    rescue Errno::ENOENT
      @out.print(text)
    end

  end

end
