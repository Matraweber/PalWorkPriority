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

-- Review round 3 (P2-1): back to 0.4.1 and up again. 0.5 saves twice (live
-- gen 2, .bak gen 1), 0.4.1 runs for a while and its own save() writes a plain
-- file, then 0.5 loads. The older .bak used to win and drop every 0.4.1 edit.
do
    local A = '00000000000000000000000000000001679D42C842B4D85AC496DCBF862D1565'
    store.set_role('authority')
    assert(store.set(A, 4, 2) and store.generation == 1, '0.5 first save failed')
    assert(store.set(A, 5, 1) and store.generation == 2, '0.5 second save failed')
    assert(fs.files['priorities.txt.bak'], 'no .bak after two saves')

    old_store.load('priorities.txt')
    assert(old_store.data[A][4] == 2, '0.4.1 could not read the 0.5 file')
    old_store.data[A][4] = 5
    old_store.data[A][9] = 3
    assert(old_store.save(), '0.4.1 save failed')
    assert(fs.files['priorities.txt']:sub(1, 11) ~= '# PWP-DATA ', 'fixture: 0.4.1 wrote an envelope')

    local rows = store.load('priorities.txt')
    assert(store.get(A, 4) == 5 and store.get(A, 9) == 3 and store.get(A, 5) == 1,
        "0.5 dropped 0.4.1's edits for its older .bak")
    assert(rows > 0 and store.state == 'saving', 'the 0.4.1 file was not marked for a rewrite')
    assert(store.generation == 1, 'generation is not the highest one left: ' .. tostring(store.generation))
    assert(store.flush(nil, true) and store.generation == 2)
    assert(store.load('priorities.txt') and store.get(A, 9) == 3 and store.state == 'saved')
end

-- Review round 4 (P2-1): rows 0.4.1 skipped. One of them used to refuse the
-- whole file, and with no .bak to fall back on the mod stopped for good.
-- 0.4.1 read a file with no envelope line by line and dropped what it could
-- not parse; 0.5 now does the same for such a file, names each row, and
-- leaves the bytes alone until its first save rotates them to .bak.
do
    local warned = {}
    quiet.warn = function(message) warned[#warned + 1] = tostring(message) end
    local function said(text)
        for _, line in ipairs(warned) do if line:find(text, 1, true) then return true end end
        return false
    end
    local BOM = string.char(239, 187, 191)
    local prio = BOM .. '# Pal Work Priority - per-pal edits from the Monitoring Stand.\n'
        .. '# palkey|worktype|priority   (X = never assign)\n'
        .. 'PAL-A|4|1\nPAL-A|5|3 \nPAL-B|7|1.5\nPAL-B|3|2\nPAL-C|1|'
    fs.files['p041.txt'] = prio
    local rows = store.load('p041.txt')
    assert(store.state == 'saved', 'a skipped row refused the file: ' .. tostring(store.error))
    assert(rows == 2 and store.get('PAL-A', 4) == 1 and store.get('PAL-B', 3) == 2, 'good rows lost')
    assert(store.get('PAL-A', 5) == nil and store.get('PAL-B', 7) == nil)
    for _, row in ipairs({ "'PAL-A|5|3 '", "'PAL-B|7|1.5'", "'PAL-C|1|'" }) do
        assert(said('priorities: skipped unreadable row ' .. row .. ' in p041.txt, as 0.4.1 did'),
            'not named: ' .. row)
    end
    assert(fs.files['p041.txt'] == prio, 'loading rewrote the file')
    assert(store.set('PAL-A', 4, 2), 'saving over the old file failed')
    assert(fs.files['p041.txt.bak'] == prio, 'the original bytes were not kept as .bak')
    assert(store.load('p041.txt') == 2 and store.get('PAL-A', 4) == 2 and store.state == 'saved')

    warned = {}
    local limits = BOM .. '# Pal Work Priority - stock limits\n'
        .. 'guild-1|Mining|Stone|100\nguild-1|Lumbering|Wood|50\nguild-1|Deforest|Wood|30 \n'
        .. '*|Mining|Ore|1.5\nguild-1|Deforest|Stone|20\nguild-1|Mining|Co'
    fs.files['c041.txt'] = limits
    local limit_rows = caps.load('c041.txt')
    -- A trailing space after the number was always read here (tonumber).
    assert(limit_rows == 3 and caps.state == 'saved', 'a skipped limit refused the file: '
        .. tostring(caps.error))
    assert(caps.data['guild-1'].Mining.Stone == 100 and caps.data['guild-1'].Deforest.Stone == 20
        and caps.data['guild-1'].Deforest.Wood == 30 and caps.data['*'] == nil)
    for _, row in ipairs({ "'guild-1|Lumbering|Wood|50'", "'*|Mining|Ore|1.5'",
        "'guild-1|Mining|Co'" }) do
        assert(said('limits: skipped unreadable row ' .. row .. ' in c041.txt, as 0.4.1 did'), 'not named: ' .. row)
    end
    assert(fs.files['c041.txt'] == limits, 'loading rewrote the caps file')

    -- Not one good row is no 0.4.1 file: unreadable data never becomes the
    -- defaults.
    fs.files['bad041.txt'] = 'not a row\nnor this\n'
    store.load('bad041.txt')
    assert(store.state == 'error', 'a file of only bad rows became empty priorities')
    -- P2-2: the stand says why (ui.store_message, test_ui_integration).
    assert(store.load_failed, 'a refused load was not marked')
    assert(not store.set('PAL-A', 4, 2), 'an edit over a refused file was accepted')
    store.load('p041.txt')
    assert(not store.load_failed, 'a loaded file still reported a refusal')
    quiet.warn = function() end
end
