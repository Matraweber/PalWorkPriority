-- Native hit-test receiver -> scalar-only queued intent. No hover sampling,
-- retained UObject wrappers, or reads from a raw keybind thread.
local api = require('palapi')
local session = require('session')
local tree = require('ui_tree')
local lifecycle = require('stand_lifecycle')
local M = {path='/Game/Mods/PalWorkPriority/UI/WBP_StandInput.WBP_StandInput_C',
    events=0,queued=0,rejected=0,created=0,
    -- nil until the first lookup, then whether the receiver class was absent.
    asset_missing=nil}
local owned, serial, epoch, hooked, retry_at = {}, 0, session.epoch, false, -math.huge
local apply, allowed, key_event, selection_revision
local key_hooked = false
local keyboard_world, keyboard_ui, keyboard_generation
local helpers
pcall(function() helpers=require('UEHelpers') end)

local function valid(o)
    if o == nil then return false end
    local ok, yes = pcall(function() return o:IsValid() end)
    return ok and yes == true
end

local function text(value)
    if type(value)=='string' then return value end
    local ok, result=pcall(function() return value:ToString() end)
    if ok and type(result)=='string' then return result end
end

local function current()
    if epoch ~= session.epoch then owned, epoch = {}, session.epoch end
end

-- Same mounted-mod route as overlay.mod_class. Every caller is already on
-- the game thread; the generated class is returned only within this call.
local function load_class()
    local class=LoadAsset(M.path)
    if valid(class) then return class end
    local registry=api.cdo('/Script/AssetRegistry.Default__AssetRegistryHelpers')
    if not valid(registry) then return nil end
    local function name(value)
        if helpers and helpers.FindOrAddFName then return helpers.FindOrAddFName(value) end
        return FName(value,EFindName.FNAME_Add)
    end
    return registry:GetAsset({PackageName=name('/Game/Mods/PalWorkPriority/UI/WBP_StandInput'),
        AssetName=name('WBP_StandInput_C')})
end

function M.configure(fn, gate, keyboard, revision)
    apply, allowed, key_event, selection_revision = fn, gate, keyboard, revision
end

-- This runs inside our own Blueprint key event, on the game thread. The
-- native focus owner authorizes capture now; a raw global key never does.
local function receive_key(context)
    current()
    M.key_events=(M.key_events or 0)+1
    if not key_event or not allowed or not allowed() then return end
    local ok, token, world, ui, priority, name, focused = pcall(function()
        local widget=context:get()
        return text(widget.PWP_Target),widget.PWP_Epoch,widget.PWP_UiEpoch,
            widget.PWP_Priority,widget:GetFullName(),widget:HasAnyUserFocus()
    end)
    if not ok or focused~=true or world~=session.epoch or ui~=session.ui_epoch
        or type(priority)~='number' or priority%1~=0 or priority<0 or priority>13 then return end
    local record=owned[token]
    if not record or record.generation~=lifecycle.generation or record.world~=world or record.ui~=ui or record.name~=name then return end
    if priority==0 then priority=false end
    key_event(priority,record.cell,record.key,record.work,token)
end

local function receive(context)
    current()
    M.events=M.events+1
    if not apply or not allowed or not allowed() then M.rejected=M.rejected+1; return end
    local ok, token, world, ui, direction, name = pcall(function()
        local widget = context:get() -- native event context, used only here
        return text(widget.PWP_Target), widget.PWP_Epoch, widget.PWP_UiEpoch, widget.PWP_Direction, widget:GetFullName()
    end)
    if not ok or type(token)~='string' or world~=session.epoch or ui~=session.ui_epoch
        or (direction~=-1 and direction~=1) then M.rejected=M.rejected+1; return end
    local record = owned[token]
    if not record or record.generation~=lifecycle.generation or record.world~=world or record.ui~=ui or record.name~=name then
        M.rejected=M.rejected+1; return
    end
    keyboard_world,keyboard_ui=world,ui -- this native handled press requests focus
    keyboard_generation=lifecycle.generation
    -- Copy scalars, not a mutable binding record and never the event wrapper.
    if session.enqueue(apply, true, record.cell, record.key, record.work, token, direction,
        selection_revision and selection_revision() or 0) then
        M.queued=M.queued+1
    else M.rejected=M.rejected+1 end
end

local function ready()
    if hooked and key_hooked then return true end
    if os.clock()<retry_at then return false end
    retry_at=os.clock()+10
    local loaded, class = pcall(load_class)
    -- A clean "not found" from both routes is the missing pak, and the stand
    -- legend says so (ui.PAK_MISSING). A thrown lookup proves nothing either way.
    if loaded then M.asset_missing=not valid(class) end
    if not loaded or not valid(class) then M.last_error='asset: '..tostring(loaded and 'unavailable' or class); return false end
    if not hooked then
        local ok, why = pcall(RegisterHook, M.path..':PWP_Dispatch', receive)
        if not ok then M.last_error='hook: '..tostring(why) end
        hooked=ok
    end
    if not key_hooked then
        local ok, why=pcall(RegisterHook,M.path..':PWP_KeyDispatch',receive_key)
        if not ok then M.last_error='key hook: '..tostring(why) end
        key_hooked=ok
    end
    -- A receiver that loses the focus (the game's own stand cursor, the Y view
    -- switch) says so; forgetting the handed-over focus lets ui.pad_tick give
    -- it back on a controller. Optional: an older pak has no such function.
    if not M.focus_hooked then
        M.focus_hooked=pcall(RegisterHook,M.path..':PWP_FocusDispatch',function()
            M.focus_lost=(M.focus_lost or 0)+1
            keyboard_world=nil
        end)
    end
    return hooked and key_hooked
end

-- Called with the freshly resolved cell and the existing placement helper.
-- A missing/new asset makes mouse editing unavailable rather than falling back
-- to the known wrong-target raw-input route. Numbers and navigation still work.
function M.ensure(cell, cell_name, key, work, attach)
    current()
    if not ready() then return false end
    local name = cell_name..'|surface'
    local previous = owned[name]
    local surface, complete, hint = tree.find(cell, previous and previous.name, valid,
        previous and previous.hint)
    if not surface and not complete then return false end
    if not surface then
        local ok, made = pcall(function()
            local class = load_class()
            local pc = api.local_player_controller()
            local lib = api.cdo('/Script/UMG.Default__WidgetBlueprintLibrary')
            if not valid(class) or not valid(pc) or not valid(lib) then return nil end
            return lib:Create(pc,class,pc)
        end)
        if not ok or not valid(made) then M.last_error='create: '..tostring(ok and 'unavailable' or made); return false end
        surface = made
        local named, surface_name=pcall(function() return surface:GetFullName() end)
        if not named or type(surface_name)~='string' or #surface_name==0 then return false end
        if not attach(cell,surface) then
            M.last_error='attach: failed'
            pcall(function() surface:RemoveFromParent() end)
            return false
        end
        -- Retain its NAME even if arming fails, so retries cannot pile up
        -- hidden receiver widgets. The record is not eligible until armed.
        if previous and previous.token then owned[previous.token]=nil end
        previous={name=surface_name}
        owned[name]=previous
        M.created=M.created+1
    end
    local ok, why = pcall(function()
        -- 3 adds controller buttons (codes 11-13, 2026-10-22); 2 is the older
        -- pak, still accepted so a Lua update never strands keyboard editing.
        local contract=surface.PWP_Contract
        if contract~=2 and contract~=3 then error('stand input contract mismatch') end
        local same = previous and previous.key==key and previous.work==work
            and previous.generation==lifecycle.generation
            and previous.world==session.epoch and previous.ui==session.ui_epoch
            and text(surface.PWP_Target)==previous.token
        if same and surface.PWP_Epoch==session.epoch and surface.PWP_UiEpoch==session.ui_epoch
            and surface:GetVisibility()==0 then previous.hint=hint; return end
        local token
        if same then token=previous.token else serial=serial+1; token='pwp'..serial end
        -- Disable first; incomplete writes cannot leave an armed stale binding.
        surface.PWP_Target=''
        surface.PWP_Epoch=session.epoch
        surface.PWP_UiEpoch=session.ui_epoch
        if surface:SetVisibility(0)==false then error('stand input visibility failed') end
        surface.PWP_Target=token
        if text(surface.PWP_Target)~=token or surface.PWP_Epoch~=session.epoch
            or surface.PWP_UiEpoch~=session.ui_epoch then
            error(string.format('stand input binding failed: token=%s/%s epoch=%s/%s ui=%s/%s',
                tostring(text(surface.PWP_Target)),token,tostring(surface.PWP_Epoch),session.epoch,
                tostring(surface.PWP_UiEpoch),session.ui_epoch))
        end
        if previous and previous.token then owned[previous.token]=nil end
        local record={cell=cell_name,key=key,work=work,token=token,world=session.epoch,
            generation=lifecycle.generation,
            ui=session.ui_epoch,name=previous.name,hint=hint}
        owned[name],owned[token]=record,record
    end)
    if not ok then
        M.last_error='bind: '..tostring(why)
        if previous and previous.token then owned[previous.token]=nil end
        pcall(function() surface.PWP_Target=''; surface:SetVisibility(2) end)
    end
    return ok
end

function M.matches(cell, cell_name, key, work, token)
    current()
    local record=owned[token]
    if not record or record.cell~=cell_name or record.key~=key or record.work~=work
        or record.generation~=lifecycle.generation
        or record.world~=session.epoch or record.ui~=session.ui_epoch then return false end
    local surface=tree.find(cell,record.name,valid,record.hint)
    if not surface then return false end
    local ok, yes=pcall(function()
        return text(surface.PWP_Target)==token and surface.PWP_Epoch==session.epoch
            and surface.PWP_UiEpoch==session.ui_epoch and surface:GetVisibility()==0
    end)
    return ok and yes
end

function M.disable(cell,cell_name)
    current()
    local record=owned[cell_name..'|surface']
    if not record then return end
    if record.token then owned[record.token]=nil end
    local surface=tree.find(cell,record.name,valid,record.hint)
    if surface then pcall(function() surface.PWP_Target=''; surface:SetVisibility(2) end) end
end

function M.token(cell,cell_name,key,work)
    current()
    local record=owned[cell_name..'|surface']
    if record and record.token and M.matches(cell,cell_name,key,work,record.token) then return record.token end
end

-- Only an explicit navigation action may move keyboard focus. Never called
-- from painting or pointer hover, and no live surface escapes this callback.
function M.focus(cell,cell_name,key,work)
    local token=M.token(cell,cell_name,key,work)
    local record=token and owned[token]
    if not record then return false end
    local surface=tree.find(cell,record.name,valid,record.hint)
    if not surface then return false end
    local ok, focused=pcall(function() surface:SetKeyboardFocus(); return surface:HasAnyUserFocus() end)
    if ok and focused==true then
        keyboard_world,keyboard_ui=session.epoch,session.ui_epoch
        keyboard_generation=lifecycle.generation
        return true
    end
    return false
end

function M.keyboard_active()
    return keyboard_world==session.epoch and keyboard_ui==session.ui_epoch
        and keyboard_generation==lifecycle.generation
end

function M.report()
    return string.format('stand pointer: hook=%s key_hook=%s created=%d events=%d keys=%d queued=%d rejected=%d error=%s',
        tostring(hooked),tostring(key_hooked),M.created,M.events,M.key_events or 0,M.queued,M.rejected,tostring(M.last_error))
end

return M
