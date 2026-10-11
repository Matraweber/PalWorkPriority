local probe = require('stand_event_probe')
local requested = {}
local function widget(path)
    return {GetClass=function() return {GetFullName=function()
        return 'BlueprintGeneratedClass '..path
    end} end}
end
local cell = widget('/Game/Example.Cell_C')
cell.PalCheckBox = widget('/Script/Pal.PalCheckBox')
local out = probe.read(cell, function(obj) return obj ~= nil end, function(path)
    requested[#requested+1] = path
    if path == '/Game/Example.Cell_C:OnMouseButtonDown' then
        return {GetFullName=function() return 'Function '..path end}
    end
    if path:find('OnKeyDown',1,true) then error('unavailable') end
    -- Reject a lookup of an inherited or unrelated function as evidence that
    -- this class actually implements the event.
    return {GetFullName=function() return 'Function /Script/UMG.UserWidget:OnMouseButtonUp' end}
end)
assert(#requested == 10)
assert(out:find('OnMouseButtonDown: present',1,true))
assert(out:find('OnMouseButtonUp: absent on this class',1,true))
assert(out:find('OnKeyDown: lookup failed',1,true))
assert(probe.read(nil,function(obj) return obj ~= nil end,function() error('must not query') end)
    :find('cell: class unavailable',1,true))
print('stand input probe: bounded, read-only presence checks passed')

local callback, hooks = nil, 0
RegisterHook=function(path, fn)
    assert(path == '/Script/UMG.UserWidget:OnMouseButtonDown')
    callback, hooks = fn, hooks+1
end
assert(probe.watch():find('census on',1,true))
callback({get=function() return cell end})
assert(probe.report():find('1 BlueprintGeneratedClass /Game/Example.Cell_C',1,true))
assert(probe.watch():find('census on',1,true) and hooks == 1)
assert(probe.report():find('no native events',1,true))
callback({get=function() error('unavailable') end})
assert(probe.report():find('unreadable context',1,true))
