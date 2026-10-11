-- Pure opt-in adapter. No engine access, IO, timers, or wrapper retention.
-- See save_local_binding.md for trusted callback and native admission contracts.
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function integer(n) return math.type(n)=='integer' and n>0 end
local function label(s,n) return type(s)=='string' and #s>0 and #s<=n and s:match('^[%w_:%-]+$')~=nil end
local function guid(s) return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$')~=nil and s~=string.rep('0',32) end
local function scalar(s) return integer(s) or label(s,128) end
local keys={'epoch','token','world','storage','guild','world_address','state_address','instance_address','manager_address','autosave'}
local function same(a,b)
    if not a or not b then return false end
    for _,k in ipairs(keys) do if a[k]~=b[k] then return false end end
    return true
end
function M.new(options)
    options=options or {}
    -- Capture once. Later writes to the caller's options cannot redirect binding.
    local namespace,boot,stream,rootcap=options.namespace,options.boot,options.stream,options.rootcap
    local get_epoch,read,authority,bind,discard=options.get_epoch,options.read_evidence,
        options.read_authority,options.bind,options.discard
    -- Legacy callbacks allocate only an inert registry entry. Explicit opt-in
    -- permits a revocable native owner CLAIM, never a job reservation or IO.
    -- The bind adapter must track that claim for lifetime discard before return.
    local binding_kind=options.binding_kind
    if binding_kind==nil then binding_kind='inert' end
    local limit=options.limit or 256
    local configured=options.enabled==true and label(namespace,64) and label(boot,64)
        and (stream=='priorities' or stream=='limits') and scalar(rootcap)
        and (binding_kind=='inert' or binding_kind=='revocable-owner')
        and integer(limit) and limit<=256
    for _,fn in ipairs({get_epoch or false,read or false,authority or false,bind or false,discard or false}) do
        configured=configured and type(fn)=='function'
    end
    local busy,poison,terminal=false,false,false
    local high,floor,serial=0,0,0
    local pending,captured,active,active_evidence,incarnation
    local api={}
    local function result(status) return {status=status,authorized=false} end
    local function close(reason,fatal)
        pending,captured=nil,nil
        floor=math.max(floor,high)
        local old=active
        active,active_evidence,incarnation=nil,nil,nil
        if fatal then terminal=true end
        if old~=nil then
            local ok,value=pcall(discard,old)
            if not ok or value~=true then terminal=true;reason='discard_uncertain' end
        end
        return result(reason)
    end
    local function epoch()
        local e=get_epoch()
        if not plain(e) or e.available~=true or e.supported~=true or not integer(e.epoch)
            or e.epoch>2147483647 or type(e.token)~='function' then return end
        if e.epoch<high or e.epoch<=floor then return end
        high=e.epoch
        return {epoch=e.epoch,token=e.token}
    end
    local function snapshot()
        local e=epoch()
        if not e then return end
        local p=read()
        if not plain(p) or p.status~='context_agrees' or p.agrees~=true
            or p.role~=3 or p.dedicated~=false or not guid(p.directory)
            or p.identity_loaded_status~='read' or p.identity_loaded_world~=true
            or p.identity_selected_status~='format_valid' or p.identity_selected~=p.directory
            or type(p.world)~='string' or #p.world==0 or #p.world>512 or p.world:find('%c') then return end
        if not (p.identity_autosave_status=='empty' and p.identity_autosave==nil)
            and not (p.identity_autosave_status=='format_valid' and p.identity_autosave==p.directory) then return end
        local s={epoch=e.epoch,token=e.token,world=p.world,storage=p.directory,autosave=p.identity_autosave}
        for _,k in ipairs({'world_address','state_address','instance_address','manager_address'}) do
            if not integer(p[k]) then return end
            s[k]=p[k]
        end
        -- Separate copy; callback mutation cannot alter our evidence.
        local a=authority({world=s.world,world_address=s.world_address,state_address=s.state_address,
            instance_address=s.instance_address,manager_address=s.manager_address})
        if not plain(a) or a.authority_status~='read' or a.authority~=true
            or a.guild_status~='format_valid' or not guid(a.guild)
            or a.world_address~=s.world_address or a.state_address~=s.state_address
            or a.instance_address~=s.instance_address then return end
        s.guild=a.guild
        local after=epoch()
        if not after or after.epoch~=e.epoch or after.token~=e.token then return end
        return s
    end
    local function guarded(fn)
        if busy then poison=true;return result('reentrant') end
        if not configured then return result('unconfigured') end
        if terminal then return result('terminal') end
        busy,poison=true,false
        local ok,out=pcall(fn)
        if not ok then out=close('read_failed',false) end
        if poison then out=close('reentrant',true) end
        busy=false
        return out
    end
    function api.sample()
        return guarded(function()
            if active then
                if not same(active_evidence,snapshot()) or poison then return close('evidence_changed',false) end
                return result('already_bound')
            end
            pending,captured=nil,nil
            if serial>=limit then return close('capacity',true) end
            local s=snapshot()
            if not s or poison then return close('evidence_unavailable',false) end
            serial=serial+1
            incarnation=boot..':'..serial
            captured=s
            pending={status='candidate',authorized=false,namespace=namespace,storage=s.storage,
                guild=s.guild,stream=stream,epoch=s.epoch,incarnation=incarnation}
            return pending
        end)
    end
    function api.bind(candidate)
        return guarded(function()
            if candidate==nil or candidate~=pending or not captured then return result('invalid_candidate') end
            local s=captured
            pending,captured=nil,nil -- consumed even on failure
            if not same(s,snapshot()) or poison then return close('evidence_changed',false) end
            local request={namespace=namespace,worldguid=s.storage,guild=s.guild,stream=stream,
                epoch=s.epoch,incarnation=incarnation}
            local ok,id=pcall(bind,rootcap,request)
            -- Both contracts forbid journal access/recovery/update admission.
            -- revocable-owner may already exclude another owner, but that claim
            -- is NOT authorization. Fresh postchecks still precede any grant.
            if not ok or not integer(id) then return close('bind_uncertain',true) end
            active=id -- register for cleanup before any further callback can throw
            if poison or not same(s,snapshot()) then return close('evidence_changed',false) end
            active_evidence=s
            return {status='bound',authorized=true,binding=id,namespace=namespace,storage=s.storage,
                guild=s.guild,stream=stream,epoch=s.epoch,incarnation=incarnation}
        end)
    end
    function api.check(id)
        return guarded(function()
            if id~=active or active==nil then return result('invalid_binding') end
            if not same(active_evidence,snapshot()) or poison then return close('evidence_changed',false) end
            return {status='current',authorized=true,binding=active}
        end)
    end
    function api.revoke()
        if busy then poison=true;return result('reentrant') end
        if not configured then return result('unconfigured') end
        busy=true
        local out=close('revoked',false)
        if poison then terminal=true;out=result('reentrant') end
        busy=false
        return out
    end
    return api
end
return M
