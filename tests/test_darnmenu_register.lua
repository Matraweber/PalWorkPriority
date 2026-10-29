-- The shared DarnMenu index lists every mod's settings page (review round 2,
-- 2026-10-29). A full disk, a failed close or a crash between the two renames
-- must never lose another mod's entry.
local create_fs = require('memory_fs')
local log = require('log')
local darnmenu = require('darnmenu')

local original_io_open, original_rename, original_remove = io.open, os.rename, os.remove
local original_warn, original_debug = log.warn, log.debug
log.warn, log.debug = function() end, function() end

local DIR = 'S/'
local INDEX = DIR .. 'DarnMenu_schema_index.lua'
local SCHEMA = DIR .. 'DarnMenu_schema_PalWorkPriority.lua'
darnmenu.shared_dir = function() return DIR end

local fs
local function fresh(files)
    fs = create_fs()
    for path, text in pairs(files or {}) do fs.files[path] = text end
    io.open = function(path, mode) return fs.open(path, mode) end
    os.rename = function(a, b) return fs.rename(a, b) end
    os.remove = function(path) return fs.remove(path) end
end

local function names(text)
    assert(type(text) == 'string', 'index missing')
    local chunk = assert(load(text, '=index', 't', {}))
    local list = chunk()
    local set = {}
    for _, n in ipairs(list) do set[n] = true end
    return set, #list
end

local OTHER = 'return {\n  "OtherMod",\n}\n'

local ok, why = pcall(function()
    -- No index yet: ours alone, and the schema beside it.
    fresh()
    assert(darnmenu.register() == true)
    assert(fs.files[SCHEMA] and names(fs.files[INDEX]).PalWorkPriority)
    assert(fs.files[INDEX .. '.tmp'] == nil)

    -- Another mod already listed: both stay, the old list is kept as .bak.
    fresh({ [INDEX] = OTHER })
    assert(darnmenu.register() == true)
    local set, count = names(fs.files[INDEX])
    assert(set.OtherMod and set.PalWorkPriority and count == 2)
    assert(fs.files[INDEX .. '.bak'] == OTHER, 'old index was removed, not kept as .bak')

    -- Already listed: nothing is rewritten.
    local before = #fs.operations
    assert(darnmenu.register() == true)
    for i = before + 1, #fs.operations do
        assert(not fs.operations[i]:find('rename', 1, true), 'a listed index was rewritten')
    end

    -- Disk full: write returns nil, err. The index keeps its bytes.
    for _, op in ipairs({ 'write', 'close', 'read' }) do
        fresh({ [INDEX] = OTHER })
        -- Only the index's temporary file fails; the schema goes through.
        fs.fault = function(kind, path) return kind == op and path == INDEX .. '.tmp' end
        assert(darnmenu.register() == false, op .. ' failure was reported as success')
        fs.fault = nil
        assert(fs.files[SCHEMA], 'schema was not written')
        assert(fs.files[INDEX] == OTHER, op .. ' failure changed the shared index')
        assert(fs.files[INDEX .. '.tmp'] == nil, op .. ' failure left a temporary file')
    end

    -- The final rename fails: the old index is moved back.
    fresh({ [INDEX] = OTHER })
    fs.fault = function(kind, path) return kind == 'rename' and path == INDEX .. '.tmp>' .. INDEX end
    assert(darnmenu.register() == false)
    fs.fault = nil
    assert(fs.files[INDEX] == OTHER, 'failed rename lost the index')

    -- Both renames fail after the old index moved: .tmp and .bak stay, and the
    -- next launch rebuilds the index from them.
    fresh({ [INDEX] = OTHER })
    fs.fault = function(kind, path)
        return kind == 'rename' and (path == INDEX .. '.tmp>' .. INDEX or path == INDEX .. '.bak>' .. INDEX)
    end
    assert(darnmenu.register() == false)
    fs.fault = nil
    assert(fs.files[INDEX] == nil and fs.files[INDEX .. '.bak'] == OTHER and fs.files[INDEX .. '.tmp'])
    assert(darnmenu.register() == true)
    set, count = names(fs.files[INDEX])
    assert(set.OtherMod and set.PalWorkPriority and count == 2, 'recovery lost an entry')

    -- A crash between the renames, with a third mod in the new list.
    fresh({ [INDEX .. '.bak'] = OTHER, [INDEX .. '.tmp'] = 'return {\n  "OtherMod",\n  "ThirdMod",\n}\n' })
    assert(darnmenu.register() == true)
    set, count = names(fs.files[INDEX])
    assert(set.OtherMod and set.ThirdMod and set.PalWorkPriority and count == 3, 'crash recovery lost a mod')

    -- Only the .bak survived.
    fresh({ [INDEX .. '.bak'] = OTHER })
    assert(darnmenu.register() == true)
    assert(names(fs.files[INDEX]).OtherMod, 'index absent, .bak ignored')

    -- A half-written .tmp does not parse and is not trusted.
    fresh({ [INDEX .. '.bak'] = OTHER, [INDEX .. '.tmp'] = 'return {\n  "Other' })
    assert(darnmenu.register() == true)
    set, count = names(fs.files[INDEX])
    assert(set.OtherMod and count == 2)

    -- Present but unreadable, or not a plain list: left alone.
    for _, text in ipairs({ 'return {', 'return { "OtherMod", { nested = true } }', 'return { "A", extra = 1 }' }) do
        fresh({ [INDEX] = text })
        assert(darnmenu.register() == false)
        assert(fs.files[INDEX] == text, 'an index we cannot read was overwritten: ' .. text)
    end

    -- An index saved with a byte order mark still reads.
    fresh({ [INDEX] = '\239\187\191' .. OTHER })
    assert(darnmenu.register() == true)
    assert(names(fs.files[INDEX]).OtherMod)
end)

io.open, os.rename, os.remove = original_io_open, original_rename, original_remove
log.warn, log.debug = original_warn, original_debug
assert(ok, why)
print('darnmenu register: failures and crashes keep every other mod in the shared index')
