local stuple = require("stuple")

local M = {}

local EMPTY = 0
local NODE = 1

local KIND = 1
local HEIGHT = 2
local KEY = 3
local VALUE = 4
local LEFT = 5
local RIGHT = 6
local COUNT = 7

local empty
empty = function(op)
    if op == KIND then
        return EMPTY
    elseif op == HEIGHT or op == COUNT then
        return 0
    end
    return nil
end

local function height(t)
    return t(HEIGHT)
end

local function count(t)
    return t(COUNT)
end

local function raw_node(key, value, left, right)
    local lh = height(left)
    local rh = height(right)
    local h = (lh > rh and lh or rh) + 1
    local n = count(left) + count(right) + 1

    return function(op)
        if op == KIND then
            return NODE
        elseif op == HEIGHT then
            return h
        elseif op == KEY then
            return key
        elseif op == VALUE then
            return value
        elseif op == LEFT then
            return left
        elseif op == RIGHT then
            return right
        elseif op == COUNT then
            return n
        end
        return nil
    end
end

local function node(key, value, left, right)
    return raw_node(key, value, left or empty, right or empty)
end

local function compare(a, b)
    local ta = type(a)
    local tb = type(b)

    assert((ta == "number" or ta == "string") and ta == tb,
        "space keys must be numbers or strings of the same type")

    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

local function rotate_left(root)
    local pivot = root(RIGHT)
    local moved = pivot(LEFT)
    local new_left = node(root(KEY), root(VALUE), root(LEFT), moved)
    return node(pivot(KEY), pivot(VALUE), new_left, pivot(RIGHT))
end

local function rotate_right(root)
    local pivot = root(LEFT)
    local moved = pivot(RIGHT)
    local new_right = node(root(KEY), root(VALUE), moved, root(RIGHT))
    return node(pivot(KEY), pivot(VALUE), pivot(LEFT), new_right)
end

local function balance(root)
    local left = root(LEFT)
    local right = root(RIGHT)
    local delta = height(left) - height(right)

    if delta > 1 then
        if height(left(RIGHT)) > height(left(LEFT)) then
            left = rotate_left(left)
            root = node(root(KEY), root(VALUE), left, right)
        end
        return rotate_right(root)
    elseif delta < -1 then
        if height(right(LEFT)) > height(right(RIGHT)) then
            right = rotate_right(right)
            root = node(root(KEY), root(VALUE), left, right)
        end
        return rotate_left(root)
    end

    return root
end

local function map_get(root, key)
    if root == empty then
        return nil
    end

    local c = compare(key, root(KEY))
    if c == 0 then
        return root(VALUE)
    elseif c < 0 then
        return map_get(root(LEFT), key)
    end
    return map_get(root(RIGHT), key)
end

local function map_put(root, key, value)
    if root == empty then
        return node(key, value), nil
    end

    local c = compare(key, root(KEY))
    if c == 0 then
        local old = root(VALUE)
        if old == value then
            return root, old
        end
        return node(key, value, root(LEFT), root(RIGHT)), old
    elseif c < 0 then
        local next_left, old = map_put(root(LEFT), key, value)
        return balance(node(root(KEY), root(VALUE), next_left, root(RIGHT))), old
    end

    local next_right, old = map_put(root(RIGHT), key, value)
    return balance(node(root(KEY), root(VALUE), root(LEFT), next_right)), old
end

local function detach_min(root)
    if root(LEFT) == empty then
        return root, root(RIGHT)
    end

    local min, next_left = detach_min(root(LEFT))
    return min, balance(node(root(KEY), root(VALUE), next_left, root(RIGHT)))
end

local function map_delete(root, key)
    if root == empty then
        return root, nil
    end

    local c = compare(key, root(KEY))
    if c < 0 then
        local next_left, old = map_delete(root(LEFT), key)
        if old == nil then
            return root, nil
        end
        return balance(node(root(KEY), root(VALUE), next_left, root(RIGHT))), old
    elseif c > 0 then
        local next_right, old = map_delete(root(RIGHT), key)
        if old == nil then
            return root, nil
        end
        return balance(node(root(KEY), root(VALUE), root(LEFT), next_right)), old
    end

    local old = root(VALUE)
    local left = root(LEFT)
    local right = root(RIGHT)

    if left == empty then
        return right, old
    elseif right == empty then
        return left, old
    end

    local successor, next_right = detach_min(right)
    return balance(node(successor(KEY), successor(VALUE), left, next_right)), old
end

local function state(root, version)
    return function(op)
        if op == "root" then
            return root
        elseif op == "version" then
            return version
        elseif op == "count" then
            return count(root)
        end
        return nil
    end
end

function M.new()
    return state(empty, 0)
end

function M.version(space)
    return space("version")
end

function M.count(space)
    return space("count")
end

function M.get(space, key)
    return map_get(space("root"), key)
end

local function wal_record(op, version, key, old_tuple, new_tuple)
    return function(field)
        if field == "op" then
            return op
        elseif field == "version" then
            return version
        elseif field == "key" then
            return key
        elseif field == "old_hash" then
            return old_tuple and stuple.hash(old_tuple) or nil
        elseif field == "new_hash" then
            return new_tuple and stuple.hash(new_tuple) or nil
        elseif field == "old" then
            return old_tuple
        elseif field == "new" then
            return new_tuple
        end
        return nil
    end
end

local wal_empty
wal_empty = function(op)
    if op == "count" then
        return 0
    end
    return nil
end

local function wal_cons(record, tail)
    local n = tail("count") + 1
    return function(op)
        if op == "head" then
            return record
        elseif op == "tail" then
            return tail
        elseif op == "count" then
            return n
        end
        return nil
    end
end

function M.wal_count(wal)
    return wal("count")
end

function M.wal_head(wal)
    return wal("head")
end

function M.wal_tail(wal)
    return wal("tail")
end

local function tx_state(base, root, wal)
    return function(op)
        if op == "base" then
            return base
        elseif op == "root" then
            return root
        elseif op == "wal" then
            return wal
        end
        return nil
    end
end

function M.begin(space)
    return tx_state(space, space("root"), wal_empty)
end

function M.tx_get(tx, key)
    return map_get(tx("root"), key)
end

function M.tx_put(tx, tuple)
    local key = stuple.head(tuple)
    assert(key ~= nil, "primary key cannot be nil")

    local root, old = map_put(tx("root"), key, tuple)
    if old == tuple then
        return tx
    end

    local version = M.version(tx("base")) + 1
    local record = wal_record(old and "replace" or "insert", version, key, old, tuple)

    return tx_state(tx("base"), root, wal_cons(record, tx("wal")))
end

function M.tx_delete(tx, key)
    local root, old = map_delete(tx("root"), key)
    if old == nil then
        return tx
    end

    local version = M.version(tx("base")) + 1
    local record = wal_record("delete", version, key, old, nil)
    return tx_state(tx("base"), root, wal_cons(record, tx("wal")))
end

function M.commit(tx)
    local base = tx("base")
    local wal = tx("wal")
    if wal("count") == 0 then
        return base, wal
    end

    local next_space = state(tx("root"), M.version(base) + 1)
    return next_space, wal
end

function M.put(space, tuple)
    return M.commit(M.tx_put(M.begin(space), tuple))
end

function M.delete(space, key)
    return M.commit(M.tx_delete(M.begin(space), key))
end

return M
