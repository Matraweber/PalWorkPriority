-- An upgrade from 0.4.1 must read every row 0.4.1 actually wrote.
-- 0.4.1's own store/caps/workdefs (tests/fixtures/v041, from the tag) write
-- the files through their real save(); rc1's modules then load them.
local fs = require('memory_fs')()
io.open, os.rename, os.remove = fs.open, fs.rename, fs.remove
local quiet = { debug=function() end, say=function() end, info=function() end,
    warn=function() end, error=function() end, count=function() end }
package.loaded.log = quiet

local function load_v041(name)
    local chunk = assert(loadfile(TEST_ROOT .. '/tests/fixtures/v041/' .. name .. '.lua'))
    return chunk()
end

-- 0.4.1 writes. Its caps needs its own workdefs while loading.
local rc1_workdefs = package.loaded.workdefs
package.loaded.workdefs = load_v041('workdefs')
local old_store, old_caps = load_v041('store'), load_v041('caps')
package.loaded.workdefs = rc1_workdefs

old_store.path, old_store.decided = 'priorities.txt', true
old_store.data = {
    ['00000000000000000000000000000001679D42C842B4D85AC496DCBF862D1565'] = { [4]=1, [5]=3, [7]=4 },
    ['000000000000000000000000000000017B48FA634B97CB3741993CB55760D2E8'] = { [3]=3, [7]=5, [5]=false },
    ['00000000000000000000000000000001285537874BDD300C89925BA094C4CDDF'] = { [7]=2, [12]=1, [13]=5 },
}
old_store.save()

old_caps.path, old_caps.decided = 'caps.txt', true
old_caps.data = {
    ['-758686034-1314655308-1294252187-537966059'] = { Mining = { Stone = 35000 }, Deforest = { Wood = 30000 } },
    ['*'] = { Mining = { Ore = 500 } },
}
old_caps.save()

local written_prio = assert(fs.files['priorities.txt'], '0.4.1 store wrote nothing')
local written_caps = assert(fs.files['caps.txt'], '0.4.1 caps wrote nothing')

-- What 0.4.1 really persisted, read back by 0.4.1 itself. Its X bug means the
-- X row is expected to be missing here; that loss happened under 0.4.1.
old_store.load('priorities.txt')
local persisted = old_store.data
assert(persisted['000000000000000000000000000000017B48FA634B97CB3741993CB55760D2E8'][5] == nil,
    'fixture no longer reproduces the 0.4.1 X loss; re-check the fixture')

-- rc1 reads the same bytes.
local store = require('store')
local n = store.load('priorities.txt')
assert(store.state == 'saved', 'rc1 refused a 0.4.1 priorities file: ' .. tostring(store.error))
local expected = 0
for key, row in pairs(persisted) do
    for value, prio in pairs(row) do
        expected = expected + 1
        assert(store.get(key, value) == prio,
            ('row %s|%d: 0.4.1 wrote %s, rc1 read %s'):format(key, value, tostring(prio), tostring(store.get(key, value))))
    end
end
assert(n == expected, ('rc1 loaded %d rows, 0.4.1 persisted %d'):format(n, expected))
assert(fs.files['priorities.txt'] == written_prio, 'loading rewrote the upgraded file')

local caps = require('caps')
caps.load('caps.txt')
assert(caps.state == nil or caps.state == 'saved', 'rc1 refused a 0.4.1 caps file: ' .. tostring(caps.error))
-- Ground truth is the bytes 0.4.1 wrote, not 0.4.1's own reload (which folds
-- the wildcard rule into guild tables).
local rules = 0
for line in written_caps:gmatch('[^\r\n]+') do
    if line:sub(1, 1) ~= '#' then
        local guild, work, item, ceiling = line:match('^([^|]+)|([^|]+)|([^|]+)|(%d+)$')
        assert(guild, '0.4.1 wrote an unexpected caps line: ' .. line)
        rules = rules + 1
        local got = caps.data[guild] and caps.data[guild][work] and caps.data[guild][work][item]
        assert(got == tonumber(ceiling), ('limit %s|%s|%s: 0.4.1 wrote %s, rc1 read %s'):format(
            guild, work, item, ceiling, tostring(got)))
    end
end
assert(rules == 3, 'fixture should persist 3 limit rules, got ' .. rules)
assert(fs.files['caps.txt'] == written_caps, 'loading rewrote the upgraded caps file')
