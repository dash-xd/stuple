local stuple = require("stuple")

local function pack(...)
    return { n = select("#", ...), ... }
end

local function assert_values(t, ...)
    local got = pack(stuple.values(t))
    local want = pack(...)
    assert(got.n == want.n, "arity mismatch")
    for i = 1, want.n do
        assert(got[i] == want[i], "value mismatch at field " .. i)
    end
end

local empty = stuple.tuple()
assert(stuple.arity(empty) == 0)
assert(stuple.head(empty) == nil)

local t = stuple.tuple(123, "alice", nil, 42, true)
assert(stuple.arity(t) == 5)
assert(stuple.head(t) == 123)
assert(stuple.get(t, 2) == "alice")
assert(stuple.get(t, 3) == nil)
assert(stuple.get(t, 4) == 42)
assert(stuple.get(t, 99) == nil)
assert_values(t, 123, "alice", nil, 42, true)

local left, right = stuple.split(t, 2)
assert_values(left, 123, "alice")
assert_values(right, nil, 42, true)

local rejoined = stuple.join(left, right)
assert(stuple.hash(rejoined) == stuple.hash(t))
assert(stuple.equal(rejoined, t))

assert_values(stuple.take(t, 3), 123, "alice", nil)
assert_values(stuple.drop(t, 3), 42, true)
assert_values(stuple.tail(t), "alice", nil, 42, true)
assert_values(stuple.append(t, "x"), 123, "alice", nil, 42, true, "x")
assert_values(stuple.prepend("z", t), "z", 123, "alice", nil, 42, true)

local changed = stuple.replace(t, 2, "bob")
assert_values(changed, 123, "bob", nil, 42, true)
assert(not stuple.equal(changed, t))

local restored = stuple.replace(changed, 2, "alice")
assert(stuple.equal(restored, t))
assert(restored == t, "interning should restore structural identity")

local same = stuple.tuple(123, "alice", nil, 42, true)
assert(same == t, "canonical construction should hash-cons identical tuples")
assert(stuple.primary_hash(t) ~= nil)

local big = stuple.tuple(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)
for i = 1, 16 do
    assert(stuple.get(big, i) == i)
end

print("stuple core: ok")
