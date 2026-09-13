local stuple = require("stuple")

local n = tonumber(arg and arg[1]) or 100000
local t = stuple.tuple(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16)

local start = os.clock()
local sum = 0
for i = 1, n do
    sum = sum + stuple.get(t, (i - 1) % 16 + 1)
end
local elapsed = os.clock() - start

print(string.format("get: %d ops in %.6fs (sum=%d)", n, elapsed, sum))
