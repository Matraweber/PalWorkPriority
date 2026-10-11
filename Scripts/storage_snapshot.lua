-- Plain-data storage publication. Never scans or borrows another guild's totals.
local wire = require('protocol')
local M = { MAX_ITEMS = wire.MAX_STORAGE_ITEMS, MAX_CAMPS = wire.MAX_STORAGE_CAMPS,
    MAX_AGE = wire.MAX_STORAGE_MS / 1000 }

function M.fresh(evidence, now)
    if type(evidence)~='table' or type(now)~='number' then return nil end
    local sampled, ttl=evidence.sampled_at,evidence.ttl
    if type(sampled)~='number' or type(ttl)~='number' or ttl~=ttl or ttl<=0 then return nil end
    local age=now-sampled
    ttl=math.min(ttl,M.MAX_AGE)
    if age~=age or age<0 or age>=ttl then return nil end
    local remaining=math.floor((ttl-age)*1000)
    if remaining<=0 then return nil end
    return math.ceil(age*1000),remaining
end

function M.build(cfg, scheduler, guild, selected, now)
    local scope = cfg.storage_scope == 'global' and 'guild' or 'camp'
    local result = {scope=scope, choices={}, verified=false, totals={}, age_ms=0, remaining_ms=0}
    if not wire.token(guild) or type(now)~='number' then return result end
    local evidence, totals
    for camp, meta in pairs(scheduler.last_storage_by_camp or {}) do
        if type(meta)=='table' and meta.guild==guild and meta.pass==scheduler.pass_id then
            if not wire.token(camp) or #result.choices >= M.MAX_CAMPS then
                result.choices={}; return result
            end
            result.choices[#result.choices+1]=camp
        end
    end
    table.sort(result.choices)
    if scope=='guild' then
        evidence=(scheduler.last_storage or {})[guild]
        totals=(scheduler.last_totals_by_guild or {})[guild]
    else
        if selected==nil then selected=result.choices[1] end
        local found=false
        for _, camp in ipairs(result.choices) do if camp==selected then found=true end end
        -- An unavailable explicit selection must not silently select another base.
        if not found then return result end
        result.camp=selected
        evidence=(scheduler.last_storage_by_camp or {})[selected]
        totals=(scheduler.last_totals_by_camp or {})[selected]
    end
    if type(evidence)~='table' or evidence.verified~=true
        or evidence.pass~=scheduler.pass_id or evidence.scope~=scope
        or (scope=='camp' and evidence.guild~=guild)
        or (evidence.unknown_scope or 0)~=0 or type(totals)~='table' then return result end
    local age_ms, remaining_ms=M.fresh(evidence,now)
    if not age_ms then return result end
    local copied, count={},0
    for item, amount in pairs(totals) do
        count=count+1
        if count>M.MAX_ITEMS or not wire.item(item) or type(amount)~='number'
            or not wire.integer(amount,0,2147483647) then return result end
        copied[item]=amount
    end
    result.age_ms,result.remaining_ms=age_ms,remaining_ms
    result.totals, result.verified=copied,true
    return result
end

return M
