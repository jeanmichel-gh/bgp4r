# CLAUDE.md

Guide for AI agents working on bgp4r. Read this before changing anything.

## What this is

bgp4r is a pure Ruby library to build, parse and speak BGP-4 (RFC 4271 and many extensions). It is used to script BGP peers for testing and research. No external gem dependencies at runtime.

## Layout

```
bgp4r.rb                 entry point, requires everything
bgp/common.rb            shared helpers (IPAddr extensions, hex dumps)
bgp/iana.rb              IANA constants (AFI, SAFI, attribute codes)
bgp/messages/            OPEN, UPDATE, KEEPALIVE, NOTIFICATION, ROUTE-REFRESH, CAPABILITY
bgp/path_attributes/     one file per path attribute (origin, as_path, communities, mp_reach...)
bgp/nlris/               prefix encodings (inet, labeled, VPN, RD, mapped IPv4)
bgp/optional_parameters/ OPEN capabilities (4-byte AS, add-path, graceful restart...)
bgp/orfs/                outbound route filtering
bgp/neighbor/            the BGP finite state machine and TCP session (neighbor.rb)
bgp/misc/                extras (live_feed.rb, a client for an old public BGP feed)
examples/                runnable scripts
test/unit/               unit tests, mirroring bgp/
test/functional/         tests that open real TCP sessions
test/helpers/            a small test BGP server
```

## Running tests

Ruby 3.x works. Tests use test-unit. The load path is the repo root, so always pass `-I.`.

All unit tests:
```
ruby -I. -e 'Dir["test/unit/**/*test.rb"].sort.each { |f| require "./#{f}" }'
```

One file:
```
ruby -I. test/unit/path_attributes/as_path_test.rb
```

Functional test over loopback (port 3456):
```
ruby -I. test/functional/add_path_test.rb
```

Do not run `test/functional/live_feed_test.rb`. It connects to a public feed that no longer answers and hangs forever.

Known gap: `rake test` only matches `test/unit/*/*test.rb`, so it skips `test/unit/common_test.rb` and `test/unit/iana_test.rb`. Use the command above.

Baseline on 2026-10-24: 238 tests, 1223 assertions, all passing. Line coverage of `bgp/` about 89%.

## Conventions

* Every class can be built three ways: from field values, from a hash, and from its wire bytes (a binary String). Keep all three working when you change a class.
* `encode` returns wire bytes. `to_hash` returns a hash that round trips through `new`. `to_s` returns the human readable form.
* Tests check round trips: build, encode, parse back, compare. Use real hex captures from the RFCs or from Wireshark when possible.
* One test file per source file, same name with `_test.rb`, in the matching folder under `test/unit/`.
* Two space indent. Match the style of the file you edit.
* Keep the library free of runtime gem dependencies.

## Rules for agents

* Work on a branch named `claude/<short-topic>`. Never push to master.
* One topic per pull request. Small diffs.
* Run the full unit suite before opening a PR. All tests must pass.
* New behavior needs a test. Bug fixes need a test that failed before the fix.
* Cite the RFC section in a comment when you implement or fix wire format logic.
* Do not delete or weaken existing tests to make a change pass.
* If you find a bug you are not fixing, list it in the PR description.

## Known issues to work on

* `bgp/misc/live_feed.rb`: no connect timeout, the parser thread busy loops with no sleep when nothing matches, and the shared buffer is touched by two threads without a lock.
* `Neighbor#start` with `:waitfor` loops forever if the state is never reached. Needs a timeout.
* Several bare `rescue` blocks swallow errors (`nlris/prefix.rb`, `nlris/labeled.rb`).
* Debug output left in library code: `p "JME: ..."` in `messages/update.rb`, and `puts` calls in `message.rb`, `path_attribute.rb`, `extended_community.rb`, `rd.rb`. Should go through `Log` or raise.
* Ruby warnings under `-w`: `IPAddr#netmask` redefined in `common.rb`, ambiguous `*` in `cluster_list.rb` and `extended_communities.rb`.
* Lowest coverage: `nlris/mapped_ipv4.rb`, `common.rb`, `orfs/prefix_orf.rb`, `neighbor/neighbor.rb`, `messages/update.rb`.
* `.travis.yml` is dead. Replace with a GitHub Actions workflow.
