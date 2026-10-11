-- Offline companion; no load/install/ExecuteAsync or automatic invocation.
local M = {}
function M.checksum(bytes)
    local h = 5381
    for i=1,#bytes do h = (h*33 + bytes:byte(i)) % 4294967296 end
    return h
end
local function decode(hex)
    assert(type(hex)=='string' and #hex>0 and #hex<=524288 and #hex%2==0
        and not hex:find('[^0-9a-f]'), 'invalid scalar hex')
    return (hex:gsub('..', function(pair) return string.char(tonumber(pair,16)) end))
end
function M.invoke(native, hex)
    local expected = M.checksum(decode(hex))
    local r = table.pack(native(hex, #hex))
    assert(r.n==7, 'uncertain native result shape; do not retry')
    for i=1,7 do assert(math.type(r[i])=='integer', 'uncertain native result type; do not retry') end
    assert(r[1]>=0 and r[1]<=5 and r[2]>=0 and r[2]<=4294967295, 'invalid status/error')
    assert(r[3]>0 and r[3]<=4294967295 and r[4]>=0 and r[5]>=r[4] and r[7]>0, 'invalid QPC/thread metadata')
    assert(r[6]==expected, 'attempted-payload checksum mismatch')
    assert((r[1]==0 and r[2]==0) or (r[1]~=0 and r[2]~=0), 'inconsistent status/error')
    return r
end
-- CLI/offline test convenience only: reader must be an external Python bridge.
-- Live callers invoke one operation, log completion, then independently read
-- the fixed target from Python. No game-thread disk readback in this module.
function M.verify_pair(native, first, second, reader)
    local expected, other = decode(first), decode(second)
    assert(expected~=other, 'conflict payload must differ')
    assert(reader, 'external readback required')
    local published = M.invoke(native, first)
    assert(published[1]==0, 'first publication not confirmed; stop, do not retry')
    assert(reader()==expected, 'exact disk readback mismatch')
    local conflict = M.invoke(native, second) -- deliberate different request, not retry
    assert(conflict[1]==2, 'expected conflict; stop')
    assert(reader()==expected, 'conflict changed target')
    return published, conflict
end
return M
