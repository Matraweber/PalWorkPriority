-- Default-off bridge from checked native diagnostics to Membership.read_member.
-- No writer activation, IO, cached observations or retained engine objects.
-- Caller must serialize on the game thread and bind authorize to the real
-- lifecycle/epoch adapter. read_context must freshly execute the checked
-- Pair + LocalAuthority chain, returning the scalar shape below, never a cache.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_priority_live_reader.lua$'))
local Guild=dofile(root..'/settings_priority_guild_roster.lua')
local Parameters=dofile(root..'/settings_priority_parameter_roster.lua')
local World=dofile(root..'/settings_priority_world_lookup.lua')
local Membership=dofile(root..'/settings_priority_membership.lua')
local M={}
local fields={'storage','guild','alias','legacy_guild','world','world_address','state_address',
    'instance_address','manager_address','player_address','controller_address','player_state_address','guild_address'}
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    if not plain(a) or not plain(b)then return false end
    for k,v in pairs(a)do if not equal(v,rawget(b,k))then return false end end
    for k in pairs(b)do if rawget(a,k)==nil then return false end end
    return true
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    local read,engine,api=o.read_context,o.get_engine,o.api
    if type(read)~='function' or type(engine)~='function'
        or not plain(api) or type(api.cdo)~='function' or type(api.unwrap)~='function'
        or type(api.instance_key)~='function' then return nil,'invalid_providers' end
    -- Capture function identities, not the mutable options/API tables.
    api={cdo=api.cdo,unwrap=api.unwrap,instance_key=api.instance_key}
    local alias=o.runtime_guild
    local function snapshot(c)
        local raw=read();assert(plain(raw))
        local s={}
        for _,k in ipairs(fields)do
            local v=rawget(raw,k)
            if k:match('_address$')then assert(math.type(v)=='integer' and v>0)
            else assert(type(v)=='string' and #v>0 and #v<=512 and not v:find('%c'))end
            s[k]=v
        end
        assert(s.storage==c.storage and s.guild==c.guild and s.alias==alias and s.legacy_guild==alias)
        return s
    end
    local function observe(key,c)
        local before=snapshot(c)
        local function once()
            local expected=copy(before)
            local p
            local function resolve(native_id)
                assert(type(native_id)=='userdata','original reflected identity required')
                local expected_world=copy(before)
                local result=World.read(engine(),expected_world,native_id,api.cdo('/Script/Pal.Default__PalUtility'))
                assert(equal(expected_world,before));return result
            end
            local g=Guild.read(engine(),expected,api,function(k,native_id)
                if k~=key then return end
                assert(p==nil,'duplicate requested identity')
                -- Only the guild's native const-ref ID enters the world lookup.
                -- The singleton is callback-local, never a global enumeration.
                -- Parameters repeats the direct lookup and checks address,
                -- identity and group before returning scalars only.
                p=Parameters.read(function()return {resolve(native_id)}end,
                    api,before.guild,{[key]=true},resolve)
            end,key)
            assert(equal(expected,before) and g.complete==true)
            local present=false
            for _,k in ipairs(g.keys)do if k==key then present=true end end
            if not present then return {guild=g,missing=true}end
            return {guild=g,parameters=p}
        end
        local first,second=once(),once()
        local after=snapshot(c)
        assert(equal(before,after) and equal(first,second),'membership changed during read')
        local p=first.parameters
        if first.missing or not p or p.complete~=true or p.requested~=1 or p.observed~=1
            or p.matched~=1 or #p.records~=1 then return nil end
        local r=p.records[1]
        if r.key~=key or r.group~=c.guild or r.matches~=true or r.world_resolved~=true then return nil end
        return {complete=true,key=key,group=r.group,world_resolved=true,in_guild=true}
    end
    -- Membership enforces exact startup context, freshness before/after observe,
    -- reentry/mutation refusal, and terminal invalidation. It owns no native IO.
    return Membership.new{enabled=true,context=o.context,runtime_guild=alias,
        authorize=o.authorize,read_member=observe}
end
return M
