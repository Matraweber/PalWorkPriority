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

-- A closed panel declines the same callback contract. No acknowledgement is
-- needed; get can reacquire if there is no engine pin to read.
panel.close()
icons.reset()
assert(icons.get('Handoff')==nil)
now=now+0.101; assert(timers.icons_pump)()
assert(next(assert(upvalue(callback,'pinned')))==nil)
assert(icons.get('Handoff')~=nil, 'closed-panel callback made icon unavailable')
os.clock,io.open=old_clock,old_open
