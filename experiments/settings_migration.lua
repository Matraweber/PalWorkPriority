-- Pure opt-in migration PLAN, not authority, initialization, backup or activation.
-- plan{enabled=true, storage=<canonical GUID>, guild=<canonical GUID>,
--      priorities=<canonical Store snapshot bytes>, limits=<canonical Caps bytes>,
--      original_files={priorities=<exact original file bytes>,limits=<same>},
--      source_policy=nil|"validated-legacy-v1",
--      membership={<pal,storage,guild> claims},
--      limit_membership={<legacy_guild,storage,guild> claims},
--      limits_policy=nil|"canonical-guild-only-v1"|"preserve-unassigned-v1"
--                    |"explicit-alias-preserve-v1",
--      max_payload_bytes=65536|...|262144}
-- Claims are dense lists, not last-write-wins maps: duplicates/contradictions
-- fail. A trusted local-host caller must prove every claim from fresh evidence;
-- this planner only validates syntax/consistency. Claims for foreign worlds
-- fail; other guilds and absent claims NEVER imply deletion or target membership.
-- Limit claims select canonical groups or explicitly proven decimal A-B-C-D
-- aliases from palapi.guild_of. Signed/unsigned fields must encode the supplied
-- canonical guild exactly; syntax equivalence does NOT establish live ownership.
-- No wildcard adoption, case normalization, arbitrary group renaming, config inheritance,
-- item-controller conversion, or flattening of effective limits is supported.
-- "canonical-guild-only-v1" (default) rejects all noncanonical/legacy groups.
-- "preserve-unassigned-v1" explicitly permits preserving those groups unchanged
-- in the remainder/original; they do NOT enter the candidate, even as defaults.
-- "explicit-alias-preserve-v1" additionally renames ONLY explicitly claimed
-- decimal GUID groups to their proven canonical guild. Conflicting selected rows
-- fail even if values agree; there is no implicit override/merge precedence.
-- Unknown work/rule formats and aliased guild groups reject under every policy.
-- Canonical snapshot bodies are distinct from original_files: originals must be
-- captured from the selected durable files, including any PWP-DATA envelope.
-- Default policy requires exact canonical bytes. Explicit validated-legacy-v1
-- accepts old comments/order only if the real decoder and canonical serializer
-- produce the supplied snapshot exactly. Original bytes remain untouched.
-- The planner cannot prove which file was read or recovery-set selection; the caller
-- must capture file identities and preserve other recovery files separately.
-- The caller must durably retain BOTH exact original file byte strings, recheck source
-- equality, establish positive missing journal state, validate current authority,
-- and separately approve activation/coverage. Never write the remainder over the
-- legacy source: mixed old/new ownership, rollback and cutover need coordination.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_migration.lua$'))
local Partition=dofile(root..'/save_partition.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Store,Caps=require('store'),require('caps')
local M={}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function fields(t,allowed)
    if not plain(t) then return false end
    for k in pairs(t) do if not allowed[k] then return false end end
    return true
end
local function guid(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$')~=nil and s~=string.rep('0',32)
end
local function alias_guid(s)
    if guid(s) then return s end
    if type(s)~='string' or #s>160 then return end
    local a,b,c,d=s:match('^(%-?%d+)%-(%-?%d+)%-(%-?%d+)%-(%-?%d+)$')
    if not a then return end
    local out={}
    for i,part in ipairs({a,b,c,d}) do
        local n=math.tointeger(tonumber(part))
        if not n or n < -2147483648 or n > 4294967295 or tostring(n)~=part then return end
        out[i]=string.format('%08x',n & 0xffffffff)
    end
    local canonical=table.concat(out)
    if guid(canonical) then return canonical end
end
local function dense(t)
    if not plain(t) then return end
    local count=0
    for k in pairs(t) do
        if math.type(k)~='integer' or k<1 or k>4096 then return end
        count=count+1
    end
    for i=1,count do if rawget(t,i)==nil then return end end
    return count
end
local function copy(t)
    if type(t)~='table' then return t end
    local out={};for k,v in pairs(t) do out[k]=copy(v) end;return out
end
local function canonical(bytes,module)
    if type(bytes)~='string' or #bytes>8*1024*1024 then return nil,'invalid source bytes' end
    local decoded,why=module.decode_snapshot(bytes)
    if not decoded then return nil,why end
    local body=module.serialize_snapshot(decoded.data,decoded.baseline)
    if body~=bytes then return nil,'source must be exact canonical snapshot bytes' end
    return decoded
end
-- Validate the existing datafile v1 envelope without doing IO or reconstructing
-- the original. FNV here is the legacy integrity check, not an ownership proof.
local function original_matches(raw,body,module,policy)
    if type(raw)~='string' or #raw>8*1024*1024 then return false end
    if raw==body then return true end
    local payload=raw
    local reserved='^%s*#%s*[Pp][Ww][Pp]%-[Dd][Aa][Tt][Aa]'
    if raw:match(reserved) then
        local gen,size,sum
        gen,size,sum,payload=raw:match('^# PWP%-DATA 1 (%d+) (%d+) (%x+)\n(.*)$')
        gen,size=math.tointeger(tonumber(gen)),math.tointeger(tonumber(size))
        if not gen or gen<1 or not size or not payload or #payload~=size then return false end
        local h=2166136261
        for i=1,#payload do h=((h ~ payload:byte(i))*16777619) & 0xffffffff end
        if string.format('%08x',h)~=sum then return false end
    end
    -- A misplaced/nested/unsupported generation marker is not an ignorable comment.
    for line in (payload..'\n'):gmatch('(.-)\n') do
        if line:match(reserved) then return false end
    end
    if payload==body then return true end
    if policy~='validated-legacy-v1' then return false end
    local decoded=module.decode_snapshot(payload)
    return decoded~=nil and module.serialize_snapshot(decoded.data,decoded.baseline)==body
end
function M.plan(o)
    if not fields(o,{enabled=true,storage=true,guild=true,priorities=true,limits=true,
        membership=true,limit_membership=true,limits_policy=true,max_payload_bytes=true,original_files=true,source_policy=true})
        or o.enabled~=true or not guid(o.storage) or not guid(o.guild) then return nil,'invalid opt-in/scope' end
    local max=o.max_payload_bytes
    if max==nil then max=65536 end
    if math.type(max)~='integer' or max<65536 or max>262144 then return nil,'invalid payload capacity' end
    if o.source_policy~=nil and o.source_policy~='validated-legacy-v1' then return nil,'unsupported source policy' end
    local policy=o.limits_policy
    if policy==nil then policy='canonical-guild-only-v1' end
    if policy~='canonical-guild-only-v1' and policy~='preserve-unassigned-v1'
        and policy~='explicit-alias-preserve-v1' then return nil,'unsupported limits policy' end
    local count,limit_count=dense(o.membership),dense(o.limit_membership)
    if not count or not limit_count then return nil,'bounded dense membership lists required' end
    local claims,limit_claims,owners,groups={},{},{},{}
    for i=1,count do
        local claim=o.membership[i]
        if not fields(claim,{pal=true,storage=true,guild=true}) or not Store.durable_key(claim.pal)
            or not guid(claim.storage) or claim.storage~=o.storage or not guid(claim.guild) then
            return nil,'invalid/foreign Pal claim'
        end
        if owners[claim.pal] then return nil,'duplicate/ambiguous Pal claim' end
        owners[claim.pal]=claim.guild;claims[i]=copy(claim)
    end
    for i=1,limit_count do
        local claim=o.limit_membership[i]
        if not fields(claim,{legacy_guild=true,storage=true,guild=true})
            or not guid(claim.guild) or alias_guid(claim.legacy_guild)~=claim.guild
            or not guid(claim.storage) or claim.storage~=o.storage then return nil,'invalid/foreign limit claim' end
        if claim.legacy_guild~=claim.guild and policy~='explicit-alias-preserve-v1' then return nil,'explicit alias policy required' end
        if groups[claim.legacy_guild] then return nil,'duplicate/ambiguous limit claim' end
        groups[claim.legacy_guild]=claim.guild;limit_claims[i]=copy(claim)
    end
    local priorities,why=canonical(o.priorities,Store);if not priorities then return nil,why end
    local limits,err=canonical(o.limits,Caps);if not limits then return nil,err end
    if not fields(o.original_files,{priorities=true,limits=true})
        or not original_matches(o.original_files.priorities,o.priorities,Store,o.source_policy)
        or not original_matches(o.original_files.limits,o.limits,Caps,o.source_policy) then
        return nil,'exact original files must match canonical snapshots (raw or checked v1 envelope)'
    end
    for group in pairs(limits.data) do
        if not guid(group) and policy=='canonical-guild-only-v1' then
            return nil,'legacy/wildcard limits require explicit preservation policy'
        end
    end
    -- Reuse the existing strict partitioner for row checks and alias ambiguity.
    local parts,problem=Partition.build({priorities={data=priorities.data,baseline=priorities.baseline},
        limits={data=limits.data}},{storage=o.storage},claims)
    if not parts then return nil,problem end
    local own=parts.guilds[o.guild]
    local selected_p=own and copy(own.records.priorities.data) or {}
    local selected_l={}
    local selected_groups={}
    for group,rows in pairs(limits.data) do
        if groups[group]==o.guild then
            selected_groups[group]=true
            selected_l[o.guild]=selected_l[o.guild] or {}
            for work,items in pairs(rows) do
                local target=selected_l[o.guild][work] or {};selected_l[o.guild][work]=target
                for item,value in pairs(items) do
                    if target[item]~=nil then return nil,'ambiguous selected limit aliases' end
                    target[item]=value
                end
            end
        end
    end
    local retained_p,retained_l={},{}
    for pal,rows in pairs(priorities.data) do if owners[pal]~=o.guild then retained_p[pal]=copy(rows) end end
    for group,rows in pairs(limits.data) do if not selected_groups[group] then retained_l[group]=copy(rows) end end
    local body_p=assert(Store.serialize_snapshot(selected_p,priorities.baseline))
    local body_l=assert(Caps.serialize_snapshot(selected_l))
    local payloads={}
    for stream,body in pairs({priorities=body_p,limits=body_l}) do
        local codec=Codec.new{storage=o.storage,guild=o.guild,stream=stream,max_payload_bytes=max}
        local payload,error=codec.encode(body)
        if not payload then return nil,error end
        payloads[stream]=payload
    end
    local remainder_p=assert(Store.serialize_snapshot(retained_p,priorities.baseline))
    local remainder_l=assert(Caps.serialize_snapshot(retained_l))
    local selected_count={priorities=assert(Store.decode_snapshot(body_p)).count,limits=assert(Caps.decode_snapshot(body_l)).count}
    local remainder_count={priorities=assert(Store.decode_snapshot(remainder_p)).count,limits=assert(Caps.decode_snapshot(remainder_l)).count}
    assert(selected_count.priorities+remainder_count.priorities==priorities.count
        and selected_count.limits+remainder_count.limits==limits.count,'migration row conservation')
    return {contract='PWP-MIGRATION-PLAN-1',verified=false,authorized=false,activation_allowed=false,
        scope={storage=o.storage,guild=o.guild},
        candidate={bodies={priorities=body_p,limits=body_l},payloads=payloads,counts=selected_count},
        preserved={bodies={priorities=remainder_p,limits=remainder_l},counts=remainder_count,
            replace_legacy_source=false},
        backup={required=true,verified=false,original={priorities=o.original_files.priorities,limits=o.original_files.limits},
            exact_source_comparison_required=true,retain_original=true},
        evidence={membership=claims,limit_membership=limit_claims,limits_policy=policy,source_policy=o.source_policy or 'exact',
            source_counts={priorities=priorities.count,limits=limits.count},
            source_bytes={priorities=#o.priorities,limits=#o.limits},
            membership_verified=false,baseline_coverage_verified=false,
            baseline_marker_preserved=priorities.baseline,limit_semantics='legacy-work-type-groups'}}
end
return M
