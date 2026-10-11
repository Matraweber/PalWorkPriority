local runtime = require("panel_runtime")
local made = 0
local function widget(name)
    local w = {name=name,calls={}}
    function w:GetFullName() assert(not self.dead) return self.name end
    function w:GetParent() return self.parent end
    function w:RemoveFromParent() self.parent=nil end
    function w:SetItem(id) assert(not self.dead) self.calls[#self.calls+1]=id end
    function w:SetVisibility(v) self.visible=v end
    return w
end
local parent = widget("parent")
function parent:AddChildToCanvas(w)
    w.parent=self
    local s={}
    for _,k in ipairs({"SetAnchors","SetAutoSize","SetZOrder","SetPosition","SetSize"}) do
        s[k]=function() end
    end
    w.Slot=s
    return s
end
local lib={}
function lib:Create()
    made=made+1
    return widget("tile"..made)
end
local registry={GetAsset=function() return {} end}
package.loaded.palapi={local_player_controller=function() return {} end,
    valid=function(w) return w~=nil end,cdo=function(path)
        if path:find("AssetRegistry",1,true) then return registry end
        return lib
    end}
EFindName={FNAME_Add=1}
FName=function(s) return s end
local proto=require("icon_prototype")
assert(proto.enabled==false)
local rt=runtime.new()
local state=proto.new(rt)
local anchor={Minimum={X=0,Y=0}}
assert(state:draw("a",parent,anchor,0,0,32,"Stone"))
local first=state.widgets.a
assert(first.calls[1]=="Stone")
state:finish()
assert(state:draw("a",parent,anchor,0,0,32,"Stone"))
assert(#first.calls==1, "unchanged item reissued")
assert(state:draw("a",parent,anchor,0,0,32,"Wood"))
assert(first.calls[2]=="Wood", "recycled tile did not receive latest item")
state:finish(); state:finish()
assert(first.calls[3]=="None" and state.tokens.a==nil, "unused load not cleared")
first.dead=true; rt.objects={}
assert(state:draw("a",parent,anchor,0,0,32,"Wood"))
assert(made==2 and state.widgets.a.calls[1]=="Wood", "replacement inherited draw token")
state:finish()
registry.GetAsset=function() return nil end
assert(state:draw("b",parent,anchor,0,0,32,"Stone")==false, "missing asset must permit fallback")
