-- Development-only, pure record partitioning; no queue, IO, migration or deletion.
-- build(snapshot, scope, owners):
--   snapshot = {priorities={data=<raw store rows>,baseline=<boolean>},
--               limits={data=<raw caps rows>}}
--   scope = {storage=<nonzero 32-hex GUID>}
--   owners = dense list of {pal=<exact durable Pal key>,guild=<GUID>,storage=<GUID>}
-- A list preserves contradictory claims that a last-write-wins map would hide.
-- Duplicate claims (even identical), foreign storage and aliases in cap group
-- identity fail the entire operation. Absence of a claim NEVER proves deletion.
-- Future caller MUST supply freshly verified ownership and source-world binding.
-- This module only validates syntax/consistency; every result is verified=false.
-- Legacy data has no inferred world/guild: preserve it separately for explicit
-- future policy. Do not submit it to a guild queue or duplicate it across guilds.
-- Noncanonical (uppercase/mixed-case) GUID cap groups also stay in legacy:
-- raw spelling is preserved, NOT advertised as usable by canonical guild lookup.
-- Resolving those groups requires a separate explicit migration policy.
local Store=require('store')
local Caps=require('caps')
local Workdefs=require('workdefs')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function guid(s)
    if type(s)=='string' and #s==32 and s:match('^%x+$') and s~=string.rep('0',32) then
        return s:lower()
    end
end
local function fields(t,allowed)
    if not plain(t) then return false end
    for key in pairs(t) do if not allowed[key] then return false end end
    return true
end
local function integer(n,lo,hi)
    return type(n)=='number' and n%1==0 and n>=lo and n<=hi
end
local function legacy_guild(s)
    return type(s)=='string' and #s>0 and #s<=160 and not s:find('[^%w%-%*]')
end
local function records(baseline)
    return {priorities={data={},baseline=baseline},limits={data={}}}
end
local function formatted(part)
    -- Call the same formatters as full serialize(), never swap module M.data.
    local p,why=Store.serialize_snapshot(part.records.priorities.data,part.records.priorities.baseline)
    if not p then return nil,why end
    local c,err=Caps.serialize_snapshot(part.records.limits.data)
    if not c then return nil,err end
    part.payloads={priorities=p,limits=c} -- immutable strings, detached from rows
    return true
end
function M.build(snapshot,scope,owners)
    if not fields(scope,{storage=true}) or not guid(scope.storage) then return nil,'invalid scope' end
    if not fields(snapshot,{priorities=true,limits=true})
        or not fields(snapshot.priorities,{data=true,baseline=true})
        or not fields(snapshot.limits,{data=true})
        or type(snapshot.priorities.baseline)~='boolean'
        or not plain(snapshot.priorities.data) or not plain(snapshot.limits.data) then
        return nil,'invalid record snapshot'
    end
    if not plain(owners) then return nil,'invalid ownership list' end
    local storage=guid(scope.storage)
    local ownership,count={},0
    for index in pairs(owners) do
        if not integer(index,1,2147483647) then return nil,'invalid ownership list' end
        count=count+1
    end
    for i=1,count do
        local claim=owners[i]
        if not fields(claim,{pal=true,guild=true,storage=true}) or not Store.durable_key(claim.pal)
            or not guid(claim.guild) or guid(claim.storage)~=storage then
            return nil,'invalid or foreign ownership claim'
        end
        if ownership[claim.pal] then return nil,'duplicate or conflicting ownership claim' end
        ownership[claim.pal]=guid(claim.guild)
    end
    local result={verified=false,guilds={},legacy={verified=false,
        provenance='unassigned_priorities_and_legacy_cap_groups',records=records(snapshot.priorities.baseline)}}
    local function guild_part(guild)
        if not result.guilds[guild] then
            result.guilds[guild]={verified=false,scope={storage=storage,guild=guild},
                records=records(snapshot.priorities.baseline)}
        end
        return result.guilds[guild]
    end
    for pal,row in pairs(snapshot.priorities.data) do
        if not Store.durable_key(pal) or not plain(row) then return nil,'invalid priority record' end
        local copied={}
        for work,priority in pairs(row) do
            if not integer(work,1,64) or (priority~=false and not integer(priority,1,Store.MAX)) then
                return nil,'invalid priority record'
            end
            copied[work]=priority
        end
        local part=ownership[pal] and guild_part(ownership[pal]) or result.legacy
        part.records.priorities.data[pal]=copied
    end
    local aliases={}
    for guild,works in pairs(snapshot.limits.data) do
        if not legacy_guild(guild) or not plain(works) then return nil,'invalid limit group' end
        local canonical=guid(guild)
        if canonical and aliases[canonical] then return nil,'ambiguous limit guild aliases' end
        if canonical then aliases[canonical]=true end
        local copied={}
        for work,items in pairs(works) do
            if type(work)~='string' or not Workdefs.is_known(work) or not plain(items) then
                return nil,'invalid limit record'
            end
            local row={};copied[work]=row
            for item,ceiling in pairs(items) do
                if (ceiling~=false and not integer(ceiling,1,Caps.MAX_CEILING))
                    or not Caps.valid_rule(work,item,ceiling==false and 1 or ceiling) then
                    return nil,'invalid limit record'
                end
                row[item]=ceiling
            end
        end
        local part=canonical and guild==canonical and guild_part(canonical) or result.legacy
        -- Preserve original group spelling and '*', not an inherited effective view.
        part.records.limits.data[guild]=copied
    end
    for _,part in pairs(result.guilds) do
        local ok,why=formatted(part);if not ok then return nil,why end
    end
    local ok,why=formatted(result.legacy);if not ok then return nil,why end
    return result
end
return M
