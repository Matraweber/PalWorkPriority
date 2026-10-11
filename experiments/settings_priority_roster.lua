-- Callback-local diagnostic only. The caller supplies world/lifecycle binding;
-- this observation never grants authority. Only the injected read APIs are used.
-- complete covers expected_alias camps, NOT all guilds/worlds. Foreign camps
-- have their identity/scope checked and counted, but their Pals are not read.
-- On failure, dense rows/counts are partial observations, never proof of absence.
local M = {}
local MAX_CAMPS, MAX_PALS, MAX_TOTAL, MAX_WORK = 32, 2048, 4096, 64

local function key(value)
    -- Same durable scalar key contract as store; no store/engine dependency.
    return type(value) == 'string' and #value > 0 and #value <= 160
        and not value:find('[^%w%-]') and not value:lower():match('^slot%d+$')
        and value ~= '0-0-0-0'
end

local function array_size(value, limit)
    if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil end
    local count = 0
    for i in next, value do
        count = count + 1
        if count > limit or type(i) ~= 'number' or i % 1 ~= 0
            or i < 1 or i > limit then return nil end
    end
    for i = 1, count do if rawget(value, i) == nil then return nil end end
    return count
end

function M.read(api, workdefs, expected_alias)
    local report = {complete=false, scope='expected_guild', camps={},
        observed_camps=0, target_camps=0, foreign_camps=0, observed_pals=0}
    if not key(expected_alias) then return report end
    report.expected_alias = expected_alias
    -- Catch injected read failures without publishing exception objects/wrappers.
    local ok, complete = pcall(function()
        local nwork = array_size(workdefs.ORDER, MAX_WORK)
        if not nwork or nwork == 0 or type(workdefs.ANYONE) ~= 'string' then return false end
        local works, names, values = {}, {}, {}
        for i = 1, nwork do
            local name = workdefs.ORDER[i]
            if type(name) ~= 'string' or name == '' or names[name] then return false end
            names[name] = true
            if name ~= workdefs.ANYONE then
                local value = workdefs.value(name)
                if type(value) ~= 'number' or value % 1 ~= 0 or value < 1
                    or value > MAX_WORK or values[value] then return false end
                values[value] = true
                works[#works+1] = value
            end
        end
        if #works == 0 then return false end
        local camps = api.base_camps() -- availability belongs to this fresh call
        local ncamps = array_size(camps, MAX_CAMPS)
        if not ncamps or api.camps_available ~= true then return false end
        local seen_camps, seen_pals = {}, {}
        for i = 1, ncamps do
            local camp = camps[i]
            report.observed_camps = report.observed_camps + 1
            local id = api.camp_id(camp)
            if id == nil then return false end
            local cid, guild = api.guid_key(id), api.camp_guild(camp)
            if not key(cid) or not key(guild) or seen_camps[cid] then return false end
            seen_camps[cid] = true
            if guild ~= expected_alias then
                report.foreign_camps = report.foreign_camps + 1
            else
                report.target_camps = report.target_camps + 1
                local pals, err = api.camp_pals(camp)
                local npals = array_size(pals, MAX_PALS)
                if err ~= nil or not npals or report.observed_pals + npals > MAX_TOTAL then return false end
                local row = {key=cid, guild=guild, pals={}}
                report.camps[#report.camps+1] = row
                for j = 1, npals do
                    local pal = pals[j]
                    if type(pal) ~= 'table' or getmetatable(pal) ~= nil
                        or not key(pal.key) or pal.param == nil or seen_pals[pal.key] then return false end
                    seen_pals[pal.key] = true
                    report.observed_pals = report.observed_pals + 1
                    local capable = {}
                    for _, value in ipairs(works) do
                        local rank = api.suitability_rank(pal.param, value)
                        if type(rank) ~= 'number' or rank % 1 ~= 0 or rank < 0 then return false end
                        if rank > 0 then capable[value] = true end
                    end
                    row.pals[#row.pals+1] = {key=pal.key, capable=capable}
                end
            end
        end
        return true
    end)
    report.complete = ok and complete == true
    return report
end

return M
