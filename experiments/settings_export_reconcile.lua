-- Pure journal-to-legacy reconciliation proposal. No IO, authority or cutover.
-- Pal claims must cover historic deletions as well as current journal rows.
-- This module validates claims; it cannot prove their completeness/ownership.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/settings_export_reconcile.lua$'))
local Migration=dofile(root..'/settings_migration.lua')
local Codec=dofile(root..'/save_settings_codec.lua')
local Store,Caps=require('store'),require('caps')
local M={}
-- Leading comment lines and the rows after them. A comment among the rows,
-- or text after the last newline, has no canonical form.
local function parts(text)
    if text~='' and text:sub(-1)~='\n' then return nil end
    local header,rows={},{}
    for line in text:gmatch('([^\n]*)\n') do
        if line:sub(1,1)=='#' then
            if #rows>0 then return nil end
            header[#header+1]=line
        else rows[#rows+1]=line end
    end
    return header,table.concat(rows,'\n')
end
local function canonical(body,module)
    if type(body)~='string' or #body>8*1024*1024 then return nil,'invalid body' end
    local decoded,why=module.decode_snapshot(body)
    if not decoded then return nil,why end
    local again=module.serialize_snapshot(decoded.data,decoded.baseline)
    if again==body then return decoded end
    -- Compare what was decoded, not the comment bytes: a journal written
    -- before the caps.txt header changed (2026-10-28) holds the same rules
    -- under the old header. Rows must still be byte-canonical, the header
    -- the same number of lines, and the decoded data equal.
    local h1,r1=parts(body)
    local h2,r2=parts(again or '')
    if not h1 or not h2 or #h1~=#h2 or r1~=r2 then return nil,'noncanonical body' end
    local redecoded=module.decode_snapshot(again)
    if not redecoded or redecoded.count~=decoded.count
        or redecoded.baseline~=decoded.baseline then return nil,'noncanonical body' end
    return decoded
end
function M.plan(o)
    if type(o)~='table' or getmetatable(o) or o.enabled~=true then return nil,'disabled' end
    local allowed={enabled=true,storage=true,guild=true,legacy_guild=true,membership=true,
        legacy_priorities=true,legacy_limits=true,journal_priorities=true,journal_limits=true}
    for k in pairs(o)do if not allowed[k]then return nil,'unknown field' end end
    local legacy_limits,invalid=canonical(o.legacy_limits,Caps)
    if not legacy_limits then return nil,invalid end
    if o.legacy_guild~=o.guild and legacy_limits.data[o.guild]~=nil
        and legacy_limits.data[o.legacy_guild]~=nil then
        return nil,'ambiguous canonical and runtime alias groups'
    end
    local groups={{legacy_guild=o.guild,storage=o.storage,guild=o.guild}}
    if o.legacy_guild~=o.guild then
        groups[#groups+1]={legacy_guild=o.legacy_guild,storage=o.storage,guild=o.guild}
    end
    -- Reuse checked alias mathematics, durable Pal keys and duplicate detection.
    local partition,why=Migration.plan{enabled=true,storage=o.storage,guild=o.guild,
        priorities=o.legacy_priorities,limits=o.legacy_limits,
        original_files={priorities=o.legacy_priorities,limits=o.legacy_limits},
        membership=o.membership,limit_membership=groups,limits_policy='explicit-alias-preserve-v1',
        max_payload_bytes=262144}
    if not partition then return nil,why end
    local jp,problem=canonical(o.journal_priorities,Store)
    if not jp then return nil,problem end
    local jl,issue=canonical(o.journal_limits,Caps)
    if not jl then return nil,issue end
    -- The codec checks scope on the canonical bytes of what was decoded, so an
    -- old-header journal is judged by its rules, not by its comment lines.
    for stream,body in pairs({priorities=assert(Store.serialize_snapshot(jp.data,jp.baseline)),
        limits=assert(Caps.serialize_snapshot(jl.data))})do
        local codec=Codec.new{storage=o.storage,guild=o.guild,stream=stream,max_payload_bytes=262144}
        if not codec.encode(body)then return nil,'journal schema/scope mismatch' end
    end
    local pp=assert(canonical(partition.preserved.bodies.priorities,Store))
    local pl=assert(canonical(partition.preserved.bodies.limits,Caps))
    if jp.baseline~=pp.baseline then return nil,'global baseline conflict' end
    local owned={}
    for _,claim in ipairs(o.membership)do
        if claim.guild==o.guild then owned[claim.pal]=true end
    end
    for pal,rows in pairs(jp.data)do
        if not owned[pal]then return nil,'journal Pal lacks target ownership claim' end
        if pp.data[pal]~=nil then return nil,'journal overlaps preserved Pal' end
        pp.data[pal]=rows
    end
    -- Empty journal group means deletion ONLY of the explicit target groups.
    -- Keep wildcard/default groups intact; OFF continues masking inherited rules.
    if jl.data[o.guild] then
        if pl.data[o.legacy_guild]~=nil then return nil,'journal overlaps preserved limit group' end
        pl.data[o.legacy_guild]=jl.data[o.guild]
    end
    local priorities=assert(Store.serialize_snapshot(pp.data,pp.baseline))
    local limits=assert(Caps.serialize_snapshot(pl.data))
    return {contract='PWP-EXPORT-RECONCILE-1',replacement_allowed=false,
        ownership_verified=false,deletion_coverage_verified=false,
        storage=o.storage,guild=o.guild,legacy_guild=o.legacy_guild,
        bodies={priorities=priorities,limits=limits},
        preserved_counts=partition.preserved.counts,
        replaced_counts=partition.candidate.counts,
        journal_counts={priorities=jp.count,limits=jl.count},
        result_counts={priorities=assert(Store.decode_snapshot(priorities)).count,
            limits=assert(Caps.decode_snapshot(limits)).count}}
end
return M
