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

module BGP
  module Daemon

    # The configuration as **set lines**, one per leaf: the text
    # `show.configuration`, `config.replace`, `config.load` and
    # `config.compare` speak.
    #
    #   set router_id 10.255.0.1
    #   set as 65000
    #   set neighbors 10.0.10.1 as 65010
    #   set neighbors 10.0.10.1 capabilities add_path 3 1 1
    #   set originate 0 prefixes 10.255.0.0/24
    #   set export {}
    #
    # **bgp4rd's configuration is YAML and this is a second rendering of
    # it, which is a decision with a cost, so here is the mechanism.**
    # routescope's Config pane reaches a candidate through calls read in
    # `Drivers::Ospfd` at routescope `7eabde1`: `config.replace` takes
    # `lines:`, `config.compare` **answers an Array of lines**, and
    # `show.configuration` is asked with `format: 'set'`. Answering YAML
    # text instead would satisfy the types, since the driver only
    # normalizes and diffs text, and it was rejected for three reasons,
    # none of them taste:
    #
    # * **A compare line has to mean something on its own.** The pane
    #   lists `config.compare`'s lines as the change list. `set neighbors
    #   10.0.10.1 hold_time 60` names its whole leaf path, so one line read
    #   alone says what changed. The YAML diff of the same edit is
    #   `- hold_time: 30` and `+ hold_time: 60`, which says nothing about
    #   which neighbor, and a person reading a list of those cannot tell
    #   two neighbors apart.
    # * **`config.replace` takes lines, and YAML's lines are not
    #   independent.** A set line carries its own path, so the order of the
    #   lines does not matter and a line is complete in itself. A YAML line
    #   means what its indentation and the lines above it make it mean, so a
    #   caller that reflowed the file, or sent the lines in another order,
    #   gets a different tree or a parse error.
    # * **A commit has to classify what changed**, because some keys take
    #   effect live, some by bouncing a session and some not at all until
    #   bgp4rd restarts. That classification is per leaf path, and
    #   `changed_paths` yields leaf paths; off a YAML diff it would mean
    #   re-walking both trees to find out which keys the hunks touched.
    #
    # The fourth argument is weaker in fact and is recorded because it is
    # the one a reader expects: a driver masks secrets by regexp on the
    # text it is given, and `Drivers::Ospfd::SECRETS` is
    # `/\b(key|simple-password)(\s+)(...)/`, which wants whitespace after
    # the key name. That matches `set ... key hunter2` and does **not**
    # match YAML's `key: hunter2`, because the colon is where the `\s+`
    # has to be. So a driver copying that regexp would leak a YAML
    # secret. **It leaks nothing today**, measured rather than assumed:
    # no key of bgp4rd's configuration is a secret, so nothing is masked
    # in either rendering. It matters the day one is added.
    #
    # ## The grammar
    #
    # `set PATH... VALUE` and `delete PATH...`, whitespace separated, with
    # a value quoted when it holds whitespace or is empty. A `#` comment
    # and a blank line are ignored. The last token of a `set` is the value
    # and everything before it is the path; a `delete` is a path with no
    # value and removes whatever is under it.
    #
    # **`{}` as a value means the mapping exists and says nothing more.**
    # `export: {}` is a documented configuration, a transit router with no
    # policy, and a neighbor or an `originate` block can be empty too, so
    # there has to be a line for them. It cannot be a bare path, because
    # `set neighbors 10.0.10.1` and `set communities 65000:1` are the same
    # shape and the second is an ordinary leaf: a bare path would make
    # every plain list ambiguous. One token says it instead.
    #
    # Four kinds of list, because YAML has one and set lines need a key
    # per element:
    #
    # * **Keyed**, `neighbors`, whose elements are objects with a natural
    #   name: the `address`. So `set neighbors 10.0.10.1 as 65010`, and
    #   reading it back puts the address in the element as well, which is
    #   what makes the rendering lossless.
    # * **Ordinal**, `announce` and `originate`, whose elements have no
    #   natural name at all: `set originate 0 med 10`. **The cost is real
    #   and is the ordinal's**: swapping two blocks reads as a change to
    #   every key of both, where a router keying them by a name would show
    #   none. There is nothing in the block to key on, since a `generate`
    #   block has no prefix list, and inventing a name would be a key the
    #   YAML file does not have.
    # * **Argument**, `capabilities`, whose elements are a name and the
    #   arguments after it: `as4_byte` on its own, `{add_path: [3, 1, 1]}`
    #   with three. So the first token after `capabilities` is the name and
    #   the rest are its arguments, which is `Peer#add_capability`'s own
    #   reading of the YAML.
    # * **Plain**, everything else, such as `communities`, `clients` and
    #   `prefixes`: one line per element, in order.
    #
    # ## Three things to know about reading lines back
    #
    # **A value's type is inferred from its token**, so `true` and `false`
    # are booleans, digits are an Integer and everything else is a String.
    # A YAML String that looks like a number therefore comes back a
    # number. Nothing here minds: every reader of these keys coerces what
    # it gets (`Integer(afi)` in `Speaker#export_options`, `to_s` in
    # `fib_options`), and `compare` works on the lines rather than on the
    # trees, so the difference cannot show as a change that is not one.
    #
    # **A nil value renders as no line.** `description:` with nothing
    # after it is nil, and absent and nil are the same thing to every
    # reader of this configuration, so there is no line shape that would
    # tell them apart and none is invented.
    #
    # **The first `set` to a path in one call replaces, and the rest
    # collect.** That is what makes one grammar serve both a plain list,
    # whose elements are one line each, and a scalar being changed by
    # `config.load` on top of a configuration that already has one. Within
    # a call the lines describe the whole value of the path they name; a
    # later call starts again.
    module Config

      # A line, or a tree, this cannot read. It is the only thing raised
      # here, so a caller has one class to rescue.
      class Error < StandardError ; end

      # The value that means "this mapping is here and holds nothing",
      # and the one that means it of a list. Both assert that the key is
      # there; emptying a key that holds something is `delete`.
      #
      # **The list one is not symmetry, it is a behaviour difference**,
      # measured in `bgp/rib/export.rb` rather than assumed. `clients:
      # []` and no `clients` key at all mean opposite things:
      # `Export#initialize` leaves `@clients` nil when it is given none,
      # and `clients?` then answers **true** for every internal peer,
      # which is RFC 4456 section 6's single cluster. Given `[]` it builds
      # an empty Hash and `clients?` answers **false** for every peer. So
      # a renderer that dropped an empty list would turn a reflector that
      # reflects to everyone into one that reflects to nobody, which is a
      # wrong answer of exactly the kind a commit must not give.
      EMPTY      = '{}'.freeze
      EMPTY_LIST = '[]'.freeze

      # A list whose elements are objects, keyed by one of their own
      # fields rather than by their position.
      KEYED_LISTS = { 'neighbors' => 'address' }.freeze

      # A list whose elements are objects with nothing to key them by, so
      # the key is the ordinal. See the grammar above for what that costs.
      ORDINAL_LISTS = %w[announce originate].freeze

      # A list whose elements are a name and its arguments.
      ARGUMENT_LISTS = %w[capabilities].freeze

      # The configuration as set lines, one per leaf, in the order the
      # Hash holds its keys.
      def self.to_set(config)
        raise Error, 'a configuration is a mapping' unless config.is_a?(Hash)
        lines = []
        render([], config, lines)
        lines
      end

      # The configuration as the YAML a person edits, which is what
      # `show.configuration` answers unless asked for `set`: the file is
      # what they have in front of them.
      def self.to_yaml_text(config)
        require 'yaml'
        YAML.dump(stringify(config))
      end

      # The tree `lines` describe, which is `to_set` run backwards.
      def self.from_set(lines)
        apply({}, lines)
      end

      # `lines` applied **on top of** `config`, which is what
      # `config.load` does: a `set` gives the path it names the value it
      # carries and a `delete` removes it. `config` is not touched; the
      # new tree is returned, so a caller whose lines raise still has the
      # candidate it had.
      def self.apply(config, lines)
        tree = deep_copy(config)
        seen = {}
        Array(lines).each_with_index do |raw, i|
          line = raw.to_s.sub(/#.*\z/, '').strip
          next if line.empty?
          tokens = split(line, i)
          verb = tokens.shift
          case verb
          when 'set'
            raise Error, "line #{i + 1}: set needs a path and a value: #{line.inspect}" if tokens.size < 2
            value = tokens.pop
            set(tree, tokens, value, i, seen)
          when 'delete'
            raise Error, "line #{i + 1}: delete needs a path: #{line.inspect}" if tokens.empty?
            unset(tree, tokens)
          else
            raise Error, "line #{i + 1}: #{verb.inspect} is not set or delete: #{line.inspect}"
          end
        end
        tree
      end

      # What turns `running` into `candidate`, as set and delete lines a
      # person reads and `config.load` can take back.
      #
      # **It compares the rendered lines and not the two trees**, which is
      # what makes the answer canonical: a key whose YAML value is the
      # Integer 1 and whose set line says `1` cannot differ from the same
      # key read back from that line, so a commit of an unedited
      # configuration shows no change.
      #
      # Grouped by leaf path, so one changed scalar is **one** `set` line
      # with the new value rather than a delete and a set. A path whose
      # list of values changed at all is a `delete` of the path and then
      # one `set` per value it now has: that is more lines than the one
      # element that moved, and it is what makes the answer exact when it
      # is loaded back, since a reader cannot otherwise tell a list that
      # gained an element from one that was reordered.
      def self.compare(running, candidate)
        before, after = group(to_set(running)), group(to_set(candidate))
        lines = []
        roots = []   # subtrees gone whole, so their leaves are not listed
        paths(before, after).each do |path|
          old, new = before[path] || [], after[path] || []
          next if old == new
          if new.empty?
            root = gone_root(path, after)
            next if roots.include?(root)
            roots << root
            lines << (['delete'] + root).join(' ')
          elsif old.size == 1 && new.size == 1
            lines << (['set'] + path + [new.first]).join(' ')
          else
            lines << (['delete'] + path).join(' ') unless old.empty?
            new.each { |v| lines << (['set'] + path + [v]).join(' ') }
          end
        end
        lines
      end

      # The shortest prefix of `path` that has gone away entirely, which
      # is what a `delete` has to name.
      #
      # **Deleting the leaves is not the same thing and the difference
      # changes behaviour.** A neighbor whose only key was `as` compares
      # as `delete neighbors 10.0.11.1 as`, and loading that back leaves
      # `{"address" => "10.0.11.1"}` behind rather than removing the
      # neighbor. Worse one level up: an `export` block taken out of the
      # file compares as a delete per leaf, and loading those back leaves
      # `export => {}`, which `Speaker#rib?` reads as **router mode on**
      # where the absent key means off. So a subtree that is gone is named
      # once, at its root.
      def self.gone_root(path, after)
        (1..path.size).each do |n|
          prefix = path[0, n]
          return prefix if after.keys.none? { |p| p[0, n] == prefix }
        end
        path
      end

      # The leaf paths that differ, as token Arrays, which is what a
      # commit classifies. A path is reported once however many of its
      # values moved.
      #
      # **Read off the groups and not off `compare`'s lines**, which was
      # the first draft and was wrong: a `delete` line is a path with no
      # value and a `set` line a path with one, so re-parsing them means
      # knowing which verb each was, and the groups already hold the
      # answer without the round trip.
      def self.changed_paths(running, candidate)
        before, after = group(to_set(running)), group(to_set(candidate))
        paths(before, after).select { |p| (before[p] || []) != (after[p] || []) }
      end

      # A deep copy, so a candidate and the running configuration cannot
      # share a Hash and an edit to one reach the other.
      def self.deep_copy(value)
        case value
        when Hash   then value.to_h { |k, v| [k, deep_copy(v)] }
        when Array  then value.map { |v| deep_copy(v) }
        when String then value.dup
        else value
        end
      end

      # Every key as a String, for YAML a person reads.
      def self.stringify(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_s, stringify(v)] }
        when Array then value.map { |v| stringify(v) }
        else value
        end
      end

      def self.paths(before, after)
        (before.keys + after.keys).uniq
      end

      # ---- rendering ----

      def self.render(path, value, lines)
        case value
        when Hash
          if value.empty?
            # The top level mapping being empty is a configuration with
            # nothing in it, which renders as no lines rather than as a
            # line naming no path.
            lines << (['set'] + path + [EMPTY]).join(' ') unless path.empty?
          else
            value.each { |k, v| render(path + [k.to_s], v, lines) }
          end
        when Array
          if value.empty?
            lines << (['set'] + path + [EMPTY_LIST]).join(' ')
          else
            render_list(path, value, lines)
          end
        when nil   then nil   # absent and nil are the same thing: no line
        else lines << (['set'] + path + [token(value)]).join(' ')
        end
      end

      def self.render_list(path, list, lines)
        name = path.last
        if (field = KEYED_LISTS[name])
          list.each do |element|
            raise Error, "#{name} takes mappings, not #{element.class}" unless element.is_a?(Hash)
            key = element[field] || element[field.to_sym]
            raise Error, "a #{name} entry has no #{field}" if key.nil?
            render(path + [token(key)], element.reject { |k, _v| k.to_s == field }, lines)
          end
        elsif ORDINAL_LISTS.include?(name)
          list.each_with_index do |element, i|
            raise Error, "#{name} takes mappings, not #{element.class}" unless element.is_a?(Hash)
            render(path + [i.to_s], element, lines)
          end
        elsif ARGUMENT_LISTS.include?(name)
          list.each { |element| lines << (['set'] + path + argument(name, element)).join(' ') }
        else
          list.each do |element|
            # A plain list is one line per element, so an element that is
            # itself a mapping or a list has nowhere to put its own
            # boundary: rendering it would run its keys together with the
            # next element's and reading the lines back would give another
            # tree. Refusing says so, which is this library's rule about
            # when to refuse at all: it cannot produce the text, rather
            # than disapproving of it. A new key shaped that way wants a
            # row in KEYED_LISTS or ORDINAL_LISTS.
            if element.is_a?(Hash) || element.is_a?(Array)
              raise Error,
                    "#{name} is a list of values, so it cannot hold a #{element.class}: " \
                    'name it in KEYED_LISTS or ORDINAL_LISTS'
            end
            render(path, element, lines)
          end
        end
      end

      # One `capabilities` element: a name on its own, or a one key
      # mapping of a name and the arguments that follow it.
      def self.argument(name, element)
        case element
        when Hash
          unless element.size == 1
            raise Error, "a #{name} entry is one name and its arguments, not #{element.keys.size} names"
          end
          key, args = element.first
          [token(key)] + Array(args).map { |a| token(a) }
        else [token(element)]
        end
      end

      # ---- reading ----

      # One `set`. `path` is the tokens before the value, `raw` the value
      # token, and `seen` the paths this call has already written, which
      # is what makes the first line to a path replace and the rest
      # collect.
      def self.set(tree, path, raw, index, seen)
        name = path.first
        if path.size == 1
          empty_or_leaf(tree, name, path, raw, index, seen)
          return tree
        end
        if KEYED_LISTS.key?(name)
          set_keyed(tree, name, path, raw, index, seen)
        elsif ORDINAL_LISTS.include?(name)
          set_ordinal(tree, name, path, raw, index, seen)
        elsif ARGUMENT_LISTS.include?(name)
          raise Error, "line #{index + 1}: #{name} is a list of its own and takes no mapping under it"
        else
          inner = (tree[name] ||= {})
          raise Error, "line #{index + 1}: #{name} holds a value, not a mapping" unless inner.is_a?(Hash)
          set_under(inner, path[1..], raw, index, path, seen)
        end
        tree
      end

      # Under a keyed list: `neighbors 10.0.10.1 ...`.
      def self.set_keyed(tree, name, path, raw, index, seen)
        field = KEYED_LISTS[name]
        list  = (tree[name] ||= [])
        raise Error, "line #{index + 1}: #{name} is a list" unless list.is_a?(Array)
        key = path[1]
        element = list.find { |e| e.is_a?(Hash) && e[field].to_s == key }
        unless element
          element = { field => scalar(key) }
          list << element
        end
        set_under(element, path[2..], raw, index, path, seen)
      end

      # Under an ordinal list: `originate 0 ...`.
      def self.set_ordinal(tree, name, path, raw, index, seen)
        list = (tree[name] ||= [])
        raise Error, "line #{index + 1}: #{name} is a list" unless list.is_a?(Array)
        i = path[1]
        raise Error, "line #{index + 1}: #{name} is keyed by a number, not #{i.inspect}" unless i.match?(/\A\d+\z/)
        i = i.to_i
        # A sparse Array is not something YAML can hold and `compact`
        # would renumber the blocks that are there, so a gap is filled
        # with empty blocks and every ordinal keeps meaning what its line
        # said.
        (list.size..i).each { |n| list[n] = {} }
        set_under(list[i], path[2..], raw, index, path, seen)
      end

      # The rest of a path inside one mapping. `full` is the whole path
      # the line named, which is what `seen` is keyed by.
      def self.set_under(element, path, raw, index, full, seen)
        # `set neighbors 10.0.10.1 {}` and `set originate 0 {}`: the
        # element is here and says nothing more. It was created above.
        return element if path.empty?
        name = path.first
        # The path from the root down to `name`. **It is not `full`**,
        # which is the whole path the line named: for `set neighbors A
        # capabilities add_path 3 1` the list lives at `neighbors A
        # capabilities` and the arguments after it are part of one
        # element. Keying `seen` by `full` instead made every capability
        # line its own path, so each cleared the list and a neighbor kept
        # only its last capability.
        at = full[0, full.size - path.size + 1]
        if ARGUMENT_LISTS.include?(name)
          list = (element[name] ||= [])
          raise Error, "line #{index + 1}: #{name} is a list" unless list.is_a?(Array)
          list.clear unless seen_before?(seen, at)
          args = path[1..].map { |t| scalar(t) } + [scalar(raw)]
          # A name on its own is a String; a name and one argument is
          # `{role: customer}` and a name and several is `{add_path: [3,
          # 1, 1]}`, which is the YAML `Peer#add_capability` reads. It
          # takes either, since it runs `Array(args)` over what it finds,
          # so the single argument form is the readable one rather than
          # the necessary one.
          list << case args.size
                  when 1 then args.first
                  when 2 then { args.first.to_s => args[1] }
                  else { args.first.to_s => args[1..] }
                  end
          return element
        end
        if path.size == 1
          empty_or_leaf(element, name, at, raw, index, seen)
        else
          inner = (element[name] ||= {})
          raise Error, "line #{index + 1}: #{name} holds a value, not a mapping" unless inner.is_a?(Hash)
          set_under(inner, path[1..], raw, index, full, seen)
        end
        element
      end

      # `{}`, `[]` or an ordinary leaf, in the one place both callers
      # reach. `at` is the path to the key, which is what `seen` is keyed
      # by.
      #
      # The two empty tokens **assert that the key is there** rather than
      # emptying one that holds something: the renderer writes them only
      # for a key that is already empty, and `compare` takes a key away
      # with `delete`, so there is no line a reader has to read as
      # "clear this".
      def self.empty_or_leaf(holder, name, at, raw, index, seen)
        case raw
        when EMPTY
          held = (holder[name] ||= {})
          raise Error, "line #{index + 1}: #{name} holds a value, not a mapping" unless held.is_a?(Hash)
        when EMPTY_LIST
          held = (holder[name] ||= [])
          raise Error, "line #{index + 1}: #{name} holds a value, not a list" unless held.is_a?(Array)
        else
          leaf(holder, name, scalar(raw), at, seen)
        end
        holder
      end

      # A leaf. The first line of this call to name the path replaces
      # whatever was there; the ones after it collect, which is what makes
      # a plain list a list. See the note on the module.
      def self.leaf(holder, name, value, full, seen)
        if seen_before?(seen, full)
          held = holder[name]
          holder[name] = held.is_a?(Array) ? held + [value] : [held, value]
        else
          holder[name] = value
        end
      end

      # True when this call has already written `path`, and records it
      # either way.
      def self.seen_before?(seen, path)
        key = path.join("\u0000")
        seen.key?(key) ? true : (seen[key] = true ; false)
      end

      # `delete PATH`: the leaf, the element of a keyed or ordinal list,
      # or the whole subtree the path names.
      def self.unset(tree, path)
        name = path.first
        if path.size == 1
          tree.delete(name)
          return tree
        end
        if KEYED_LISTS.key?(name) && path.size == 2
          field = KEYED_LISTS[name]
          list = tree[name]
          list.reject! { |e| e.is_a?(Hash) && e[field].to_s == path[1] } if list.is_a?(Array)
          return tree
        end
        if ORDINAL_LISTS.include?(name) && path.size == 2
          list = tree[name]
          list.delete_at(path[1].to_i) if list.is_a?(Array) && path[1].match?(/\A\d+\z/)
          return tree
        end
        holder = locate(tree, path[0..-2])
        case holder
        when Hash  then delete_key(holder, path.last)
        when Array then delete_element(holder, path.last)
        end
        tree
      end

      # A key of a mapping, by its token. **Both the token and the value
      # it stands for**, because a YAML key need not be a String: the
      # `next_hops` mapping is keyed by the AFI, so `export: {next_hops:
      # {1 => ...}}` holds the Integer 1 where `delete export next_hops
      # 1` arrives with the String. Deleting only the String missed it,
      # and `compare` emits exactly that line, so a compare loaded back
      # left the next hop behind.
      def self.delete_key(holder, token)
        holder.delete(token)
        holder.delete(scalar(token))
      end

      # One element of an argument list, by its name: `delete neighbors
      # 10.0.10.1 capabilities add_path` takes that capability away and
      # leaves the others.
      #
      # **A bare name and a name with arguments are both matched**, which
      # is the half that was missing. `Array#delete` finds `'as4_byte'`
      # and does not find `{'add_path' => [3, 1, 1]}`, so a capability
      # with arguments could not be deleted at all; `compare` emits that
      # line, and the test meant to catch it passed **vacuously**, since
      # an edit that did nothing left nothing to compare.
      def self.delete_element(list, token)
        list.reject! do |e|
          e.is_a?(Hash) ? e.size == 1 && e.keys.first.to_s == token : e.to_s == token
        end
      end

      # The mapping a path names, or nil. Used by `delete` only: a `set`
      # creates what is missing and a `delete` must not.
      def self.locate(tree, path)
        path.inject(tree) do |node, name|
          case node
          when Hash  then node.key?(name) ? node[name] : node[scalar(name)]
          when Array then element_of(node, name)
          else nil
          end
        end
      end

      def self.element_of(list, name)
        field = KEYED_LISTS.values.find { |f| list.first.is_a?(Hash) && list.first.key?(f) }
        return list.find { |e| e.is_a?(Hash) && e[field].to_s == name } if field
        name.match?(/\A\d+\z/) ? list[name.to_i] : nil
      end

      # ---- tokens ----

      # One line's tokens. A value holding whitespace is written quoted,
      # so the tokenizer has to know about quotes; everything else is a
      # split on whitespace.
      def self.split(line, index)
        tokens = []
        s = line.to_s.strip
        until s.empty?
          if s.start_with?('"')
            m = s.match(/\A"((?:[^"\\]|\\.)*)"(?:\s+|\z)/) or
              raise Error, "line #{index + 1}: a quoted value is not closed: #{line.inspect}"
            tokens << m[1].gsub(/\\(.)/, '\1')
            s = m.post_match.lstrip
          else
            token, _, rest = s.partition(/\s+/)
            tokens << token
            s = rest.lstrip
          end
        end
        tokens
      end

      # A value as a token: quoted when a split could not give it back.
      def self.token(value)
        s = value.to_s
        return s unless s.empty? || s.match?(/[\s"]/)
        '"' + s.gsub(/([\\"])/) { "\\#{Regexp.last_match(1)}" } + '"'
      end

      # A token as the value it stands for. See the note on the module for
      # what inferring a type does and does not cost.
      def self.scalar(token)
        case token
        when 'true'  then true
        when 'false' then false
        when /\A-?\d+\z/ then token.to_i
        when /\A-?\d+\.\d+\z/ then token.to_f
        else token
        end
      end

      # The rendered lines as path => values, which is what `compare` and
      # `changed_paths` group by. The path is every token but the last.
      def self.group(lines)
        h = {}
        lines.each_with_index do |line, i|
          tokens = split(line, i)
          tokens.shift if %w[set delete].include?(tokens.first)
          if tokens.size <= 1
            h[tokens] ||= []
          else
            (h[tokens[0..-2]] ||= []) << tokens.last
          end
        end
        h
      end

    end

  end
end
