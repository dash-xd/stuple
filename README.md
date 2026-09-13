# stuple

`stuple` is an experimental persistent tuple for Lua built around the language's native multiple-value semantics.

Construction is vararg-native: a continuation-passing parser consumes `...` directly into a balanced immutable tree. The tuple itself has no Lua table backing store and does not use `table.pack` or `table.unpack`.

## Properties

- balanced persistent tuple tree
- `O(log n)` positional lookup and replacement
- structural sharing across edits, splits, and joins
- weak hash-consing of leaves and branches
- shape-independent memoized sequence hashes
- native multiple-value emission with recursive continuations
- immutable `Space` index with MVCC snapshots and logical WAL records
- no runtime dependencies
- Lua 5.1-5.4 and LuaJIT 2.1 CI

Lua tables are intentionally reserved for things they are good at: weak interning pools and external indexes. Tuple payloads and persistent tree nodes are closures.

## Tuple API

```lua
local stuple = require("stuple")

local t = stuple.tuple(123, "alice", nil, 42)

assert(stuple.arity(t) == 4)
assert(stuple.head(t) == 123)
assert(stuple.get(t, 2) == "alice")

local id, name, optional, age = stuple.values(t)

local changed = stuple.replace(t, 2, "bob")
local prefix, suffix = stuple.split(changed, 2)
local restored = stuple.join(prefix, suffix)

assert(stuple.equal(changed, restored))
```

`values()` returns Lua multiple values recursively; it does not call `table.unpack`.

## Space / MVCC

`stuple.space` is the first database-oriented layer. Its primary index is an immutable AVL tree. A committed `Space` value is therefore also a snapshot: retaining an older value retains the old index root while later transactions path-copy only changed nodes.

```lua
local stuple = require("stuple")
local space = require("stuple.space")

local s0 = space.new()
local tx = space.begin(s0)

tx = space.tx_put(tx, stuple.tuple(1, "alice"))
tx = space.tx_put(tx, stuple.tuple(2, "bob"))

local s1, wal = space.commit(tx)

assert(space.get(s0, 1) == nil)
assert(stuple.get(space.get(s1, 1), 2) == "alice")
assert(space.wal_count(wal) == 2)
```

The first tuple field is the primary key. The current persistent index accepts homogeneous numeric or string keys.

WAL entries currently describe logical mutations in memory:

- operation (`insert`, `replace`, `delete`)
- target version
- primary key
- old tuple hash
- new tuple hash
- old/new tuple roots

The WAL layer is deliberately not yet a disk format. A durable format needs canonical scalar encoding, checksums, framing, fsync policy, replay rules, and recovery tests before it should be called write-ahead logging in the storage-engine sense.

## Design

For sequences `A` and `B`, hashes compose as:

```text
H(A || B) = H(A) * BASE^|B| + H(B) mod MOD
```

This makes a tuple hash dependent on logical field order rather than tree topology. Splitting and rejoining a tuple can rebalance the tree without changing its content hash.

Construction uses CPS to solve Lua's lack of a prefix-select primitive:

```text
build_n(n, continuation, ...)
    -> continuation(subtree, remaining...)
```

The left subtree consumes its exact prefix and forwards untouched remaining multiple values directly to the right subtree builder.

## Current boundaries

This is an experiment, not a production database engine. In particular:

- the rolling hash is a fast content fingerprint, not a cryptographic digest
- number hashing currently uses canonical-looking text formatting rather than a specified binary representation
- exact equality verification is not yet the optimal linear zipper walk
- `Space` has a single primary index and no secondary indexes yet
- WAL records are logical in-memory records, not durable files
- there is no concurrency control beyond immutable snapshots

Those constraints are intentional so persistence semantics can be specified before adding I/O.

## Test

```sh
lua tests/test_stuple.lua
lua tests/test_space.lua
```

## Benchmark

```sh
lua bench/tuple.lua 1000000
```
