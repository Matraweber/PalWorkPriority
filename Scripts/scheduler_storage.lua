-- Aggregate one bucketed scan into guild scopes. Container deduplication and
-- complete-read proof must come from the reader before aggregation loses IDs.
local M = {}

-- Retry an incomplete snapshot promptly once, then at a bounded cadence.
-- These counters affect timing only; they never establish completeness.
function M.failures(previous, verified)
    return verified and 0 or math.min((previous or 0) + 1, 4)
end

function M.retry_ttl(ttl, failures)
    if (failures or 0) == 0 then return ttl end
    return math.min(ttl, 30, 5 * 2 ^ (failures - 1))
end

function M.group(camps, by_camp, counts, evidence)
    local ownership, seen, guilds = {}, {}, {}
    local unknown = type(evidence) == "table" and tonumber(evidence.unknown_scope) or 0
    unknown = unknown or 0
    for _, camp in ipairs(camps) do
        if type(camp.id) ~= "string" or type(camp.guild) ~= "string" then
            unknown = unknown + 1
        elseif ownership[camp.id] and ownership[camp.id] ~= camp.guild then
            ownership[camp.id] = false
        elseif ownership[camp.id] ~= false then
            ownership[camp.id] = camp.guild
        end
    end
    for _, camp in ipairs(camps) do
        if type(camp.guild) == "string" and not guilds[camp.guild] then
            guilds[camp.guild] = { totals = {}, chests = 0, verified = false }
        end
    end
    for id, totals in pairs(by_camp or {}) do
        local guild = ownership[id]
        if not guild then
            unknown = unknown + 1
        elseif not seen[id] then
            seen[id] = true
            local out = guilds[guild]
            local chests = (counts or {})[id] or 0
            if type(chests) == "number" and chests >= 0 and chests < math.huge then
                out.chests = out.chests + chests
            else
                unknown = unknown + 1
            end
            for item, amount in pairs(totals) do
                if type(item) == "string" and type(amount) == "number" and amount >= 0 and amount < math.huge then
                    out.totals[item] = (out.totals[item] or 0) + amount
                else
                    unknown = unknown + 1
                end
            end
        end
    end
    local verified = type(by_camp) == "table" and type(counts) == "table"
        and type(evidence) == "table" and evidence.complete == true
        and evidence.deduplicated == true and unknown == 0
    for _, out in pairs(guilds) do
        out.verified = verified
        out.unknown_scope = unknown
    end
    return guilds, unknown
end

return M
