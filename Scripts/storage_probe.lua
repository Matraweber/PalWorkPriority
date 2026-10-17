-- One-shot, read-only census. All native objects stay inside this call;
-- the report contains scalars only. Never used as permission evidence.
local api = require('palapi')
local M = {}

function M.read()
    local report = {models=0, holders=0, slot_reads=0, failures=0, truncated=false, groups={}, examples={}}
    local identities, group_n = {}, 0
    local projected, projected_counts, projection_seen = {}, {}, {}
    local projection_ok=true
    local ok, models = pcall(FindAllOf, api.CONTAINER_BASE_CLASS)
    if not ok or type(models) ~= 'table' then report.failures=1; return report end
    for i, model in ipairs(models) do
        if report.slot_reads >= 32768 then report.truncated=true; break end
        if i > 8192 then report.truncated=true; break end
        report.models=report.models+1
        local good = pcall(function()
            if not api.valid(model) then error('model') end
            local module = model:GetItemContainerModule()
            if not api.valid(module) then return end
            report.holders=report.holders+1
            local name = model:GetFullName()
            if type(name) ~= 'string' then error('name') end
            local cls = name:match('^(%S+)') or '<unknown>'
            local scope_ok, guid = pcall(function() return model:GetBaseCampIdBelongTo() end)
            local cid = scope_ok and api.guid_key(guid) or nil
            local scope = cid and 'scoped' or 'unknown'
            local container = module.TargetContainer
            local state, identity, count, occupied = 'unavailable', nil, 0, 0
            local examples, quantities = {}, {}
            local contents_ok = pcall(function()
                if not api.valid(container) then return end
                identity = container:GetFullName()
                if type(identity) ~= 'string' or identity == '' then error('identity') end
                local slots = container.ItemSlotArray
                count = #slots
                if count < 0 or count > 4096 or count ~= math.floor(count) then error('slot budget') end
                for n=1,count do
                    if report.slot_reads >= 32768 then report.truncated=true; error('total slot budget') end
                    if n > #slots then error('slots changed') end
                    report.slot_reads=report.slot_reads+1
                    local slot = slots[n]
                    if slot == nil then error('slot missing') end
                    local checked, valid = pcall(function() return slot:IsValid() end)
                    if checked and valid == false then error('slot invalid') end
                    local id = slot.ItemId.StaticId:ToString()
                    if type(id) ~= 'string' then error('item') end
                    if id ~= '' and id ~= 'None' then
                        local amount = tonumber(slot.StackCount)
                        if not amount or amount < 0 or amount ~= amount or amount == math.huge then error('amount') end
                        if amount > 0 then occupied=occupied+1 end
                        quantities[id]=(quantities[id] or 0)+amount
                        if #examples < 3 then examples[#examples+1]=id .. '=' .. tostring(amount) end
                    end
                end
                if #slots ~= count then error('changed') end
                state = occupied == 0 and 'empty' or 'nonempty'
            end)
            if not contents_ok then state='unreadable' end
            -- Independent projection of the old reader's positive camp IDs.
            -- Unknown-world contents never contribute, regardless of class.
            if cid then
                if state ~= 'empty' and state ~= 'nonempty' then projection_ok=false
                elseif projection_seen[identity] then
                    if projection_seen[identity] ~= cid then projection_ok=false end
                else
                    projection_seen[identity]=cid
                    projected[cid]=projected[cid] or {}
                    projected_counts[cid]=(projected_counts[cid] or 0)+1
                    for id,n in pairs(quantities) do projected[cid][id]=(projected[cid][id] or 0)+n end
                end
            end
            local key = cls .. ' | ' .. scope .. ' | ' .. state
            if not report.groups[key] then
                group_n=group_n+1
                if group_n > 64 then key='<other groups>'; report.truncated=true end
            end
            report.groups[key]=(report.groups[key] or 0)+1
            if identity then
                local seen=identities[identity] or {unknown=0, scoped=0, camps={}}
                seen[scope]=seen[scope]+1
                if cid then seen.camps[cid]=true end
                identities[identity]=seen
            end
            if scope == 'unknown' and #report.examples < 12 and report.groups[key] == 1 then
                report.examples[#report.examples+1]=name .. ' -> ' .. tostring(identity) ..
                    ' slots=' .. tostring(count) .. ' state=' .. state .. ' [' .. table.concat(examples, ',') .. ']'
            end
        end)
        if not good then report.failures=report.failures+1 end
    end
    report.shared_scope_aliases=0
    report.distinct_targets,report.zero_only_targets,report.conflicting_targets=0,0,0
    for _, seen in pairs(identities) do
        report.distinct_targets=report.distinct_targets+1
        if seen.scoped == 0 then report.zero_only_targets=report.zero_only_targets+1 end
        local camps=0
        for _ in pairs(seen.camps) do camps=camps+1 end
        if camps > 1 then report.conflicting_targets=report.conflicting_targets+1 end
        if seen.scoped > 0 then report.shared_scope_aliases=report.shared_scope_aliases+seen.unknown end
    end
    report.projection=projected
    report.projection_counts=projected_counts
    report.comparison='unavailable'
    if api.has_authority and api.has_authority()==true and api.chest_totals_by_camp
        and projection_ok and report.failures==0 and not report.truncated then
        -- Same synchronous callback; a fresh production scan, no retained
        -- wrappers and no permission writes. Explicitly unfiltered base stock.
        local called, now, counts, evidence=pcall(api.chest_totals_by_camp, {exclude={}})
        if not called or type(now)~='table' or type(counts)~='table' or type(evidence)~='table' then
            report.comparison='unavailable (production read)'
            return report
        end
        report.production_complete=evidence.complete==true and evidence.deduplicated==true
            and (evidence.unknown_scope or 0)==0
        report.production_exclusions=evidence.outside_camp_loot or 0
        if not report.production_complete then report.comparison='INCOMPLETE'; return report end
        local compared, equal=pcall(function()
        local equal=true
        for cid, quantities in pairs(projected) do
            if not now[cid] or counts[cid]~=projected_counts[cid] then equal=false end
            for id,n in pairs(quantities) do if not now[cid] or now[cid][id]~=n then equal=false end end
        end
        for cid, quantities in pairs(now) do
            if not projected[cid] or counts[cid]~=projected_counts[cid] then equal=false end
            for id,n in pairs(quantities) do if not projected[cid] or projected[cid][id]~=n then equal=false end end
        end
        return equal
        end)
        report.comparison=compared and (equal and 'MATCH' or 'MISMATCH') or 'unavailable (malformed production rows)'
    end
    return report
end

function M.format(report)
    local lines={string.format('storage census: models=%d holders=%d failures=%d truncated=%s unknown aliases with scoped backing=%d',
        report.models, report.holders, report.failures, tostring(report.truncated), report.shared_scope_aliases or 0)}
    lines[#lines+1]=string.format('  distinct backing targets=%d unknown-only=%d conflicting camp ownership=%d',
        report.distinct_targets or 0, report.zero_only_targets or 0, report.conflicting_targets or 0)
    lines[#lines+1]='  slot reads=' .. tostring(report.slot_reads)
    lines[#lines+1]='  independent positive-base projection vs production reader (unfiltered): ' ..
        tostring(report.comparison) .. '; production complete=' .. tostring(report.production_complete) ..
        '; exclusions=' .. tostring(report.production_exclusions)
    local camps={}
    for cid in pairs(report.projection or {}) do camps[#camps+1]=cid end
    table.sort(camps)
    for index,cid in ipairs(camps) do
        if index > 8 then lines[#lines+1]='  additional bases omitted from text report'; break end
        local items={}
        for id,n in pairs(report.projection[cid]) do items[#items+1]=id .. '=' .. tostring(n) end
        table.sort(items)
        if #items > 64 then
            local omitted=#items-64
            for i=#items,65,-1 do items[i]=nil end
            items[#items+1]='... ' .. omitted .. ' additional items omitted'
        end
        lines[#lines+1]='  base ' .. cid .. ' containers=' .. report.projection_counts[cid] .. ': ' .. table.concat(items, ',')
    end
    local keys={}
    for key in pairs(report.groups) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do lines[#lines+1]='  ' .. key .. ': ' .. report.groups[key] end
    for _,example in ipairs(report.examples) do lines[#lines+1]='  example: ' .. example end
    -- What the scheduler itself compared in its last pass: per base, each
    -- limited item's count against its ceiling, and the decision. Read only
    -- from tables the scheduler already published; nothing is recomputed
    -- except cap_state over those same published totals.
    local okm, sched = pcall(require, 'scheduler')
    local okc, caps = pcall(require, 'caps')
    if okm and okc and type(sched) == 'table' and type(caps) == 'table' then
        local cfg = {}
        for key, totals in pairs(sched.last_totals_by_camp or {}) do
            local st = (sched.last_storage_by_camp or {})[key] or {}
            local parts = {}
            for _, work in ipairs({ 'Deforest', 'Mining' }) do
                local okw, ceilings = pcall(caps.for_work, cfg, work, st.guild)
                for item, ceiling in pairs(okw and ceilings or {}) do
                    parts[#parts + 1] = string.format('%s %s %s/%s', work, item, tostring(totals[item]), tostring(ceiling))
                end
                local okd, capped = pcall(sched.cap_state, cfg, work, totals, st.guild)
                parts[#parts + 1] = work .. ' capped=' .. tostring(okd and capped)
            end
            lines[#lines+1] = '  scheduler base ' .. tostring(key) .. ' verified=' .. tostring(st.verified)
                .. ' scope=' .. tostring(st.scope) .. ': ' .. table.concat(parts, ', ')
        end
    end
    return table.concat(lines, '\n')
end

return M
