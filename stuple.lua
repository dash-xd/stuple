local floor = math.floor
local select = select
local type = type
local format = string.format
local setmetatable = setmetatable

local M = {}

local EMPTY = 0
local LEAF = 1
local BRANCH = 2

local KIND = 1
local SIZE = 2
local HEIGHT = 3
local HASH = 4
local POWER = 5
local VALUE = 6
local LEFT = 7
local RIGHT = 8

-- Products remain below 2^53, so arithmetic is exact on LuaJIT's doubles.
local MOD = 16777213
local BASE = 65599

local function hash_bytes(s, h)
    h = h or 216613

    for i = 1, #s do
        h = (h * BASE + s:byte(i)) % MOD
    end

    return h
end

local function hash_value(v)
    local tv = type(v)

    if tv == "nil" then
        return 1
    elseif tv == "boolean" then
        return v and 2 or 3
    elseif tv == "number" then
        return hash_bytes("n:" .. format("%.17g", v), 5)
    elseif tv == "string" then
        return hash_bytes("s:" .. #v .. ":" .. v, 7)
    end

    error("unsupported tuple value type: " .. tv, 3)
end

local empty

empty = function(op)
    if op == KIND then
        return EMPTY
    elseif op == SIZE then
        return 0
    elseif op == HEIGHT then
        return 0
    elseif op == HASH then
        return 0
    elseif op == POWER then
        return 1
    end

    return nil
end

-- Intern primitive leaves. Nested weak tables preserve typed equality without
-- stringifying values or trusting hashes as identities.
local leaf_pools = {
    ["boolean"] = setmetatable({}, { __mode = "v" }),
    ["number"] = setmetatable({}, { __mode = "v" }),
    ["string"] = setmetatable({}, { __mode = "v" }),
}
local nil_leaf

local function raw_leaf(value)
    local h = hash_value(value)

    return function(op)
        if op == KIND then
            return LEAF
        elseif op == SIZE then
            return 1
        elseif op == HEIGHT then
            return 1
        elseif op == HASH then
            return h
        elseif op == POWER then
            return BASE
        elseif op == VALUE then
            return value
        end

        return nil
    end
end

local function leaf(value)
    local tv = type(value)

    if tv == "nil" then
        if nil_leaf == nil then
            nil_leaf = raw_leaf(nil)
        end
        return nil_leaf
    end

    if tv == "number" and value ~= value then
        return raw_leaf(value)
    end

    local pool = leaf_pools[tv]
    if pool == nil then
        return raw_leaf(value)
    end

    local existing = pool[value]
    if existing ~= nil then
        return existing
    end

    local node = raw_leaf(value)
    pool[value] = node
    return node
end

local function raw_branch(left, right)
    local size = left(SIZE) + right(SIZE)
    local lh = left(HEIGHT)
    local rh = right(HEIGHT)
    local height = (lh > rh and lh or rh) + 1
    local cached_hash
    local cached_power

    return function(op)
        if op == KIND then
            return BRANCH
        elseif op == SIZE then
            return size
        elseif op == HEIGHT then
            return height
        elseif op == LEFT then
            return left
        elseif op == RIGHT then
            return right
        elseif op == POWER then
            local p = cached_power
            if p == nil then
                p = (left(POWER) * right(POWER)) % MOD
                cached_power = p
            end
            return p
        elseif op == HASH then
            local h = cached_hash
            if h == nil then
                h = (left(HASH) * right(POWER) + right(HASH)) % MOD
                cached_hash = h
            end
            return h
        end

        return nil
    end
end

-- left -> weak map(right -> branch). Identity interning lets path-copying
-- converge back to an existing DAG when an edit is semantically rolled back.
local branch_pool = setmetatable({}, { __mode = "k" })

local function branch(left, right)
    if left == empty then
        return right
    elseif right == empty then
        return left
    end

    local by_right = branch_pool[left]
    if by_right == nil then
        by_right = setmetatable({}, { __mode = "kv" })
        branch_pool[left] = by_right
    end

    local existing = by_right[right]
    if existing ~= nil then
        return existing
    end

    local node = raw_branch(left, right)
    by_right[right] = node
    return node
end

local function build_n(n, continuation, ...)
    if n == 0 then
        return continuation(empty, ...)
    end

    if n == 1 then
        local value = ...
        return continuation(leaf(value), select(2, ...))
    end

    local left_n = floor(n / 2)
    local right_n = n - left_n

    return build_n(left_n, function(left, ...)
        return build_n(right_n, function(right, ...)
            return continuation(branch(left, right), ...)
        end, ...)
    end, ...)
end

local function done(root, ...)
    assert(select("#", ...) == 0, "tuple builder left unconsumed values")
    return root
end

function M.tuple(...)
    return build_n(select("#", ...), done, ...)
end

M.empty = empty

function M.arity(t)
    return t(SIZE)
end

function M.hash(t)
    return t(HASH)
end

function M.get(t, i)
    local n = t(SIZE)

    if i < 1 or i > n then
        return nil
    end

    if t(KIND) == LEAF then
        return t(VALUE)
    end

    local left = t(LEFT)
    local left_n = left(SIZE)

    if i <= left_n then
        return M.get(left, i)
    end

    return M.get(t(RIGHT), i - left_n)
end

function M.head(t)
    return M.get(t, 1)
end

local function emit(t, tail)
    local kind = t(KIND)

    if kind == EMPTY then
        return tail()
    elseif kind == LEAF then
        return t(VALUE), tail()
    end

    local left = t(LEFT)
    local right = t(RIGHT)

    return emit(left, function()
        return emit(right, tail)
    end)
end

local function emit_done()
    return
end

function M.values(t)
    return emit(t, emit_done)
end

local function rebalance(left, right)
    local lh = left(HEIGHT)
    local rh = right(HEIGHT)

    if lh > rh + 1 then
        local ll = left(LEFT)
        local lr = left(RIGHT)

        if ll(HEIGHT) >= lr(HEIGHT) then
            return branch(ll, branch(lr, right))
        end

        local lrl = lr(LEFT)
        local lrr = lr(RIGHT)
        return branch(branch(ll, lrl), branch(lrr, right))
    elseif rh > lh + 1 then
        local rl = right(LEFT)
        local rr = right(RIGHT)

        if rr(HEIGHT) >= rl(HEIGHT) then
            return branch(branch(left, rl), rr)
        end

        local rll = rl(LEFT)
        local rlr = rl(RIGHT)
        return branch(branch(left, rll), branch(rlr, rr))
    end

    return branch(left, right)
end

function M.join(a, b)
    if a == empty then
        return b
    elseif b == empty then
        return a
    end

    local ah = a(HEIGHT)
    local bh = b(HEIGHT)

    if ah > bh + 1 then
        return rebalance(a(LEFT), M.join(a(RIGHT), b))
    elseif bh > ah + 1 then
        return rebalance(M.join(a, b(LEFT)), b(RIGHT))
    end

    return branch(a, b)
end

function M.split(t, n)
    local size = t(SIZE)

    if n <= 0 then
        return empty, t
    elseif n >= size then
        return t, empty
    end

    local left = t(LEFT)
    local right = t(RIGHT)
    local left_n = left(SIZE)

    if n == left_n then
        return left, right
    elseif n < left_n then
        local a, b = M.split(left, n)
        return a, M.join(b, right)
    end

    local a, b = M.split(right, n - left_n)
    return M.join(left, a), b
end

function M.take(t, n)
    local left = M.split(t, n)
    return left
end

function M.drop(t, n)
    local _, right = M.split(t, n)
    return right
end

function M.tail(t)
    return M.drop(t, 1)
end

function M.replace(t, i, value)
    local n = t(SIZE)
    assert(i >= 1 and i <= n, "tuple index out of range")

    if t(KIND) == LEAF then
        return leaf(value)
    end

    local left = t(LEFT)
    local right = t(RIGHT)
    local left_n = left(SIZE)

    if i <= left_n then
        return branch(M.replace(left, i, value), right)
    end

    return branch(left, M.replace(right, i - left_n, value))
end

function M.append(t, value)
    return M.join(t, leaf(value))
end

function M.prepend(value, t)
    return M.join(leaf(value), t)
end

local function value_equal(a, b)
    return a == b
end

-- Exact verification after the shape-independent hash gate. This implementation
-- remains allocation-free with respect to Lua tables; it intentionally favors
-- clarity over the future O(n) zipper optimization.
local function equal_exact(a, b, n)
    if n == 0 or a == b then
        return true
    elseif n == 1 then
        return value_equal(M.get(a, 1), M.get(b, 1))
    end

    local k = floor(n / 2)
    local al, ar = M.split(a, k)
    local bl, br = M.split(b, k)

    return equal_exact(al, bl, k) and equal_exact(ar, br, n - k)
end

function M.equal(a, b)
    if a == b then
        return true
    end

    local n = a(SIZE)
    if n ~= b(SIZE) then
        return false
    end

    if a(HASH) ~= b(HASH) then
        return false
    end

    return equal_exact(a, b, n)
end

local function first_leaf(t)
    if t(KIND) == LEAF then
        return t
    elseif t(KIND) == EMPTY then
        return nil
    end

    return first_leaf(t(LEFT))
end

function M.primary_hash(t)
    local first = first_leaf(t)
    return first and first(HASH) or nil
end

M._kind = function(t) return t(KIND) end
M._height = function(t) return t(HEIGHT) end
M._leaf = leaf
M._branch = branch
M._constants = {
    EMPTY = EMPTY,
    LEAF = LEAF,
    BRANCH = BRANCH,
}

return M
