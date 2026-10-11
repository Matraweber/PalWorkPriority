-- One-shot scoped import evidence. No writes or engine access. The installer
-- supplies authenticated captured bytes and a backup receipt checker; the caller
-- keeps BOTH legacy writers fenced throughout verification and native admission.
-- Byte equality alone is not proof of fsync, path identity or current authority.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_migration_guard.lua$'))
local Plan=dofile(root..'/settings_migration.lua')
local Store,Caps=require('store'),require('caps')
local M={}
local names={}
for _,base in ipairs({'priorities.txt','caps.txt'}) do
    for _,suffix in ipairs({'','.tmp','.pending','.bak'}) do names[#names+1]=base..suffix end
end
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    local expected={}
    assert(plain(o.files),'complete frozen recovery set required')
    for _,name in ipairs(names) do
        local bytes=o.files[name]
        assert(bytes==false or type(bytes)=='string' and #bytes<=8*1024*1024,'explicit bytes/absence required')
        expected[name]=bytes
    end
    for name in pairs(o.files)do assert(expected[name]~=nil,'unexpected recovery path')end
    local storage,guild,alias=o.storage,o.guild,o.runtime_guild
    local stream=o.stream
    if stream==nil then stream='limits' end
    assert(stream=='limits' or stream=='priorities','supported stream required')
    local owns=o.owns_key
    if stream=='priorities' then assert(type(owns)=='function','fresh Pal ownership provider required') end
    local source,backup,receipt,fence=o.read_source,o.read_backup,o.verify_receipt,o.fenced
    assert(type(source)=='function' and type(backup)=='function' and type(receipt)=='function'
        and type(fence)=='function','verified readers and writer fence required')
    -- Separate datafile instance: never replace the production module's fs.
    local Data=dofile(root..'/../Scripts/datafile.lua')
    Data.fs={open=function(name,mode)
        assert(mode=='rb')
        local bytes=expected[name];assert(bytes~=nil,'unexpected parser path')
        if bytes==false then return nil,'missing',2 end
        return {read=function()return bytes end,close=function()return true end}
    end}
    local p,pm=Data.read('priorities.txt',Store.decode_snapshot)
    local l,lm=Data.read('caps.txt',Caps.decode_snapshot)
    if not p or not l then return nil,'valid legacy selections required' end
    -- The first priority cutover admits only a fully scoped legacy selection.
    -- Never discard unknown/foreign rows or turn an empty claim list into an
    -- empty migrated save. These are candidate claims, re-proven under the
    -- startup fence below; neither parsing nor constructing the guard is proof.
    local membership,keys={},{}
    if stream=='priorities' then
        for key in pairs(p.data) do keys[#keys+1]=key end
        table.sort(keys)
        for _,key in ipairs(keys) do
            membership[#membership+1]={pal=key,storage=storage,guild=guild}
        end
    end
    local plan,why=Plan.plan{enabled=true,storage=storage,guild=guild,
        priorities=assert(Store.serialize_snapshot(p.data,p.baseline)),limits=assert(Caps.serialize_snapshot(l.data)),
        original_files={priorities=expected[pm.source],limits=expected[lm.source]},
        source_policy='validated-legacy-v1',membership=membership,
        limit_membership={{legacy_guild=alias,storage=storage,guild=guild}},
        limits_policy='explicit-alias-preserve-v1',max_payload_bytes=o.max_payload_bytes}
    if not plan then return nil,why end
    local body=plan.candidate.bodies[stream]
    local attempted,busy,poison=false,false,false
    local function check_fence()
        return not poison and fence()==true and not poison
    end
    local function matches(reader)
        for _,name in ipairs(names) do
            if not check_fence() then return false end
            local bytes,_,code=reader(name)
            if poison then return false end
            if expected[name]==false then
                if bytes~=nil or code~=2 then return false end
            elseif bytes~=expected[name] then return false end
        end
        return check_fence()
    end
    local m={}
    function m:body()return body end
    function m:verify(c,candidate)
        if busy then poison=true;return false end
        if attempted then return false end
        attempted,busy=true,true
        local ok,yes=pcall(function()
            if not plain(c) or c.storage~=storage or c.guild~=guild or c.stream~=stream
                or c.scope~='PWP-SCOPE-1:'..storage..':'..guild..':'..stream or c.authority~=true
                or candidate~=body or not check_fence() then return false end
            local context={}
            for _,key in ipairs({'storage','guild','scope','stream','session','incarnation','epoch','camp','authority'}) do
                local value=c[key]
                if value~=nil and type(value)~='string' and type(value)~='number' and type(value)~='boolean' then return false end
                context[key]=value
            end
            local function membership_current()
                if stream~='priorities' then return true end
                for _,key in ipairs(keys) do
                    local copy={};for k,v in pairs(context)do copy[k]=v end
                    if not check_fence() or owns(key,copy)~=true or not check_fence() then return false end
                end
                return check_fence()
            end
            -- Receipt provider authenticates durable completion/root identities.
            -- Give it copies; it cannot rewrite the protected expected strings.
            local files={};for k,v in pairs(expected)do files[k]=v end
            if not membership_current() or receipt(files)~=true or not check_fence() then return false end
            return matches(source) and matches(backup) and matches(source) and membership_current()
        end)
        busy=false
        return ok and yes==true and not poison
    end
    return m
end
return M
