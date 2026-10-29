-- Reuse the real panel renderer's UMG fixture to check its existing callback.
-- This models engine brush ownership; it does not certify native lifetimes.
dofile(TEST_ROOT .. '/tests/test_panel_render.lua')
local panel, wired_icons=require('panel'), require('icons')
local function upvalue(fn, wanted, seen)
    seen=seen or {}
    if seen[fn] then return end
    seen[fn]=true
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value end
        if type(value)=='function' then
            local found=upvalue(value,wanted,seen)
            if found~=nil then return found end
        end
    end
end
local callback=assert(wired_icons.on_sweep)
local timers, now, loads={},0,0
package.loaded.clock={every=function(name,_,fn) timers[name]=fn end,
    cancel=function(name) timers[name]=nil end}
package.loaded.icondex={NAMES={handoff='Material_Handoff'}, FOLDER='/Test/'}
local old_clock,old_open=os.clock,io.open
os.clock=function() return now end
io.open=function() return nil end
package.loaded.icons=nil
local icons=require('icons')
icons.on_sweep=callback
local current
LoadAsset=function()
    loads=loads+1
    current={IsValid=function() return true end}
    return current
end
FindAllOf=function() error('handoff must not rediscover textures') end
StaticFindObject=function() error('handoff must not rediscover textures') end
assert(panel.open)
assert(icons.get('Handoff')==nil and loads==0)
assert(timers.icons_pump)()
local pins=assert(upvalue(callback,'pinned'))
local pin=assert(pins.Material_Handoff, 'real panel did not pin singleton LoadAsset result')
assert(pin.Brush.ResourceObject==current and pin.parent and pin.visibility==1)
assert(not timers.icons_pump and loads==1)

-- Perf P2-3: pins are not part of the tree rescan. Each pin was an Image on
-- the panel's root, so ensure_root's rescan (five times a second) named one
-- more widget for every icon a session pinned, up to 400. Counted here as
-- GetFullName calls in a settled refresh, the rescan's per-widget cost.
local rb=assert(upvalue(panel.refresh,'RB'))
local Widget=getmetatable(pin).__index
local full,named=Widget.GetFullName,0
Widget.GetFullName=function(self) named=named+1 return full(self) end
local construct,made=StaticConstructObject,0
StaticConstructObject=function(...) made=made+1 return construct(...) end
local function settled()
    panel.refresh(rb.cfg); panel.refresh(rb.cfg)
    named=0; panel.refresh(rb.cfg); return named
end
local before=settled()
local textures, found={}, {}
for i=1,50 do
    local id='Stone'..string.char(65+i//26)..string.char(65+i%26)
    textures[id]={IsValid=function() return true end, id=id}
    found[id]=textures[id]
end
for _=1,3 do callback(found) end
local pin_count=assert(upvalue(callback,'pin_count'))
assert(pin_count==51, 'fixture: '..pin_count..' pins')
local after=settled()
assert(after<=before+1, 'the rescan grew from '..before..' to '..after..' names with 50 pins')
-- Reuse: a second sweep of the same icons makes no new pin.
made=0; callback(found)
assert(made==0, 'a repeated sweep made '..made..' new widgets')
-- And a tile draws its picture from the pin, never from a lookup: the
-- panel's icons stub finds nothing, so only a pin can supply it.
-- Show all over these ids, so the page is exactly the pinned items.
local ids={}
for id in pairs(textures) do ids[#ids+1]=id end
table.sort(ids)
local items_stub=package.loaded.items
items_stub.catalogue_ids=function() return ids, 'ready' end
items_stub.prepare_picker=function() return {}, 'ready' end
items_stub.search_picker=function() return {} end
panel.set_screen('item'); panel.refresh(rb.cfg)
assert(panel.apply(rb.cfg,{kind='toggle_all'},-1,true))
for _=1,6 do panel.refresh(rb.cfg) end
local from_pin=0
for id, tex in pairs(textures) do
    if pins[id] == nil then rb.read_shelf() end
    local p=pins[id]
    assert(p and p.Brush.ResourceObject==tex, 'pin for '..id..' lost')
end
local seen={}
local function walk(w)
    if seen[w] then return end
    seen[w]=true
    if w.kind=='Image' and w.Brush and w.Brush.ResourceObject and w.visibility~=1 then
        for _, tex in pairs(textures) do if w.Brush.ResourceObject==tex then from_pin=from_pin+1 end end
    end
    for _, c in ipairs(w.children or {}) do walk(c) end
end
walk(assert(upvalue(panel.refresh,'root')))
assert(from_pin>=10, 'only '..from_pin..' tiles drew their picture from a pin')
Widget.GetFullName, StaticConstructObject=full, construct
panel.apply(rb.cfg,{kind='toggle_all'},-1,true)
panel.set_screen('list'); panel.refresh(rb.cfg)

-- A closed panel declines the same callback contract. No acknowledgement is
-- needed; get can reacquire if there is no engine pin to read.
panel.close()
icons.reset()
assert(icons.get('Handoff')==nil)
now=now+0.101; assert(timers.icons_pump)()
assert(next(assert(upvalue(callback,'pinned')))==nil)
assert(icons.get('Handoff')~=nil, 'closed-panel callback made icon unavailable')
os.clock,io.open=old_clock,old_open
