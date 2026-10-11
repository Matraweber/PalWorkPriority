local M = PROBE_DRIVER
local passed = 0
local function reject(fn)
    assert(not pcall(fn), 'expected fail-closed rejection')
    passed = passed + 1
end
local function good(hex, status, error)
    local bytes = hex:gsub('..', function(p) return string.char(tonumber(p,16)) end)
    return {status or 0, error or 0, 123, 1000, 1001, M.checksum(bytes), 10000000}
end
local function native(hex) return table.unpack(good(hex)) end
for _,hex in ipairs({'', 'a', 'GG', '00\0ff', string.rep('00',262145)}) do
    reject(function() M.invoke(native,hex) end)
end
reject(function() M.invoke(function() return 0 end,'00') end)
for _,change in ipairs({{1,9},{2,1},{3,0},{4,-1},{5,999},{6,0},{7,0},{3,'123'}}) do
    reject(function()
        M.invoke(function(hex)
            local r=good(hex); r[change[1]]=change[2]; return table.unpack(r)
        end,'00')
    end)
end
for _,status in ipairs({1,2,3,4,5}) do
    local calls=0
    reject(function()
        M.verify_pair(function(hex)
            calls=calls+1; return table.unpack(good(hex,status,87))
        end,'00','01',function() return '\0' end)
    end)
    assert(calls==1, 'failed/uncertain publication must not cause second call')
end
local calls=0
reject(function()
    M.verify_pair(function(hex) calls=calls+1; return table.unpack(good(hex)) end,
        '00','01',function() return 'wrong' end)
end)
assert(calls==1, 'readback failure must stop before conflict attempt')
reject(function() M.verify_pair(native,'00','00',function() return '\0' end) end)
calls=0
local a,b=M.verify_pair(function(hex)
    calls=calls+1
    return table.unpack(good(hex,calls==1 and 0 or 2,calls==1 and 0 or 183))
end,'00','01',function() return '\0' end)
assert(calls==2 and a[1]==0 and b[1]==2)
passed=passed+1
return passed
