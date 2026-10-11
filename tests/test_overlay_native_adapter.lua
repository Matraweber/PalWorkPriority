-- Exercise overlay.lua itself. The adapter models attachment/input calls;
-- it cannot establish native safety or compatibility with a game build.
local objects, all, next_id, stale = {}, {}, 0, 0
local methods = {}
local function check(w) if w.dead then stale = stale + 1 error("dead native wrapper") end end
local function make(kind)
    next_id = next_id + 1
    local w = setmetatable({ kind = kind, path = "/Test.Owner.Widget" .. next_id }, { __index = methods })
    objects[w.path], all[#all + 1] = w, w
    return w
end
function methods:GetAddress()
    for i,w in ipairs(all) do if w==self then return i end end
end
function methods:IsValid() check(self) return true end
function methods:GetFullName() check(self) return self.kind .. " " .. self.path end
function methods:SetIsFocusable() end
function methods:IsActivated() check(self) return self.active == true end
function methods:ActivateWidget() check(self) self.active = true end
function methods:DeactivateWidget() check(self) self.active = false end
function methods:SetKeyboardFocus() check(self) self.focus = true end
function methods:HasAnyUserFocus() check(self) return self.focus == true end
function methods:HasFocusedDescendants() check(self) return self.child_focus == true end
function methods:SetVisibility(v) check(self) self.visible = v end
function methods:AddToViewport() check(self) self.attached = true end
function methods:RemoveFromParent() check(self) self.attached = false end
local pc = make("PalPlayerController")
pc.bShowMouseCursor = false
function pc:K2_GetPawn() return nil end
function pc:SetIgnoreMoveInput(on) self.move_held = on end
function pc:DisableInput() self.disabled = true end
function pc:EnableInput() self.disabled = false end
local game_only, game_focus, ui_modes = 0, 0, 0
local lib = {}
function lib:SetInputMode_GameOnly() game_only = game_only + 1 end
function lib:SetFocusToGameViewport() game_focus = game_focus + 1 end
function lib:SetInputMode_GameAndUIEx() ui_modes = ui_modes + 1 end
local api = { game_ui_active = false, player_controller = function() return pc end }
function api.cdo(path)
    if path:find("Default__WidgetBlueprintLibrary", 1, true) then return lib end
    return { kind = path:match("%.([^%.]+)$") }
end
package.loaded.palapi = api
package.loaded.trace = { around = function(_, fn) return fn() end }
package.loaded.log = { say = function() end, warn = function() end, debug = function() end }
StaticConstructObject = function(cls) return make(cls.kind) end
StaticFindObject = function(path) return objects[path] end
FindAllOf = function(kind)
    local found = {}
    for _, w in ipairs(all) do
        if not w.dead and w.kind == kind then found[#found + 1] = w end
    end
    return found
end
local overlay = require("overlay")
overlay.mod_class = function(_, _, done) done(nil) end -- missing-pak fallback
local function attached()
    local n = 0
    for _, w in ipairs(all) do if w.attached then n = n + 1 end end
    return n
end
overlay.prepare()
assert(attached() == 0, "closed panel attached during preload")
assert(overlay.show() and attached() == 1 and ui_modes == 1)
assert(overlay.show() and attached() == 1 and ui_modes == 1, "duplicate show attached twice")
assert(overlay.native_cancel ~= true, 'missing-pak fallback claimed native Escape support')
local _, _, input_root = overlay.host()
input_root.PWP_InputContract, input_root.PWP_CancelRequested = 2, false
input_root.active, input_root.PWP_CancelBindingAttempted = true, true
overlay.host()
assert(overlay.native_cancel == true, 'current native input contract was ignored')
input_root.PWP_CancelBindingAttempted=false
overlay.host()
assert(not overlay.native_cancel, 'unregistered widget suppressed the raw fallback')
input_root.PWP_CancelBindingAttempted=true
overlay.host()
assert(not overlay.take_cancel(input_root))
input_root.PWP_CancelRequested = true
assert(overlay.take_cancel(input_root) and input_root.PWP_CancelRequested == false,
    'native Escape was not acknowledged before dispatch')
assert(not overlay.take_cancel(input_root), 'one native Escape became two actions')
input_root.PWP_InputContract=3
local amount=make('EditableTextBox')
assert(overlay.set_amount_editor(amount) and input_root.PWP_AmountEditor==amount)
assert(overlay.set_amount_editor(nil) and input_root.PWP_AmountEditor==nil,
    'cancelled editor remained owned by the native preview')
for _, focus in ipairs({'focus','child_focus'}) do
    amount.focus,amount.child_focus=false,false
    amount[focus]=true
    input_root.focus=false
    assert(overlay.set_amount_editor(amount))
    assert(overlay.set_amount_editor(nil,true) and input_root.focus,
        'cancel left keyboard focus on the hidden amount editor: '..focus)
end
amount.focus,amount.child_focus=false,false
input_root.focus=false
assert(overlay.set_amount_editor(amount) and overlay.set_amount_editor(nil,true))
assert(not input_root.focus, 'cancel stole focus from another menu')
amount.focus=true
input_root.active=false
assert(overlay.set_amount_editor(amount) and overlay.set_amount_editor(nil,true))
assert(not input_root.focus, 'inactive panel stole focus')
input_root.active=true
assert(overlay.set_amount_editor(amount) and overlay.set_amount_editor(nil))
assert(not input_root.focus, 'teardown took focus back before closing')
input_root.IsActivated=function() error('activation unreadable') end
assert(overlay.set_amount_editor(amount) and overlay.set_amount_editor(nil,true)
    and input_root.PWP_AmountEditor==nil and not input_root.focus,
    'unknown activation prevented reference cleanup or took focus')
input_root.IsActivated=nil
amount.focus=false
input_root.PWP_CancelRequested=true
assert(overlay.take_cancel(input_root), 'contract3 lost the CommonUI cancellation path')
for _, version in ipairs({0,1,'2'}) do
    input_root.PWP_InputContract, input_root.PWP_CancelRequested = version, true
    assert(not overlay.take_cancel(input_root) and not overlay.native_cancel,
        'unsupported input contract suppressed the raw fallback')
end
input_root.PWP_InputContract, input_root.PWP_CancelRequested = nil, nil
local unreadable = setmetatable({}, {__index=function() error('no native property') end})
assert(not overlay.take_cancel(unreadable) and not overlay.native_cancel)
local failed_ack = setmetatable({}, {
    __index=function(_,key)
        if key=='IsActivated' then return function() return true end end
        if key=='PWP_CancelBindingAttempted' then return true end
        return key=='PWP_InputContract' and 2 or true
    end,
    __newindex=function() error('write refused') end,
})
local pending_ack, acknowledged = overlay.take_cancel(failed_ack)
assert(pending_ack and not acknowledged, 'failed acknowledgement lost the pending Cancel')
local pending_value, fail_readback = true, false
local transient_ack = setmetatable({}, {
    __index=function(_,key)
        if key=='PWP_InputContract' then return 2 end
        if key=='IsActivated' then return function() return true end end
        if key=='PWP_CancelBindingAttempted' then return true end
        if fail_readback then fail_readback=false; error('readback unavailable') end
        return pending_value
    end,
    __newindex=function(_,_,value) pending_value=value; fail_readback=true end,
})
pending_ack, acknowledged = overlay.take_cancel(transient_ack)
assert(pending_ack and not acknowledged and pending_value==false)
pending_ack, acknowledged = overlay.take_cancel(transient_ack)
assert(not pending_ack and acknowledged, 'later verified clear could not acknowledge the Lua request')
api.game_ui_active = true
input_root.PWP_InputContract, input_root.PWP_CancelRequested = 2, true
assert(overlay.hide() and attached() == 0)
assert(not overlay.native_cancel, 'closed panel retained a native key claim')
assert(input_root.active==false, 'closed panel retained its consuming action binding')
assert(not overlay.take_cancel(input_root), 'closed panel dispatched a stale native request')
for _, throw_read in ipairs({false,true}) do
    api.game_ui_active=false
    assert(overlay.show())
    local before_only,before_focus=game_only,game_focus
    api.game_ui_active=nil
    if throw_read then
        setmetatable(api,{__index=function(_,key)
            if key=="game_ui_active" then error('UI state read failed') end
        end})
    end
    assert(overlay.hide() and attached()==0)
    assert(game_only==before_only and game_focus==before_focus,
        "unknown/throwing UI state authorized GameOnly or viewport focus")
    assert(pc.bShowMouseCursor==true,'unknown close hid the cursor')
    setmetatable(api,nil)
    api.game_ui_active=false
    assert(not overlay.watch_input(), 'unknown handoff was reclassified as a leak')
end
assert(game_only == 0 and game_focus == 0 and pc.bShowMouseCursor == true)
assert(not overlay.watch_input())
api.game_ui_active = false
assert(not overlay.watch_input() and game_only == 0, "watchdog stole vanilla handoff")
assert(not overlay.hide() and game_only == 0, "repeat close altered input")
pc.bShowMouseCursor = false
for _ = 1, 3 do
    assert(overlay.show() and attached() == 1)
    assert(overlay.hide() and attached() == 0)
end
assert(game_only == 3 and game_focus == 3)
assert(overlay.show())
for _, w in ipairs(all) do
    if w.attached then
        objects[w.path], w.dead, w.attached = nil, true, false
    end
end
assert(overlay.hide())
assert(stale == 0, "close dereferenced the previously retained dead widget")
assert(overlay.show())
overlay.reset()
assert(attached() == 0 and not overlay.open)
assert(stale == 0)

-- With a proven local viewport, repeated attached-root lookups must avoid
-- StaticFindObject. Replacement wrappers are reacquired, not cached by Lua.
api.has_viewport=function() return true end
api.local_player_controller=function() return pc end
api.unwrap=function(w) return w end
api.valid=function(w) return type(w)=='table' and not w.dead end
function lib:GetAllWidgetsOfClass(_,out,_,top)
    assert(top==true)
    out.FoundWidgets={}
    for _,w in ipairs(all) do
        if w.attached and not w.dead then out.FoundWidgets[#out.FoundWidgets+1]=w end
    end
end
local slow=0
StaticFindObject=function(path) slow=slow+1; return objects[path] end
assert(overlay.show())
slow=0
assert(overlay.host())
assert(overlay.host())
assert(slow==0, 'attached root still performs full object lookup')
assert(overlay.hide())
assert(overlay.show())
local refusing
for _, w in ipairs(all) do if w.attached then refusing = w end end
refusing.RemoveFromParent = function() return false end
assert(not overlay.hide() and attached() == 1)
assert(not overlay.show() and attached() == 1, "a failed detach allowed a duplicate panel")
refusing.RemoveFromParent = nil
assert(overlay.show() and attached() == 1)
assert(overlay.hide() and attached() == 0)

-- An incomplete/ambiguous viewport query is not a match. The existing exact
-- path lookup is independent proof and must supply its OWN current wrapper.
-- Exercise the real widget_lookup -> resolve_owned -> host chain, not a stub
-- returning nil from owned(). No native lifetime or timing claims are made.
assert(overlay.show())
local _, _, original_root = overlay.resolve_owned()
local owned_path = assert(original_root.path)
local enumerate, exact_find = lib.GetAllWidgetsOfClass, StaticFindObject
local previous, previous_tree, previous_canvas
local partial_reads, fallback_calls = 0, 0
local generation, constructed = overlay.generation, next_id
for _, mode in ipairs({'duplicate', 'nil-name', 'malformed-name', 'invalid-element'}) do
    -- Same identity on a later callback must not validate an earlier wrapper.
    if previous then
        previous.dead, previous_tree.dead, previous_canvas.dead = true, true, true
    end
    local fresh_canvas = setmetatable({kind='CanvasPanel', path=owned_path..'.FreshCanvas'}, {__index=methods})
    local fresh_tree = setmetatable({kind='WidgetTree', path=owned_path..'.FreshTree',
        RootWidget=fresh_canvas}, {__index=methods})
    local fresh_root = setmetatable({kind='UserWidget', path=owned_path,
        WidgetTree=fresh_tree}, {__index=methods})
    local candidate = setmetatable({kind='UserWidget', path=owned_path}, {
        __index=function(w, key)
            if key=='WidgetTree' then
                partial_reads=partial_reads+1
                error('partial viewport result was consumed')
            end
            return methods[key]
        end,
    })
    local other = setmetatable({GetFullName=function()
        if mode=='nil-name' then return nil end
        if mode=='malformed-name' then return 'not-a-full-name' end
        return 'UserWidget '..owned_path
    end, dead=mode=='invalid-element'}, getmetatable(candidate))
    lib.GetAllWidgetsOfClass=function(_, context, out, _, top)
        assert(context==pc and top==true)
        out[1], out[2] = candidate, other
    end
    StaticFindObject=function(path)
        assert(path==owned_path, 'fallback changed the exact owned path')
        fallback_calls=fallback_calls+1
        -- Poison the discarded query wrapper before returning another one.
        -- Even an IsValid call on it after this point must fail the test.
        candidate.dead, other.dead=true, true
        return fresh_root
    end
    local before=fallback_calls
    local canvas_now, tree_now, root_now=overlay.host()
    assert(fallback_calls==before+1, mode..': query did not fall back exactly once')
    assert(root_now==fresh_root and tree_now==fresh_tree and canvas_now==fresh_canvas,
        mode..': host accepted the query candidate or an older fallback wrapper')
    assert(partial_reads==0 and stale==0, mode..': discarded/stale wrapper was accessed')
    assert(overlay.generation==generation and next_id==constructed,
        mode..': fallback recreated the panel')
    previous, previous_tree, previous_canvas = fresh_root, fresh_tree, fresh_canvas
end
lib.GetAllWidgetsOfClass, StaticFindObject = enumerate, exact_find
assert(overlay.hide() and attached()==0)
assert(partial_reads==0 and stale==0)


-- Action-router capability requires verified activation, and closing must
-- deactivate before detach. A failed deactivation cannot authorize a new root.
overlay.reset()
local native_root, refuse_activate, refuse_deactivate, refuse_capture
StaticConstructObject=function(cls)
    local w=make(cls.kind)
    if cls.kind=='UserWidget' then
        native_root=w
        if refuse_capture then
            setmetatable(w, {
                __index=function(self,key)
                    if key=='GameMouseCaptureMode' then return 1 end
                    return methods[key]
                end,
                __newindex=function(self,key,value)
                    if key~='GameMouseCaptureMode' then rawset(self,key,value) end
                end,
            })
        end
        w.PWP_InputContract,w.PWP_CancelRequested,w.PWP_CancelBindingAttempted=2,false,true
        w.ActivateWidget=function(self)
            check(self)
            assert(self.GameMouseCaptureMode == 0,
                'native activation retained permanent mouse capture')
            if not refuse_activate then self.active=true end
        end
        w.DeactivateWidget=function(self)
            check(self)
            if not refuse_deactivate then self.active=false end
        end
        w.RemoveFromParent=function(self)
            assert(self.active~=true, 'active consuming binding detached before deactivation')
            self.attached=false
        end
    end
    return w
end
assert(overlay.show() and native_root.active and overlay.native_cancel)
local original_active=native_root.IsActivated
for _,unknown in ipairs({'nil','number','throw'}) do
    native_root.IsActivated=function()
        if unknown=='throw' then error('activation read failed') end
        if unknown=='number' then return 1 end
    end
    overlay.host()
    assert(not overlay.native_cancel, 'unknown activation claimed native input ownership')
end
native_root.IsActivated=original_active
refuse_deactivate=true
assert(not overlay.hide() and attached()==1)
assert(not overlay.show() and attached()==1, 'failed deactivation allowed another attachment')
refuse_deactivate=false
assert(overlay.show() and attached()==1 and overlay.native_cancel)
assert(overlay.hide() and attached()==0)
refuse_activate=true
assert(not overlay.show() and not overlay.native_cancel and attached()==0,
    'unsuccessful activation advertised an open native panel')
refuse_activate=false
assert(overlay.show() and overlay.native_cancel)
native_root.PWP_InputContract=3
setmetatable(native_root, {__index=methods, __newindex=function(self,key,value)
    if key=='PWP_AmountEditor' then error('editor reference write failed') end
    rawset(self,key,value)
end})
assert(overlay.hide() and not native_root.active and attached()==0,
    'failed editor reference clearing prevented deactivation/detachment')
assert(overlay.show())
overlay.reset()
assert(not native_root.active and attached()==0, 'reset left a consuming binding active')
refuse_capture=true
assert(not overlay.show() and not native_root.active and attached()==0,
    'refused cursor configuration activated an unclickable panel')
refuse_capture=false

-- A late asset answer must re-check the viewport before constructing anything.
package.loaded.overlay=nil
overlay=require("overlay")
local late, creates = nil, 0
function lib:Create()
    creates=creates+1
    local w=make('UserWidget')
    w.PWP_InputContract,w.PWP_CancelRequested,w.PWP_CancelBindingAttempted=2,false,true
    w.WidgetTree=make('WidgetTree')
    w.Root=make('CanvasPanel')
    w.WidgetTree.RootWidget=w.Root
    w.ActivateWidget=function(self) if not refuse_activate then self.active=true end end
    return w
end
overlay.mod_class=function(_,_,done) late=done end
assert(overlay.show())
api.has_viewport=function() return false end
late({})
assert(creates==0 and attached()==0 and not overlay.open,
    'late blueprint answer built/retained a panel without a local viewport')
api.has_viewport=function() return true end
overlay.reset()
-- Immediate and delayed activation failures must never fall through to a
-- replacement canvas or leave show() claiming success after hide().
package.loaded.overlay=nil
overlay=require("overlay")
refuse_activate=true
overlay.mod_class=function(_,_,done) done({}) end
local before_construct=next_id
assert(not overlay.show() and not overlay.open and attached()==0,
    'synchronous activation failure reopened a fallback panel')
assert(next_id==before_construct+3, 'failed native activation constructed a fallback')
overlay.reset()
package.loaded.overlay=nil
overlay=require("overlay")
refuse_activate=false
overlay.mod_class=function(_,_,done) late=done end
assert(overlay.show())
refuse_activate=true
late({})
assert(not overlay.open and attached()==0 and overlay.host()==nil,
    'delayed activation failure retained/rebuilt a panel')
refuse_activate=false
overlay.reset()
