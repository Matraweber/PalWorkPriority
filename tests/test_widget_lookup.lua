local calls, viewport = 0, false
local pc, cls = {}, {}
local mode = 'flat'
local lib = {}
function lib:GetAllWidgetsOfClass(context, out, kind, top)
    assert(context == pc and kind == cls and type(top)=='boolean')
    calls=calls+1
    if mode=='error' then error('not reflected') end
    local items = {{GetFullName=function() return 'WBP_WorkSuitabilityPreferenceMenu_C /Current.Menu' end}}
    if mode=='wrapped' then out.FoundWidgets=items else out[1]=items[1] end
end
package.loaded.palapi = {
    has_viewport=function() return viewport end,
    local_player_controller=function() return pc end,
    valid=function(x) return x~=nil end,
    unwrap=function(x) return x end,
    cdo=function(path) return path:find('Default__',1,true) and lib or cls end,
}
FindAllOf=function() return {{GetFullName=function() return 'UserWidget /Default__Stand' end, IsVisible=function() return false end}} end
local probe=require('widget_lookup')
assert(probe.probe():find('no local viewport') and calls==0)
viewport=true
for _, shape in ipairs({'flat','wrapped'}) do
    mode=shape
    local text=probe.probe()
    assert(text:find('1 results, 1 stand, 0 panel',1,true))
    assert(not text:find('FAILED',1,true))
end
mode='error'
assert(probe.probe():find('FAILED',1,true))
assert(calls==6)

mode='flat'
assert(probe.owned('/Current.Menu'))
assert(probe.owned('/Other.Menu')==nil)
local old=probe.owned('/Current.Menu')
local fresh=probe.owned('/Current.Menu')
assert(old~=fresh, 'viewport wrapper was retained between calls')
mode='wrapped'
assert(probe.owned('/Current.Menu'))
viewport=false
local before=calls
assert(probe.top_level()==nil and calls==before)
viewport=true; mode='error'
assert(probe.owned('/Current.Menu')==nil)
function lib:GetAllWidgetsOfClass(_,out)
    local w={GetFullName=function() return 'UserWidget /Duplicate' end}
    out[1],out[2]=w,w
end
assert(probe.owned('/Duplicate')==nil,'ambiguous ownership was accepted')
function lib:GetAllWidgetsOfClass(_,out)
    out[1]={GetFullName=function() return 'UserWidget /Match' end}
    out[2]={GetFullName=function() return false end}
end
assert(probe.owned('/Match')==nil,'partial query accepted a root')
function lib:GetAllWidgetsOfClass(_,out) for i=1,129 do out[i]={} end end
assert(probe.top_level()==nil, 'query exceeded its bound')
