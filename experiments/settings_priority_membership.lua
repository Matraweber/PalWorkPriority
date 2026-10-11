-- Default-off pure preparatory owns_key adapter; no production wiring or IO.
-- new{enabled=true, context=<exact priority startup context>, runtime_guild=<immutable alias>, authorize=function,
--     read_member=function}. Providers are trusted, synchronous, non-yielding.
-- Each grant needs fresh authorization / membership / authorization. Nothing
-- here authenticates a dishonest provider or establishes native/world evidence.
-- Disposable context copies must remain unchanged; never retain engine wrappers
-- in providers. Any failed check, reentry, or revoke permanently fences this
-- adapter. Construct a new one for a new lifecycle; positives are never cached.
local Store = require('store')
local M = {}
local fields = {'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}
local result_fields = {'complete','key','group','world_resolved','in_guild'}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function copy(t, names)
    local r={};for _,k in ipairs(names) do r[k]=rawget(t,k) end;return r
end
local function exact(t, original, names)
    if not plain(t) then return false end
    for _,k in ipairs(names) do
        local v=rawget(t,k)
        if v~=original[k] or (type(v)=='number' and math.type(v)~=math.type(original[k])) then return false end
    end
    for k in next,t do if rawget(original,k)==nil then return false end end
    return true
end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$')~=nil and s~=string.rep('0',32)
end
local function text(s) return type(s)=='string' and #s>0 and #s<=256 and not s:find('%c') end
local function pal_key(k)
    return Store.durable_key(k) and #k==64 and k:match('^[0-9A-F]+$')~=nil
        and k:sub(33)~=string.rep('0',32)
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    local c=o.context
    if not plain(c) then return nil,'invalid_context' end
    local captured=copy(c,fields)
    if not exact(c,captured,fields) or not guid(c.storage) or not guid(c.guild)
        or c.stream~='priorities' or c.scope~='PWP-SCOPE-1:'..c.storage..':'..c.guild..':priorities'
        or not text(c.session) or not text(c.incarnation) or not text(c.camp)
        or math.type(c.epoch)~='integer' or c.epoch<1 or c.epoch>2147483646
        or c.authority~=true then return nil,'invalid_context' end
    local alias=o.runtime_guild
    if not text(alias) then return nil,'invalid_alias' end
    local authorize,read=o.authorize,o.read_member
    if type(authorize)~='function' or type(read)~='function' then return nil,'invalid_providers' end
    local busy,terminal,reason=false,false,nil
    local adapter={}
    local function deny(why)
        terminal=true;reason=reason or why;return false,reason
    end
    function adapter.owns_key(key,context)
        if busy then return deny('reentrant') end
        if terminal then return false,reason end
        if not exact(context,captured,fields) then return deny('context_mismatch') end
        if not pal_key(key) then return deny('invalid_key') end
        busy=true
        local ok,yes=pcall(function()
            local before,member,after=copy(captured,fields),copy(captured,fields),copy(captured,fields)
            local function unchanged()
                return not terminal and exact(context,captured,fields)
                    and exact(before,captured,fields) and exact(member,captured,fields)
                    and exact(after,captured,fields)
            end
            if authorize(before,alias)~=true or not unchanged() then return false end
            local read_ok,result=pcall(read,key,member)
            if not unchanged() then return false end
            -- Compare against a private all-scalar literal shape, including after
            -- the final callback (which could have retained the result table).
            local wanted={complete=true,key=key,group=captured.guild,world_resolved=true,in_guild=true}
            local accepted=read_ok and exact(result,wanted,result_fields)
            local authorized=authorize(after,alias)==true
            return authorized and unchanged() and accepted and exact(result,wanted,result_fields)
        end)
        busy=false
        if not ok then return deny('provider_failed') end
        if yes~=true or terminal then return deny('membership_unavailable') end
        return true,'current'
    end
    function adapter.revoke() return deny('revoked') end
    function adapter.status() return {state=terminal and 'revoked' or 'active',reason=reason} end
    return adapter
end
return M
