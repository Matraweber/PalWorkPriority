package.loaded.log = { debug=function() end, say=function() end, warn=function() end, error=function() end }
local file = require('datafile')
local create_fs = require('memory_fs')
local decode = function(s) if s == 'old' or s == 'new' then return s end return nil,'invalid' end
for _, fault in ipairs({'open','write','close','rename_old','rename_new','remove_backup'}) do
    local fs = create_fs()
    file.fs = fs
    assert(file.write('save','old',0))
    fs.files['save.bak'] = 'old'
    fs.fault = function(op,path)
        return (fault==op and path=='save.tmp')
            or (fault=='rename_old' and op=='rename' and path=='save>save.bak')
            or (fault=='rename_new' and op=='rename' and path=='save.tmp>save')
            or (fault=='remove_backup' and op=='remove' and path=='save.bak')
    end
    assert(file.write('save','new',1) == false, fault .. ' reported success')
    fs.fault = nil
    local value = file.read('save',decode)
    assert(value=='old' or value=='new', fault .. ' lost every valid generation')
    assert(fs.files.save or fs.files['save.bak'], fault .. ' destroyed previous generation')
end
-- Crash after verified temporary write and rotation: recover without truncation.
local fs = create_fs(); file.fs = fs
assert(file.write('save','old',0))
fs.fault=function(op,path) return op=='rename' and path=='save.tmp>save' end
assert(not file.write('save','new',1))
fs.fault=nil
local value,meta = file.read('save',decode)
assert(value=='new' and meta.recovered)
fs.files['save.tmp']=fs.files['save.tmp']:sub(1,-2)
assert(file.read('save',decode)=='old', 'truncated temporary generation was accepted')
fs.files['bad']='not a priority row'
assert(file.read('bad',decode)==nil, 'corrupt save was treated as empty')
local store=require('store')
store.load('priorities'); store.set_role('authority')
assert(not store.set('slot3',1,2), 'temporary Pal identity persisted')
assert(not store.set('guid',1,1.5), 'fraction accepted')
assert(store.set('guid',1,false)); assert(store.flush(nil,true))
fs.fault=function(op,path) return op=='write' and path=='priorities.tmp' end
assert(not store.set('guid',2,3)); assert(not store.flush(nil,true))
assert(store.state=='error')
fs.fault=nil
assert(store.flush(nil,true)); assert(store.state=='saved')
store.set_role('client')
assert(not store.apply_set('guid',1,4)); assert(not store.save())
store.set_role(nil)
assert(not store.set('guid',1,4))

-- Review round 3 (P2-2): two bad hand edits in a row. The second one used to
-- meet the first one's .rejected.<gen> name and refuse every save for good.
do
    local fs2 = create_fs(); file.fs = fs2
    assert(file.write('rows','old',0)); assert(file.write('rows','old',1))
    fs2.files.rows = 'edited badly'
    local loaded, meta = file.read('rows',decode)
    assert(loaded == 'old' and meta.generation == 1, 'the older valid generation did not load')
    local saved, why, gen = file.write('rows','new',meta.generation,decode)
    assert(saved and gen == 2, tostring(why))
    assert(fs2.files['rows.rejected.2'] == 'edited badly', 'the first bad edit was not kept')
    -- Edited again the same way before the next launch, and again differently.
    fs2.files.rows = 'edited badly'
    loaded, meta = file.read('rows',decode)
    -- The live file is gen 2 again only by name; .bak still holds gen 1.
    assert(loaded == 'old' and meta.generation == 1)
    saved, why = file.write('rows','new',meta.generation,decode)
    assert(saved, 'the same bad edit twice stopped saving: ' .. tostring(why))
    assert(fs2.files['rows.rejected.2'] == 'edited badly' and fs2.files['rows.rejected.2.2'] == nil,
        'the same bytes were kept twice')
    fs2.files.rows = 'edited badly again'
    loaded, meta = file.read('rows',decode)
    saved, why = file.write('rows','new',meta.generation,decode)
    assert(saved, 'a second different bad edit stopped saving: ' .. tostring(why))
    assert(fs2.files['rows.rejected.2.2'] == 'edited badly again', 'the second bad edit was lost')
    assert(file.read('rows',decode) == 'new')
end

-- Review round 3 (P2-1): a live file without an intact envelope came from
-- 0.4.1 or a person. Decoding cleanly, it wins over the older .bak, takes the
-- highest generation and is rewritten; alone it is a plain upgrade.
do
    local fs3 = create_fs(); file.fs = fs3
    assert(file.write('hand','old',0)); assert(file.write('hand','old',1))
    fs3.files.hand = 'new' -- envelope removed, as 0.4.1 writes it
    local value, meta = file.read('hand',decode)
    -- 0.4.1 replaced gen 2, so the highest number left is the .bak's 1.
    assert(value == 'new' and meta.recovered and meta.generation == 1, 'the older .bak won over the edit')
    local saved, _, gen = file.write('hand','new',meta.generation,decode)
    assert(saved and gen == 2 and fs3.files['hand.bak'] == 'new', 'the edited file was not kept as .bak')
    -- Envelope kept, body edited: the checksum fails, the payload still decodes.
    fs3.files.hand = fs3.files.hand:gsub('\nnew$', '\nold')
    value, meta = file.read('hand',decode)
    assert(value == 'old' and meta.recovered and meta.generation == 2, 'the stated generation was lost')
    -- Zero bytes is a failed write, never an edit: the .bak still wins.
    local fs4 = create_fs(); file.fs = fs4
    assert(file.write('empty','old',0)); assert(file.write('empty','new',1))
    fs4.files.empty = ''
    value = file.read('empty',function(s) if s == '' then return 'blank' end return decode(s) end)
    assert(value == 'old', 'an empty live file won over the .bak: ' .. tostring(value))
    file.fs = fs3
    -- Alone and plain: read as it is, nothing to rewrite.
    fs3.files = { lone = 'old' }
    value, meta = file.read('lone',decode)
    assert(value == 'old' and not meta.recovered and meta.generation == 0)
    -- No .bak yet: an unfinished first save on top of a plain file is newer.
    fs3.files = { first = 'old' }
    fs3.fault = function(op,path) return op=='rename' and path=='first.tmp>first' end
    assert(not file.write('first','new',0))
    fs3.fault = nil
    fs3.files['first.bak'] = nil
    fs3.files.first = 'old'
    value, meta = file.read('first',decode)
    assert(value == 'new' and meta.recovered, 'an interrupted first save lost to the plain file')
end

-- Review round 4 (Gap 7 / engine P3-3): a live file cut off at a line end
-- still parses, so it reads like a hand edit and wins over the full .bak.
-- Nothing tells the two apart, so it is used, but the warning says it may be
-- cut off instead of calling it an edit.
do
    local warned = {}
    package.loaded.log.warn = function(message) warned[#warned + 1] = tostring(message) end
    local rows = function(s)
        local n = 0
        for line in s:gmatch('[^\n]+') do
            if not line:match('^row%d+$') then return nil, 'invalid' end
            n = n + 1
        end
        return n
    end
    local fs4 = create_fs(); file.fs = fs4
    assert(file.write('cut', 'row1\nrow2\nrow9\n', 3))
    assert(file.write('cut', 'row1\nrow2\nrow3\n', 4))
    assert(fs4.files['cut.bak'] and fs4.files.cut:find('^# PWP%-DATA 1 5 '))
    fs4.files.cut = fs4.files.cut:sub(1, -6)
    local count, meta = file.read('cut', rows)
    assert(count == 2 and meta.generation == 5 and meta.recovered, 'the cut copy was not the one read')
    assert(#warned == 1 and warned[1]:find('cut is shorter than its first line says: cut off by a crash or a sync tool',
        1, true), tostring(warned[1]))
    -- A hand edit of the same length is still called an edit.
    warned = {}
    assert(file.write('same', 'row1\nrow2\n', 0))
    assert(file.write('same', 'row1\nrow3\n', 1))
    fs4.files.same = fs4.files.same:gsub('row3', 'row4')
    assert(file.read('same', rows) == 2)
    assert(#warned == 1 and warned[1]:find('was changed outside this version', 1, true), tostring(warned[1]))
    package.loaded.log.warn = function() end
end

-- Review round 4 (persistence P3-1): an editor's byte order mark made a hand
-- edit invalid, so the .bak quietly replaced it on the next save.
do
    local rows = function(s)
        local n = 0
        for line in s:gmatch('[^\n]+') do
            if not line:match('^row%d+$') then return nil, 'invalid' end
            n = n + 1
        end
        return n
    end
    local fs5 = create_fs(); file.fs = fs5
    assert(file.write('bom', 'row1\n', 0))
    assert(file.write('bom', 'row1\nrow2\n', 1))
    fs5.files.bom = string.char(239, 187, 191) .. 'row1\nrow2\nrow3\n'
    local count, meta = file.read('bom', rows)
    assert(count == 3 and meta.recovered, 'a hand edit with a byte order mark lost to the .bak')
    -- Its next save keeps the edit as the .bak, not as a rejected copy.
    assert(file.write('bom', 'row1\nrow2\nrow3\n', meta.generation, rows))
    assert(fs5.files['bom.bak'] == string.char(239, 187, 191) .. 'row1\nrow2\nrow3\n'
        and fs5.files['bom.rejected.' .. (meta.generation + 1)] == nil)
end
