# Building objects: the three ways in, and getting the same object back

Every class in bgp4r can be built three ways, and most accept a fourth:

| From | Example |
|---|---|
| **field values** | `Origin.new(2)`, `Aggregator.new('10.0.0.1', 100)` |
| **a hash** | `Aggregator.new(:address => '10.0.0.1', :asn => 100)` |
| **its wire bytes** | `Origin.new(['40010102'].pack('H*'))` |
| **another instance** | `Aggregator.new(other)`, which re-parses `other.encode` |

All of them have to produce the same object, and `encode` is the measure of
that: same octets, same object. This document is about how the dispatch
works and where it goes wrong, because an object that comes back slightly
different costs far more time to diagnose than it should.

Read this with `to-hash-round-trips.md`, which is the inventory of which
hash forms read back today. This one is the mechanism; that one is the
record.

## How `initialize` dispatches

There is no shared base constructor. Each class decides for itself, with
the same branch order nearly everywhere:

```ruby
def initialize(*args)
  @flags, @type = OPTIONAL_TRANSITIVE, AGGREGATOR
  if args[0].is_a?(String) and args[0].is_packed?   # 1. wire bytes
    parse(*args)
  elsif args.size == 2 and
    args[0].is_a?(String) and args[1].is_a?(Integer) # 2. field values
    @ip_address = IPAddr.create(args[0])
    self.asn = args[1]
  elsif args[0].is_a?(self.class)                    # 3. another instance
    parse(args[0].encode, *args[1..-1])
  elsif args[0].is_a?(Hash)                          # 4. a hash
    @ip_address = IPAddr.create(args[0][:address])
    self.asn = args[0][:asn]
  else
    raise ArgumentError, "invalid argument, #{args.inspect}"
  end
end
```

That is `Aggregator` verbatim. Four things about the shape are worth
knowing before you add a branch to one of these.

**Wire bytes are tested first, and the test is the mark, not the
content.** See the next section; it is the single biggest source of
wasted time here.

**An instance of the class is re-parsed through `encode`**, not copied
field by field. So copy construction is only as good as the round trip
through the wire form, which is the one path every class gets right.

**The `else` raises.** A class whose hash branch does not fire does not
quietly build an empty object; it raises `ArgumentError`. That is the
good case. The bad case is a hash whose keys are read by a branch that
fires but reads the wrong ones, which builds a different object and says
nothing.

**`initialize` sets instance variables, and nothing else.** This is the
whole of the contract and worth saying plainly, because it answers most
questions about what a hash has to carry. A hash is an argument to the
constructor. What has to come back is the instance state. If a field
lives in an instance variable and no key sets it, that field cannot
survive a hash build, however reasonable the hash looks.

## The mark is the only thing that says "wire bytes"

A binary String is recognised by `is_packed?`, which reads an instance
variable set by `is_packed`. `bgp/common.rb` patches `Array#pack` so that
every `pack` result carries the mark:

```ruby
['40010102'].pack('H*').is_packed?   # => true
"\x40\x01\x01\x02".is_packed?        # => nil
```

`packed?` is an alias of `is_packed?`, and both are in the tree: 64 uses
of `is_packed?` and one of `packed?`, in `origin.rb`. Grep for both.

So octets built by `pack` just work, and octets from anywhere else, a
literal, a file, a socket read, an `unpack`/`slice` result, do not. An
unmarked String skips the wire branch and falls through to the field
value branches, and what happens next is the class's business:

```ruby
BGP::Origin.new("\x40\x01\x01\x02")
# ArgumentError: invalid argument, String (@)

BGP::Prefix.new("\x18\xc0\x00\x02")
# IPAddr::InvalidAddressError: invalid address:
#   from ipaddr.rb:692:in `in6_addr'
```

Neither message mentions the mark. The second one names `IPAddr` and
points into the standard library, which is a long way from the actual
mistake. **When a build fails somewhere improbable, check
`arg.is_packed?` first.** `str.is_packed` marks a String in place and
returns it, which is the fix.

## Building from a hash

Three things to know.

**The hash a class reads is not always the hash it writes.** `new` reads
the **bare** hash a test writes, `Aggregator.new(:address => ..., :asn =>
...)`, while `to_hash` answers the **wrapped** form, `{:aggregator =>
{...}}`, because `Path_attribute#to_hash` merges one key per attribute
and `Extended_communities` does the same for its list. Both halves work.
For 38 of the 97 classes measured, the route that rebuilds the object is
the owning attribute and not the class itself, and that is by design
rather than a defect. `to-hash-round-trips.md` has the history and the
row for each class, and `CLAUDE.md` says not to add a wrapped-form
branch without a reason beyond symmetry.

**A path attribute hash is keyed by attribute, through a registry.**
`Attr.register(ORIGIN, Origin, :origin)` sits under each attribute class
and gives it its hash keys; `Attr.by_key(:origin)` finds the
registration and its builder, which is `klass.new(value)` unless the
registration passed a block. So `Path_attribute.new(:origin => 2)` does
not know about `Origin` at all. A key with no registration raises
`ArgumentError, "#{key} not implemented"`.

**An unusual field gets an extra key, and only when it is unusual.** This
is the library's answer to fields that cannot live in the natural hash
shape, and it means an ordinary object's hash never changes:

| Key | Holds | Set when |
|---|---|---|
| `:tail` | octets after the last item that could not be read | parsing kept some |
| `:bits` | all 48 bits of a typed extended community value | a bit outside the defined fields arrived set |
| `:duplicates` | the occurrences of an attribute type after the first | a type repeats in one `Path_attribute` |

`Attr::TAIL_KEY` and `Path_attribute::DUP_KEY` name two of them in one
place. The rule each time is the same: no tail, no key; no odd bit, no
key; no repeat, no key. An object with nothing unusual hashes exactly as
it always did, so nothing that reads these hashes has to change.

## Building from field values

Constructors do not validate, and that is deliberate: this library exists
to put octets on the wire that no RFC allows, so a real router can be
watched handling them. Any value, any length, any combination.

The one thing a constructor may refuse is an input it cannot represent at
all, such as an Integer too wide for its field, because the alternative is
silently sending a different value. It must never refuse a combination
that is merely wrong by the RFC. Where a constructor does refuse, the
octet level routes stay open and must keep working: wire bytes,
`Attr::Raw`, and the `BGP::Fault` helpers.

## Checking that an object really comes back

Build it, encode it, build it again from each form, compare the octets:

```ruby
pa = BGP::Path_attribute.new(wire)      # from the wire
assert_equal(pa.encode, BGP::Path_attribute.new(pa.to_hash).encode)
```

Two places have to agree, and both are enforced:

* **the class's own test file**, which is where a reader looks. Exercise
  every field the object carries. An assertion that misses a field passes
  for the wrong reason, and three recipes did exactly that while the
  inventory was being written.
* **`test/unit/to_hash_catalog.rb`**, which is what makes the guarantee
  hold across the library. `to_hash_round_trip_test.rb` measures every
  entry against its declared verdict, so breaking a working round trip
  fails the suite and so does closing a gap without striking the record.

Where a field only arrives by parsing, parse. `Label_stack.new(100, 101)`
never sets the Rsrv bits its hash drops, so a recipe built that way
proves nothing about them.

## When an object does not come back, look here first

In the order that has actually paid off:

1. **Is the String marked?** `is_packed?`. See above. The error will not
   tell you.
2. **Does any key set that field?** If the field only ever arrives by
   parsing, no hash carries it and no hash can rebuild it. That is the
   shape of every lossy row in the inventory: a field that entered the
   object after its hash shape was settled.
3. **Which hash is it?** Bare or wrapped. A class whose `new` takes the
   bare form will not read its own `to_hash`, and that is often correct
   rather than broken.
4. **Does the value need the same translation the Symbol branch does?**
   `Origin#to_hash` answers `:incomplete`, and the hash branch assigned it
   raw, which left a Symbol in `@origin` and made `encode` raise in `pack`.
   A hash branch that skips a setter other branches use is a common bug.
5. **Does a merge collapse two of something?** One key per type cannot
   hold two attributes of a type, which silently kept the last. Two
   unknown attributes have the same problem and solve it with a list.
6. **Is it `const_defined?` reaching a parent's class?** `const_defined?`
   searches ancestors unless passed `false`, which once made
   `Capability::Unknown` resolve to the parameter level class, with a
   different hash and a different constructor. Three tests failed and not
   one of them named a constant.
