-- Executes the real panel renderer against a deliberately small UMG model.
-- These assertions cover layout/lifecycle logic, not Unreal's native lifetime.
local registry, count, stale = {}, 0, 0
local Widget = {}
Widget.__index = Widget
local function check(w) if w.dead then stale = stale + 1 error("stale widget") end end
local function make(kind)
    count = count + 1
    local w = setmetatable({ kind = kind, name = kind .. " /Test.Panel.W" .. count,
        children = {}, Font = { Size = 20 }, Brush = {}, visibility = 0 }, Widget)
    registry[#registry + 1] = w
    return w
end
function Widget:IsValid() check(self) return true end
function Widget:GetFullName() check(self) return self.name end
function Widget:GetFName() return { ToString = function() return self.name end } end
function Widget:GetChildrenCount() check(self) return #self.children end
function Widget:GetChildAt(i) check(self) return self.children[i + 1] end
function Widget:GetParent() check(self) return self.parent end
function Widget:RemoveFromParent()
    check(self)
    if self.parent then
        for i, child in ipairs(self.parent.children) do
            if child == self then table.remove(self.parent.children, i) break end
        end
    end
    self.parent = nil
end
function Widget:AddChild(child)
    check(self) child:RemoveFromParent()
    self.children[#self.children + 1] = child
    child.parent = self
    child.Slot = make("Slot")
    return child.Slot
end
Widget.AddChildToCanvas = Widget.AddChild
function Widget:SetAnchors(v) check(self) self.anchors = v end
function Widget:SetPosition(v) check(self) self.position = v end
function Widget:SetSize(v) check(self) self.size = v end
function Widget:SetAutoSize(v) self.auto = v end
function Widget:SetZOrder(v) self.z = v end
function Widget:SetVisibility(v) check(self) self.visibility = v end
function Widget:SetHeightOverride(v) self.height = v end
function Widget:SetPadding(v) self.padding = v end
function Widget:SetBrushColor(v) check(self) self.colour = v end
function Widget:SetRenderOpacity(v) self.opacity = v end
function Widget:SetOpacity(v) self.opacity = v end
function Widget:SetFont(v) self.Font = v end
function Widget:SetShadowOffset() end
function Widget:SetShadowColorAndOpacity() end
function Widget:SetColorAndOpacity() end
function Widget:SetBrushFromTexture(v) self.Brush.ResourceObject = v end
function Widget:SetText(v) check(self) self.text = v:ToString() end
function Widget:GetText() check(self) return FText(self.text or "") end
function Widget:IsHovered() return false end
function Widget:SetKeyboardFocus() self.focus = true end
function Widget:HasKeyboardFocus() return self.focus == true end
function Widget:SetJustification() end
function Widget:SetHintText() end
function Widget:SetForegroundColor() end
function Widget:SetWidgetStyle() end
function Widget:SetSelectAllTextWhenFocused() end
function Widget:SetClearKeyboardFocusOnCommit() end
function Widget:SetMinDesiredWidth() end
function Widget:SetIsReadOnly() end
function Widget:SetRevertTextOnEscape() end
function Widget:SetIsPassword() end
function Widget:SetAllowContextMenu() end
FText = function(text) return { ToString = function() return text end } end
StaticConstructObject = function(cls) return make(cls.kind) end
local cfg = { enabled = true, storage_scope = "camp", item_limits_on_rocks = false }
local data, writes = {}, 0
local caps = { state = "saved", LADDER = { 100, 500, 1000 } }
function caps.all() return { Mining = data } end
function caps.rule_kind() return "legacy" end
function caps.support() return false, "This producer is unsupported" end
function caps.set(_, item, amount) writes = writes + 1 data[item] = amount return true end
function caps.clear(_, item) data[item] = nil return true end
package.loaded.caps = caps
package.loaded.log = setmetatable({}, { __index = function() return function() end end })
package.loaded.trace = { at = function() end, done = function() end }
package.loaded.palapi = {
    my_guild = function() return "guild" end,
    cdo = function(path) return { kind = path:match("%.([^%.]+)$") or path } end,
    player_controller = function() return nil end,
    has_viewport = function() return true end,
    base_camps = function() return {} end,
    game_ui_active = false,
}
local stock = {}
for i = 1, 90 do stock["Stone" .. string.char(64 + math.ceil(i / 26)) .. string.char(65 + i % 26)] = i end
stock.Stone01 = 37
local scheduler = { last_totals = {Stone01=9876543}, last_capped = {}, pass_id = 1,
    last_totals_by_camp = {base1=stock},
    last_storage_by_camp = {base1={guild="guild",scope="camp",verified=true,pass=1,sampled_at=os.clock(),ttl=30}},
    forget_stock = function() end }
package.loaded.scheduler = scheduler
package.loaded.items = { display_name = function(id) return id end,
    real_name = function(id) return id end, load = function() return {} end }
package.loaded.icons = { reset = function() end, new_frame = function() end,
    probe = function() end, get = function() return nil end,
    name_for = function(id) return id end, gave_up = function() return false end }
local pad_actions
package.loaded.pad = { drive = function(actions) pad_actions = actions end, forget = function() end }
local overlay = { generation = 0, parts = {}, open = false }
local bound_editor, refuse_editor, return_editor_focus
function overlay.set_amount_editor(w, return_focus)
    if refuse_editor and w then return false end
    bound_editor=w
    return_editor_focus=return_focus
    return true
end
local root, tree
local function build()
    root, tree = make("CanvasPanel"), make("WidgetTree")
    overlay.parts = { Root = root }
    for _, name in ipairs({ "Backdrop", "Body", "RuleList", "ItemList", "TabsRow", "Tabs",
        "TitleRow", "Title", "SubRow", "Sub", "NoticeRow", "Notice", "SearchRow", "Search",
        "CaptionRow", "Caption", "HeadRow", "Head", "FootRow", "Foot" }) do
        overlay.parts[name] = make(name)
        root:AddChild(overlay.parts[name])
    end
end
function overlay.show() if not root then build() end overlay.open = true return true end
function overlay.host() if overlay.open then return root, tree, root end end
function overlay.take_cancel(w)
    local pending = w.cancel_requested
    if not w.cancel_ack_fails then w.cancel_requested = false end
    if w.cancel_readback_fails then
        w.cancel_readback_fails = false
        return pending == true, false
    end
    return pending == true, not w.cancel_ack_fails
end
function overlay.hide()
    overlay.open = false
    for _, w in ipairs(registry) do w.dead = true end
    root, tree = nil, nil
    overlay.generation = overlay.generation + 1
end
package.loaded.overlay = overlay
-- A clock the tests can move (review round 2): a confirm sooner than
-- RB.CONFIRM_MIN_S after its arm is a double-click and does nothing, so two
-- clicks a test means as two decisions call later() between them. Tests
-- that replace os.clock themselves move their own `now` instead.
local real_clock, skew = os.clock, 0
os.clock = function() return real_clock() + skew end
local function later(s) skew = skew + (s or 0.5) end
local panel = require("panel")
local function rules(n)
    data = {}
    for i = 1, n do data["Stone" .. string.format("%02d", i)] = 100 + i end
end
local function rendered(text)
    for _, w in ipairs(registry) do
        if not w.dead and w.text == text then return w end
    end
end
rules(1)
panel.refresh(cfg)
panel.toggle()
-- One line per job cell (round 2): a group row is its job, no sub-label.
assert(panel.open and rendered("Mining") and not rendered("Group limit"))
assert(rendered("No count yet"), "missing scheduler evidence claimed work was active")
rules(0)
for _,entry in ipairs({{'ready','Click "Add a limit" below to start.'},
    {'connecting','Limits unavailable; check the status above.'}})do
    caps.view_status=function()return entry[1] end
    panel.refresh(cfg)
    local empty=assert(rendered(entry[2]))
    assert(empty.parent==overlay.parts.Head,'empty-state text escaped its panel row')
    assert(overlay.parts.HeadRow.visibility==0,'empty-state row collapsed')
end
caps.view_status=nil;rules(1);panel.refresh(cfg)
caps.state = "saving"
panel.refresh(cfg)
assert(rendered("Saving..."))
caps.state, caps.error = "error", "Disk write failed; retry pending"
panel.refresh(cfg)
assert(rendered("Save failed - changes need attention"))
assert(rendered("Disk write failed; retry pending"))
caps.state, caps.error = "saved", nil
for _, entry in ipairs({{"connecting","Connecting to server..."},
    {"pending","Sending changes..."},{"acknowledged","Server accepted - awaiting data"},
    {"ready","Synced with server"},{"rejected","Server rejected changes"},
    {"accepted","Confirmed by server"}}) do
    caps.view_status=function() return entry[1], "ack_timeout" end
    panel.refresh(cfg)
    assert(rendered(entry[2]), "header ignored remote state "..entry[1])
    assert(not rendered("Saved") and not rendered("Limits saved"), "local Saved label overrode remote status")
    assert(rendered("Server did not acknowledge the change."), "remote error not shown")
end
caps.view_status=function() return "applied_unsaved", "save_failed" end
panel.refresh(cfg)
assert(rendered("Applied - not saved"),"applied_unsaved has no truthful human label")
assert(rendered("The server applied this change but could not save it; it may be lost after a restart."),
    "save_failed has no actionable explanation")
assert(not rendered("Saved") and not rendered("Limits saved") and not rendered("Confirmed by server"),"unsaved changes claimed durable acceptance")
caps.view_status=nil
panel.refresh(cfg)
assert(rendered("37"), "panel did not consume selected camp storage")
assert(not rendered("9.8M") and not rendered("9.9M"), "cross-guild aggregate leaked into storage column")
scheduler.last_capped.Mining={pass=1,camps=1,capped=1,unknown=1}
panel.refresh(cfg)
assert(rendered("No count yet") and not rendered("Stopped"), "unknown verdict claimed Stopped")
scheduler.last_storage_by_camp.base1.verified=false
panel.refresh(cfg)
assert(rendered("?"), "unverified storage showed a known quantity")
scheduler.last_storage_by_camp.base1.verified=true
scheduler.last_capped.Mining={pass=1,camps=1,capped=1,unknown=0}
panel.refresh(cfg)
assert(rendered("Limit reached") and not rendered("Stopped"), "cap decision claimed actual work stopped")
scheduler.last_capped.Mining={pass=1,camps=1,capped=0,unknown=0}
panel.refresh(cfg)
assert(rendered("Below limit") and not rendered("Working"), "uncapped decision claimed actual work")
scheduler.last_totals_by_camp.base1.Stone01=200
panel.refresh(cfg)
assert(rendered("Others below") and not rendered("Waiting"), "legacy rule claimed actual waiting")
scheduler.last_totals_by_camp.base1.Stone01=37
scheduler.last_capped.Mining={pass=1,camps=2,capped=2,unknown=0}
scheduler.last_storage_by_camp.foreign={guild="other",scope="camp",verified=true,pass=1}
panel.refresh(cfg)
assert(rendered("No count yet") and not rendered("Stopped"), "other guild's verdict leaked")
scheduler.last_storage_by_camp.foreign=nil
scheduler.last_storage_by_camp.base2={guild="guild",scope="camp",verified=true,pass=1,sampled_at=os.clock(),ttl=30}
scheduler.last_totals_by_camp.base2={Stone01=18}
panel.refresh(cfg)
assert(panel.apply(cfg,{kind="stock_scope"},1,true))
panel.refresh(cfg)
assert(rendered("18"), "base selector did not change the scoped storage quantity")
scheduler.last_storage_by_camp.base2=nil
scheduler.last_totals_by_camp.base2=nil
scheduler.last_capped={}
for _, n in ipairs({ 0, 1, 13, 14, 26, 27 }) do
    rules(n)
    panel.refresh(cfg)
    if n==0 then
        assert(rendered('Click "Add a limit" below to start.'))
        caps.view_status=function() return "connecting" end
        panel.refresh(cfg)
        assert(rendered("Limits unavailable; check the status above."))
        assert(not rendered('Click "Add a limit" below to start.'), "unknown snapshot presented as no rules")
        caps.view_status=nil
    end
    if n > 13 then
        local pager = assert(rendered("Next   >"), "missing rules pager")
        assert(pager.parent ~= root, "pager was attached to root canvas")
        assert(pager.parent.parent.parent == overlay.parts.RuleList, "rules pager is outside its list")
        local pager_y = pager.Slot.position.Y
        panel.page_step(cfg, 1)
        panel.refresh(cfg)
        local prev = assert(rendered("<   Previous"))
        assert(prev.parent.parent.visibility == 0, "pager hidden on the short last page")
        assert(math.abs(prev.Slot.position.Y - pager_y) < 0.000001,
            "short-page pager retained its old offset")
        panel.page_step(cfg, -1)
        panel.refresh(cfg)
    end
end
rules(14)
panel.refresh(cfg)
refuse_editor=true
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
local editor
for _, w in ipairs(registry) do if not w.dead and w.kind == "EditableTextBox" then editor = w end end
assert(editor and editor.parent.parent.parent == overlay.parts.RuleList, "amount editor not inside its rule row")
assert(not editor.focus and bound_editor==nil, 'unverified editor took native keyboard focus')
refuse_editor=false
panel.refresh(cfg)
assert(bound_editor==editor, 'focused editor was not registered with the native preview')
editor.text = "1.5"
assert(not panel.confirm_edit(cfg) and writes == 0 and data.Stone01 == 101)
editor.text = "700"
editor.focus = false
panel.refresh(cfg)
assert(writes == 0, "focus loss committed the edit")
panel.escape()
assert(panel.open and writes == 0, "Escape saved or closed before cancelling edit")
assert(editor.visibility == 1)
assert(bound_editor==nil, 'cancelled amount editor still owns native Escape')
assert(return_editor_focus==true, 'normal cancel did not request owned focus handoff')
-- A native Escape received before a queued Confirm cancels instead of saving.
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
root.cancel_requested = true
panel.confirm_edit(cfg, '999')
assert(panel.open and writes == 0 and data.Stone01 == 101,
    'queued Confirm beat the earlier native Cancel')
panel.refresh(cfg)
-- Regular refresh also services native Escape without another input action.
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
local deferred = {}
ExecuteInGameThread = function(fn) deferred[#deferred+1] = fn end
panel.confirm_edit(cfg, '999')
panel.nav(cfg, 'enter') -- Must not act on the underlying rule after cancellation.
root.cancel_requested = true
panel.refresh(cfg)
local queued = deferred; deferred = {}
for _,fn in ipairs(queued) do fn() end
assert(#deferred == 0 and panel.open and writes == 0 and data.Stone01 == 101,
    'deferred Confirm beat refresh cancellation or acted on the underlying rule')
ExecuteInGameThread = nil
assert(panel.open and writes == 0 and not root.cancel_requested,
    'refresh did not cancel the native edit request')
panel.refresh(cfg)
assert(editor.visibility == 1)
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
root.cancel_requested, root.cancel_ack_fails = true, true
panel.confirm_edit(cfg, '999')
panel.refresh(cfg)
assert(panel.open and writes == 0 and data.Stone01 == 101,
    'failed native Cancel acknowledgement permitted a save')
root.cancel_ack_fails = false
panel.refresh(cfg)
panel.refresh(cfg)
assert(panel.open and editor.visibility == 1 and writes == 0,
    'retried acknowledgement failed to cancel the original edit once')
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
root.cancel_requested, root.cancel_readback_fails = true, true
panel.refresh(cfg) -- The write worked, but its immediate readback was unavailable.
panel.refresh(cfg) -- A fresh verified false must acknowledge the pending Lua request.
panel.refresh(cfg)
assert(panel.open and editor.visibility == 1 and writes == 0,
    'successful clear with transient readback failure left the editor blocked')
root.cancel_requested = true
panel.refresh(cfg)
assert(not panel.open and writes == 0, 'next native Escape did not close')
panel.toggle(); panel.refresh(cfg)
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
editor=nil
for _,w in ipairs(registry) do if not w.dead and w.kind=='EditableTextBox' then editor=w end end
assert(editor and editor.visibility~=1, 'fresh amount editor did not open')
panel.pad_tick()
assert(pad_actions and pad_actions.close, 'panel did not bind controller Cancel')
overlay.native_cancel=true
pad_actions.close()
panel.refresh(cfg)
assert(panel.open and editor.visibility~=1, 'pad polling raced the active native cancel binding')
overlay.native_cancel=false
pad_actions.close()
assert(panel.open and writes == 0 and data.Stone01 == 101,
    'controller Cancel closed the panel instead of cancelling the edit')
panel.refresh(cfg)
assert(editor.visibility == 1, 'controller Cancel left the editor visible')
pad_actions.close()
assert(not panel.open and writes == 0, 'second controller Cancel did not close without saving')
panel.toggle()
panel.refresh(cfg)
panel.apply(cfg, { kind = "rule", rule = { work = "Mining", item = "Stone01", amount = 101 }, row = 4 }, -1, true)
panel.refresh(cfg)
assert(panel.confirm_edit(cfg, "700") and data.Stone01 == 700 and writes == 1)
assert(not panel.apply(cfg,{kind="job",rule={work="Mining",item="Stone01",amount=700},
    works={"Mining","Kindling"}},-1,true),"unsupported legacy migration was accepted")
assert(data.Stone01==700 and writes==1,"work-type change deleted the source legacy rule")
local clear=caps.clear
caps.clear=function() return false end
caps.error="Disk write failed; retry pending"
local remove={kind="drop",rule={work="Mining",item="Stone01",amount=700}}
panel.apply(cfg,remove,1,true)
later()
assert(not panel.apply(cfg,remove,1,true),"failed removal reported success")
panel.refresh(cfg)
assert(rendered("Disk write failed; retry pending"),"removal failure invented a guild-ownership explanation")
caps.clear=clear; caps.error=nil
assert(not panel.apply(cfg, { kind = "item", item = "StoneNew" }, -1, true))
assert(writes == 1, "unsupported producer created a rule")
panel.set_screen("item")
panel.refresh(cfg)
local picker_pager = assert(rendered("Next   >"))
assert(picker_pager.parent.parent.parent == overlay.parts.ItemList, "picker pager outside its grid list")
panel.close()
assert(not panel.open)
panel.close()
panel.refresh(cfg)
panel.toggle()
panel.refresh(cfg)
assert(stale == 0, "closed/destroyed widget was queried after reopen")

-- Real draw: unavailable catalogues/storage are not zero-result claims;
-- pending search schedules continuation without publishing partial tiles.
panel.set_screen("item")
local items = package.loaded.items
local catalogue_state = "pending"
items.prepare_picker = function() return nil, catalogue_state end
items.catalogue_ids = function() return nil, "unavailable" end
panel.refresh(cfg)
assert(panel.command(cfg, "filter ore") == "filter is now 'ore'")
panel.refresh(cfg)
assert(rendered("Preparing item search...   |   Under each item: what a click does"))
local rb
for i=1,100 do
    local name,value=debug.getupvalue(panel.refresh,i)
    if name=="RB" then rb=value break end
end
assert(rb and rb.pending, "unfinished index did not request continuation")
catalogue_state="unavailable"
panel.refresh(cfg)
assert(rendered("Item catalogue unavailable   |   Under each item: what a click does"))
assert(not rb.pending, "unavailable catalogue started a fast retry loop")
panel.command(cfg, "filter")
scheduler.last_storage_by_camp.base1.verified=false
panel.refresh(cfg)
-- Says how to get a count (round 2), not "choose Show all": nothing can
-- be added from Show all either until storage is counted.
assert(rendered("Storage not counted yet. Alt+F2 rechecks now.   |   Under each item: what a click does"))
-- A click after the last draw is valid when dispatch reacquires this tree.
-- The old 150ms draw-age gate rejected it despite successful current lookup.
local toggle=assert(rendered("Show all items a base can make"))
toggle.IsHovered=function() return true end
rb.validated=-100
assert(panel.handle_click(cfg,-1), "freshly validated delayed click was dropped")
panel.refresh(cfg)
assert(rendered("Item catalogue unavailable   |   Under each item: what a click does"))
toggle.IsHovered=function() return false end
local saved_host=overlay.host
overlay.host=function() return nil end
assert(not panel.handle_click(cfg,-1), "missing current tree permitted a click")
overlay.host=saved_host
panel.close()
panel.toggle()
panel.refresh(cfg)

-- A deferred host failure cancels edits and queued writes on this refresh,
-- even though the underlying close adapter has already finished.
panel.apply(cfg, {kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4}, -1, true)
panel.refresh(cfg)
local later, saved_writes = {}, writes
ExecuteInGameThread=function(fn) later[#later+1]=fn end
panel.confirm_edit(cfg, '888')
overlay.hide()
panel.refresh(cfg)
assert(not panel.open, 'host failure left panel open until another queued callback')
for _,fn in ipairs(later) do fn() end
ExecuteInGameThread=nil
assert(writes==saved_writes, 'host failure committed an abandoned edit')

-- Other renderer tests reuse this fixture with an open, current panel.
panel.toggle()
panel.refresh(cfg)
panel.apply(cfg, {kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4}, -1, true)
panel.refresh(cfg)
assert(bound_editor and bound_editor.focus)
local snapshot=rb.runtime.snapshot
rb.runtime.snapshot=function() return false end
panel.refresh(cfg)
assert(not panel.open and not overlay.open and bound_editor==nil,
    'unreadable tree left a visible native editor without Lua ownership')
assert(return_editor_focus~=true, 'failed-tree teardown requested focus')
rb.runtime.snapshot=snapshot
panel.toggle()
panel.refresh(cfg)

-- Exercise real snapshot rejection, not a stubbed false result. The root
-- advertises a child whose wrapper becomes unavailable during enumeration.
panel.apply(cfg, {kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4}, -1, true)
panel.refresh(cfg)
assert(bound_editor and bound_editor.focus)
local interrupted_writes, interrupted_count = writes, count
local old_child=root.GetChildAt
root.GetChildAt=function(self,i) if i==0 then return nil end return old_child(self,i) end
panel.refresh(cfg)
assert(not panel.open and not overlay.open and bound_editor==nil,
    'partial native tree retained an active amount editor')
assert(count==interrupted_count,'partial native tree created replacement controls')
assert(not panel.confirm_edit(cfg,'999') and writes==interrupted_writes,
    'partial native tree allowed an abandoned edit to save')
panel.toggle()
panel.refresh(cfg)
assert(panel.open and overlay.open and stale==0,'complete replacement tree failed to recover')
