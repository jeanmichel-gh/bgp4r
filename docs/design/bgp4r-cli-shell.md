# bgp4r-cli: an interactive prompt

Status: approved (#319). Step 1 is built: bgp/daemon/shell.rb.

## The problem

Today every operator command is one quoted argument, and every method
takes its parameters as JSON in single quotes:

```
cli -c 'show bgp 10.0.0.0/8'
cli -c 'clear bgp 10.0.10.1'
cli peer.stop '{"peer":"10.0.10.1"}'
```

A person at a lab node types the same few commands again and again. The
quotes and the JSON are what a script needs, not what a person needs.
And `bgp4r-cli` with no argument prints the usage and exits 1.

## What we want

```
root@r1:/app# cli
r1> show bgp 10.0.0.0/8
r1> clear bgp 10.0.10.1
r1> sh b s
r1> show bgp | match 10.30
r1> exit
root@r1:/app#
```

No quotes. Line editing and history. Tab and `?` say what comes next.

## Where the shape comes from

ospfv2 already has this: `ospf-cli` with no argument opens a prompt
(`lib/ospfv2/command_line/shell.rb`). Its `Shell#execute(line)` returns
the text and never prints, so `-c`, the prompt and the tests share one
path. It uses `reline` from Ruby's standard library, and reads plain
lines when standard input is not a terminal. bgp4r-cli should feel the
same, so a person moving between an ospfd node and a bgp4rd node in one
lab types the same way.

This is a second shell with the same shape, not a shared one. The two
repositories do not depend on each other, and the command words differ.

## The proposal

### 1. Starting it

| Typed | Does |
|---|---|
| `cli` on a terminal | opens the prompt |
| `cli` with standard input not a terminal | unchanged: the usage, status 1 (see question 1) |
| `cli -c 'show bgp'` | unchanged |
| `cli show bgp 10.0.0.0/8` | new: the words without quotes, same as `-c` |
| `cli show.peers` | unchanged: a word with a dot is a method |
| `cli -h` | unchanged |

The prompt is the hostname, `r1>`, as ospf-cli's is. `--style` given at
start applies to every `show bgp` in the session.

The rule that tells a command from a method on the shell's command line:
**the first word holds a dot, it is a method; otherwise it is a command.**
No method name today is a command word, and no command word has a dot.

### 2. One grammar for `-c`, the bare words and the prompt

`COMMANDS` becomes a small grammar table: each entry is the words, the
argument it takes (PEER, PREFIX, or none), the method it calls, and one
line of help. `-c`, the bare words and the prompt all go through one
`Shell#execute(line)` that returns text. The renderers in `cli.rb`
(`summary`, `fib`, `link_state`, `cleared`) move behind it unchanged.

Words may be shortened to any unique prefix: `sh b s` is
`show bgp summary`. An ambiguous prefix is refused with the choices.

### 3. Help and completion at the prompt

Help works at every level, and `?` and `help` mean the same thing:

```
r1> ?                    the command groups: show, clear, config, monitor, ...
r1> help                 the same
r1> show ?               what may follow show, one help line each
r1> show help            the same
r1> config ?             the config commands
r1> config help          the same
r1> clear ?              the clear commands
r1> clear help           the same
```

For example:

```
r1> clear ?
  bgp PEER             reset one session
  bgp PEER soft in     ask PEER to send its routes again (ROUTE-REFRESH)
r1> clear
```

- After `?` the line is put back for editing, without the `?`, as
  ospf-cli does. After `help` it is not, since `help` is a word typed
  in full.
- `help` is help only where the grammar expects a keyword. Where it
  expects an argument (PEER, PREFIX, a config value), `help` is that
  argument, and `?` is the way to ask.
- `?` and `help` work with `-c` and the bare words too:
  `cli show ?` and `cli -c 'config help'` print the same list.
- Tab completes a word. For PEER it offers the configured neighbors,
  read from `show.peers` once per Tab. PREFIX is not completed.
- `exit`, `quit` and Ctrl-D leave.
- History is kept for the session, in memory only.

### 4. More commands, for what today needs JSON

The commands a person types most that today need the method form and
JSON. Each one is a single method call with a fixed parameter, so the
grammar stays a table and not a parser:

| Command | Method |
|---|---|
| `show bgp neighbors` | `show.peers` |
| `show bgp neighbors PEER received-routes` | `show.adj_in` |
| `show bgp neighbors PEER advertised-routes` | `show.adj_out` |
| `show bgp PREFIX detail` | `show.rib`, every path and why each lost |
| `show log` | `show.log` |
| `clear bgp PEER soft in` | `peer.refresh` |
| `disable bgp PEER` | `peer.stop` |
| `enable bgp PEER` | `peer.start` |
| `monitor events` | `events.subscribe`, until Ctrl-C, back to the prompt |

The column layout for the new tables is this file's own, as
`show bgp summary`'s is today. Where no layout is chosen yet, the
command prints the method's JSON, indented. The words above are a first
list for the owner to change.

Originate, withdraw, specimen, fault and replay stay in the method form.
They take several parameters, and a grammar for them is a separate
decision.

### 4a. The `config` commands

The candidate configuration, without JSON. Each is one existing
`config.*` method. The set and delete lines are the ones
`bgp/daemon/config.rb` already reads, so the shell passes them through
and the daemon checks them:

| Command | Method |
|---|---|
| `config show` | `show.configuration`, format set |
| `config show candidate` | the same, `candidate` true |
| `config set PATH... VALUE` | `config.load`, the line `set PATH... VALUE` |
| `config delete PATH...` | `config.load`, the line `delete PATH...` |
| `config compare` | `config.compare` |
| `config check` | `config.commit`, `check` true |
| `config commit [comment TEXT]` | `config.commit` |
| `config discard` | `config.discard` |
| `config history` | `config.history` |
| `config rollback N` | `config.rollback`, `number` N |

```
r1> config set neighbors 10.0.10.1 hold_time 60
r1> config compare
r1> config check
r1> config commit comment hold time 60
```

This is one command group, not a mode. ospf-cli has a `configure` mode
with its own prompt; a group works the same from `-c` and from the
prompt, and needs no state in the shell. A mode can come later as a
second step if it is wanted. `show configuration` and
`show configuration candidate` stay as they are.

Tab after `config set` and `config delete` completes nothing in step 1.
Completing configuration paths needs the daemon's key list, which is a
later step.

### 5. Methods without JSON

At the prompt and on the command line, a method takes `key=value` words
as well as JSON:

```
r1> show.rib prefix=10.0.0.0/8
r1> peer.stop peer=10.0.10.1
cli show.rib prefix=10.0.0.0/8 --pretty
```

A value that reads as an integer, `true` or `false` becomes that; any
other value is a string. A value that needs a list or an object still
takes JSON. At the prompt, method results are printed indented.

### 6. Pipes

Output filters, after a `|`, as ospf-cli has them and every router
does:

| Pipe | Keeps |
|---|---|
| `\| match REGEX` (`include`) | the lines that match |
| `\| except REGEX` (`exclude`) | the lines that do not |
| `\| count` | the number of lines |
| `\| last N` | the last N lines |

They work on `-c` too: `cli -c 'show bgp | match 10.30'`.

## What does not change

- Every form that works today answers the same, byte for byte. The
  existing `cli_test.rb` and `cli_doc_test.rb` stay as they are and pass.
- `bgp4r-cli` still loads the socket client and JSON only. `reline` is
  required only when the prompt opens on a terminal. It is in Ruby's
  standard library, so `logger` stays the only runtime gem.
- The daemon and its API are untouched. Every command is an existing
  method.

## Files

- `bgp/daemon/shell.rb`: the grammar table, `Shell#execute`,
  completion, pipes, the prompt loop.
- `bgp/daemon/cli.rb`: option parsing; hands lines to the shell.
- `test/unit/daemon/shell_test.rb`: each command against the fake
  client, abbreviations, `?`, completion, pipes, `key=value`, and the
  piped-input loop.
- `docs/bgp4r-cli.md`: a section on the prompt; the doc test keeps
  every command listed.
- `CLAUDE.md` and `README.rdoc`: a line each.

## Order of work

One pull request per step, each usable on its own:

1. The prompt, bare words, abbreviations, and `?` and `help` at every
   level, over today's commands (sections 1 to 3).
2. The `config` commands (section 4a).
3. `key=value` for methods (section 5).
4. Pipes (section 6).
5. The new show, clear, enable and disable commands (section 4), once
   the owner has settled the words.

## Open questions for the owner

1. Bare `cli` with piped input: read lines, as ospf-cli does, or keep
   printing the usage and exiting 1? **Settled in step 1: it keeps the
   usage.** Reading lines would change what `cli </dev/null` answers,
   which "What does not change" rules out, and `cli_test.rb` holds it.
   `-c` covers a script.
2. The words in section 4: IOS forms as above, or Junos forms too
   (`show bgp neighbor`), as ospf-cli takes both?
3. Should history persist across sessions in `~/.bgp4r_history`? The
   container's home goes away with it. **Step 1 keeps it in memory
   only.**
