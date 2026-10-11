-- Isolated composition boundary; NOT a native storage verifier.
-- Providers run fresh on the game thread, must not yield or retain wrappers.
-- verify_storage must prove the ACTIVE loaded storage, not directory existence.
local Scope=dofile((debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/save_authorization.lua$'))..'/save_scope.lua')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function text(s,n) return type(s)=='string' and #s>0 and #s<=n end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$')
        and s~=string.rep('0',32)
end
local function context(t)
    if not plain(t) then return end
    if not text(t.incarnation,256) or math.type(t.epoch)~='integer' or t.epoch<1
        or not text(t.world,512) or not guid(t.guild)
        or t.role~='authority' or t.ready~=true then return end
    -- Copy before another provider can mutate its source table.
    return {incarnation=t.incarnation,epoch=t.epoch,world=t.world,guild=t.guild}
end
local function same(a,b)
    return a and b and a.incarnation==b.incarnation and a.epoch==b.epoch
        and a.world==b.world and a.guild==b.guild
end
function M.new(options)
    options=options or {}
    local busy=false
    local function check(owner,token)
        if options.enabled~=true then return false end
        if type(options.read_context)~='function' or type(options.read_identity)~='function'
            or type(options.verify_storage)~='function' then return false end
        local before=context(options.read_context())
        if not before or before.incarnation~=token then return false end
        local i=options.read_identity()
        if not plain(i) or i.world~=before.world or i.loaded_status~='read'
            or i.loaded_world~=true or i.selected_status~='format_valid'
            or not guid(i.selected) then return false end
        -- Only the observed local-host route is described by this contract.
        -- Missing/conflicting/unreadable additional evidence never strengthens it.
        if i.autosave_status~='empty' and
            not (i.autosave_status=='format_valid' and i.autosave==i.selected) then return false end
        local storage=i.selected
        local scope=Scope.new(storage,before.guild,options.stream)
        if scope.key~=owner then return false end
        -- Give the provider a copy, never the captured comparison context.
        local proof=options.verify_storage({storage=storage,guild=before.guild,
            world=before.world,epoch=before.epoch,incarnation=before.incarnation})
        if not plain(proof) or proof.contract~='PWP-ACTIVE-STORAGE-1' or proof.active~=true
            or proof.storage~=storage or proof.guild~=before.guild or proof.world~=before.world
            or proof.epoch~=before.epoch or proof.incarnation~=before.incarnation then return false end
        return same(before,context(options.read_context()))==true
    end
    return function(owner,token)
        if busy then return false end
        busy=true
        local ok,result=pcall(check,owner,token)
        busy=false
        return ok and result==true
    end
end
return M
