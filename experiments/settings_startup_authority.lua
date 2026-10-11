-- Default-off, local-only settings_startup authorize adapter. No IO or engine access.
-- new{enabled=true, context=<startup captured context>, runtime_guild=<exact alias>,
--     get_epoch=function, read_evidence=function, read_authority=function}
-- Providers are trusted, synchronous, non-yielding and serialized on the game
-- thread. get_epoch follows save_local_binding; read_evidence calls Pair.read
-- with freshly resolved engine/getters; read_authority calls LocalAuthority.read
-- with a fresh engine and the supplied scalar context. Never cache wrappers in
-- provider closures. These contracts cannot authenticate a dishonest provider.
-- Optional operation_context=true passes one fresh plain context to both evidence
-- reads ONLY within authorize. A trusted provider may put a callback-local CDO in
-- it, never observed world/guild results. No provider may retain the context or its
-- wrappers. It is emptied and closed on every exit, including immediate revoke or
-- reentry; providers must check closed after native calls before storing/using it.
-- Default providers still receive exactly zero arguments and resolve as before.
-- authorize(context, alias) returns boolean, reason; pass it directly to startup.
-- revoke() permanently fences this instance; wire lifecycle invalidation to it.
-- status() returns diagnostics, never a cached grant. Construct a new adapter for
-- a new startup. No native ownership, migration proof or durability is implied.
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function integer(n) return math.type(n)=='integer' and n>0 end
local function text(s,n) return type(s)=='string' and #s>0 and #s<=n and not s:find('%c') end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$')~=nil and s~=string.rep('0',32)
end
local function alias_guid(s)
    if not text(s,160) then return end
    local a,b,c,d=s:match('^(%-?%d+)%-(%-?%d+)%-(%-?%d+)%-(%-?%d+)$')
    if not a then return end
    local hex={}
    for _,word in ipairs({a,b,c,d}) do
        local n=tonumber(word)
        if math.type(n)~='integer' or n< -2147483648 or n>4294967295
            or tostring(n)~=word then return end
        hex[#hex+1]=string.format('%08x',n%4294967296)
    end
    return table.concat(hex)
end
local context_keys={'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}
local addresses={'world_address','state_address','instance_address','manager_address'}
local snapshot_keys={'epoch','token','world','storage','guild','alias','autosave',
    'world_address','state_address','instance_address','manager_address'}
local function copy(t,keys)
    local out={};for _,k in ipairs(keys) do out[k]=t[k] end;return out
end
local function same(a,b,keys)
    if not plain(a) or not plain(b) then return false end
    for _,k in ipairs(keys) do if a[k]~=b[k] then return false end end
    return true
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    local c=o.context
    if not plain(c) or not guid(c.storage) or not guid(c.guild)
        or (c.stream~='limits' and c.stream~='priorities')
        or c.scope~='PWP-SCOPE-1:'..c.storage..':'..c.guild..':'..c.stream
        or not text(c.session,256) or not text(c.incarnation,256) or not text(c.camp,256)
        or not integer(c.epoch) or c.epoch>2147483646 or c.authority~=true
        or not text(o.runtime_guild,160) then return nil,'invalid_context' end
    local get_epoch,read,authority=o.get_epoch,o.read_evidence,o.read_authority
    if o.operation_context~=nil and type(o.operation_context)~='boolean' then return nil,'invalid_providers' end
    local scoped=o.operation_context==true
    if type(get_epoch)~='function' or type(read)~='function' or type(authority)~='function' then
        return nil,'invalid_providers'
    end
    c=copy(c,context_keys)
    local alias=o.runtime_guild
    local busy,terminal,reason,bound=false,false,nil,nil
    local operation
    local function clear_operation(op)
        op=op or operation
        if op then
            for k in next,op do rawset(op,k,nil)end
            rawset(op,'closed',true)
            if operation==op then operation=nil end
        end
    end
    local api={}
    local function deny(why)
        terminal=true;reason=reason or why;bound=nil
        clear_operation()
        return false,reason
    end
    local function epoch()
        local e=get_epoch()
        if terminal or not plain(e) or e.available~=true or e.supported~=true
            or not integer(e.epoch) or e.epoch~=c.epoch or type(e.token)~='function' then return end
        return {epoch=e.epoch,token=e.token}
    end
    local function snapshot(op)
        local e=epoch();if not e then return end
        local p
        if scoped then p=read(op)else p=read()end
        if terminal or not plain(p) or p.status~='context_agrees' or p.agrees~=true
            or p.role~=3 or p.dedicated~=false or p.directory~=c.storage
            or p.identity_loaded_status~='read' or p.identity_loaded_world~=true
            or p.identity_selected_status~='format_valid' or p.identity_selected~=c.storage
            or not text(p.world,512) then return end
        if not (p.identity_autosave_status=='empty' and p.identity_autosave==nil)
            and not (p.identity_autosave_status=='format_valid' and p.identity_autosave==c.storage) then return end
        local s={epoch=e.epoch,token=e.token,world=p.world,storage=p.directory,autosave=p.identity_autosave}
        for _,k in ipairs(addresses) do if not integer(p[k]) then return end;s[k]=p[k] end
        local expected=copy(s,addresses);expected.world=s.world
        local a=authority(expected)
        -- Providers get a disposable copy, and mutation is not accepted as proof.
        if terminal or not same(expected,s,addresses) or expected.world~=s.world
            or not plain(a) or a.authority_status~='read' or a.authority~=true
            or a.guild_status~='format_valid' or a.guild~=c.guild
            or a.world_address~=s.world_address or a.state_address~=s.state_address
            or a.instance_address~=s.instance_address
            or alias_guid(a.legacy_guild)~=a.guild
            or (alias~=a.legacy_guild and alias~=a.guild) then return end
        s.guild,s.alias=a.guild,a.legacy_guild
        local after=epoch()
        if not after or after.epoch~=e.epoch or after.token~=e.token then return end
        return s
    end
    function api.authorize(context,runtime_guild)
        if busy then return deny('reentrant') end
        if terminal then return false,reason end
        if not same(context,c,context_keys) or runtime_guild~=alias then return deny('context_mismatch') end
        busy=true
        local op=scoped and {} or nil
        operation=op
        local ok,yes=pcall(function()
            local first=snapshot(op)
            if not first or terminal then return false end
            local last=snapshot(op)
            if terminal or not same(first,last,snapshot_keys)
                or (bound and not same(bound,last,snapshot_keys))
                or not same(context,c,context_keys) then return false end
            bound=last -- only allowlisted scalars and the lifecycle function token
            return true
        end)
        clear_operation(op)
        busy=false
        if not ok then return deny('provider_failed') end
        if yes~=true or terminal then return deny('evidence_changed') end
        return true,'current'
    end
    function api.revoke() return deny('revoked') end
    function api.status()
        return {state=terminal and 'revoked' or bound and 'bound' or 'idle',reason=reason}
    end
    return api
end
return M
