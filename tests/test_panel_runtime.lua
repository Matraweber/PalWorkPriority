local runtime = require("panel_runtime")
assert(_VERSION == "Lua 5.4")
for _, text in ipairs({ "", "-100", "1.5", "+5", "1e3", "1,000", "12cats", "0", "10000000", "9999999999999999999999999" }) do
    assert(runtime.amount(text) == nil, "accepted malformed ceiling: " .. text)
end
assert(runtime.amount(" 4200 ") == 4200)
assert(runtime.amount("9999999") == 9999999)

local cache, calls = {}, 0
local function write() calls = calls + 1 end
assert(runtime.write(cache, "button", 0, write))
assert(runtime.write(cache, "button", 0, write) and calls == 1)
assert(runtime.write(cache, "button", 3, write)) -- hidden by another screen
assert(runtime.write(cache, "button", 0, write) and calls == 3)
assert(not runtime.write(cache, "button", 1, function() return false end))
assert(cache.button == nil)
assert(not runtime.write(cache, "button", 1, function() error("refused") end))
assert(runtime.write(cache, "button", 1, write) and calls == 4)

local function widget(name)
    local w = { name = name, children = {} }
    function w:GetFullName() assert(not self.dead, "stale wrapper touched") return self.name end
    function w:GetChildrenCount() return #self.children end
    function w:GetChildAt(i) return self.children[i + 1] end
    function w:GetParent() return self.parent end
    function w:RemoveFromParent() self.parent = nil end
    function w:AddChildToCanvas(child)
        child.parent = self
        local slot = {}
        function slot:SetAnchors(anchors) self.anchors = anchors end
        function slot:SetAutoSize(auto) self.auto = auto end
        function slot:SetZOrder(z) self.z = z end
        child.Slot = slot
        return slot
    end
    return w
end
local root, row, short_row = widget("root"), widget("row14"), widget("row7")
local pager = widget("pager")
local centre = { Minimum = { X = .5, Y = .5 } }
local corner = { Minimum = { X = 0, Y = 0 } }
local parents = {}
local slot = assert(runtime.place(parents, "pager", pager, root, centre, true, 9000))
assert(pager.parent == root and slot.anchors == centre)
slot = assert(runtime.place(parents, "pager", pager, row, corner, true, 9000))
assert(pager.parent == row and slot.anchors == corner)
slot = assert(runtime.place(parents, "pager", pager, short_row, corner, true, 9000))
assert(pager.parent == short_row, "row-to-row reuse did not move the pager")
local stretched = {Minimum={X=0,Y=0},Maximum={X=1,Y=1}}
slot = assert(runtime.place(parents,"pager",pager,short_row,stretched,true,9000))
assert(slot.anchors==stretched,"changing only Maximum anchors was incorrectly cached")
slot.SetAnchors = function() error("native anchor setter refused") end
assert(not runtime.place(parents, "pager", pager, short_row, centre, true, 9000))
assert(parents.pager == nil, "failed anchor write was cached")

local state = runtime.new()
local refs = state:cache()
root.children = { row }
assert(state:snapshot(root))
refs.row = row
row.dead = true
local replacement = widget("row14")
root.children = { replacement }
assert(state:snapshot(root))
assert(refs.row == replacement, "cache used yesterday's same-name wrapper")
root.children = {}
assert(state:snapshot(root) and refs.row == nil)
root.children = { replacement }
assert(not state:snapshot(root, 1), "partial tree must be unavailable")
assert(refs.row == nil)

-- An advertised child that cannot be resolved is not an absent control.
-- Partial acceptance lets the renderer recreate controls in an existing tree.
for _,failure in ipairs({"nil-child","throw-name","nil-name","empty-name"}) do
    local broken=widget("broken")
    function broken:GetFullName()
        if failure=="throw-name" then error("name unavailable") end
        if failure=="nil-name" then return nil end
        if failure=="empty-name" then return "" end
        return "broken"
    end
    local owner=widget("owner")
    owner.children={replacement,broken}
    if failure=="nil-child" then
        function owner:GetChildAt(i) if i==0 then return replacement end end
    end
    assert(not state:snapshot(owner),failure.." was accepted as a complete tree")
    assert(next(state.objects)==nil and refs.row==nil,
        failure.." exposed a partial widget snapshot")
    owner.children={replacement}
    assert(state:snapshot(owner) and refs.row==replacement,
        failure.." prevented recovery on the next complete tree")
end

local queue, fired = {}, 0
ExecuteInGameThread = function(fn) queue[#queue + 1] = fn end
state:dispatch(function() fired = fired + 1 end)
state:invalidate()
queue[1]()
assert(fired == 0, "old-session action executed")
state:dispatch(function() fired = fired + 1 end)
queue[2]()
assert(fired == 1)
state.session = { epoch = 3, ui_epoch = 8 }
state:dispatch(function() fired = fired + 1 end)
state.session.epoch = 4
queue[3]()
assert(fired == 1, "an old-world action survived the shared session change")
state:dispatch(function() fired = fired + 1 end)
state.session.ui_epoch = 9
queue[4]()
assert(fired == 1, "an old-widget action survived shared UI invalidation")

local bounded=runtime.new()
local pending_callbacks={}
ExecuteInGameThread=function(fn) pending_callbacks[#pending_callbacks+1]=fn end
for _=1,128 do assert(bounded:dispatch(function() end)) end
assert(not bounded:dispatch(function() error('queue overflow executed') end))
assert(#pending_callbacks==128 and bounded.pending==128,'panel native callback queue was not bounded')
bounded:invalidate()
for _,fn in ipairs(pending_callbacks) do fn() end
assert(bounded.pending==0,'stale callbacks altered the new generation queue count')
ExecuteInGameThread=function() error('queue unavailable') end
assert(not bounded:dispatch(function() end) and bounded.pending==0)
