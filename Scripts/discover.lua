-- Read-only reconnaissance.
--
-- Writes Discovery.txt next to the mod. Nothing here changes game state; it
-- exists to answer the two questions this build has not confirmed yet:
--
--   1. Which property or function on a work says what suitability it needs?
--      SUITABILITY_PROBES in palapi.lua is a guess list until this says
--      which entry actually answers.
--   2. Does EPalWorkSuitability start at 0 or 1? workdefs.enum_offset
--      assumes 1. The rank sweep below settles it: find a pal you know the
--      suitabilities of and see which offset lines the ranks up.

local log = require("log")
local api = require("palapi")
local workdefs = require("workdefs")

local M = {}

local CLASSES = {
    "/Script/Pal.PalWorkBase",
    "/Script/Pal.PalWorkProgress",
    "/Script/Pal.PalBaseCampWorkerDirector",
    "/Script/Pal.PalNetworkBaseCampComponent",
    "/Script/Pal.PalIndividualCharacterParameter",
}

local function dump_schema(f, class_path)
    f:write("=== schema " .. class_path .. "\n")

    local walked = pcall(function()
        local cur = StaticFindObject(class_path)
        if not api.valid(cur) then
            f:write("  class not found on this build\n")
            return
        end

        local depth = 0
        while cur and depth < 6 do
            local cname = "?"
            pcall(function() cname = cur:GetFullName() end)
            f:write(" class: " .. cname .. "\n")

            pcall(function()
                cur:ForEachProperty(function(p)
                    local n = "?"
                    pcall(function() n = p:GetFullName() end)
                    f:write("   prop " .. n .. "\n")
                end)
            end)

            pcall(function()
                cur:ForEachFunction(function(fn)
                    local n = "?"
                    pcall(function() n = fn:GetFName():ToString() end)
                    f:write("   func " .. n .. "\n")
                end)
            end)

            local nxt
            pcall(function() nxt = cur:GetSuperStruct() end)
            if not nxt or nxt == cur then break end
            cur = nxt
            depth = depth + 1
        end
    end)

    if not walked then f:write("  schema walk unavailable\n") end
end

-- Tries every probe against real work objects and reports which answered.
local function probe_works(f)
    f:write("=== live work probes\n")

    local camps = api.base_camps()
    f:write("camps loaded: " .. #camps .. "\n")

    local sampled = 0
    for ci, camp in ipairs(camps) do
        local works, err = api.camp_works(camp)
        f:write(string.format("camp %d: %d work(s)%s\n",
            ci, #works, err and (" (" .. err .. ")") or ""))

        for _, w in ipairs(works) do
            if sampled >= 12 then break end
            sampled = sampled + 1

            f:write("  work " .. api.work_full_name(w) .. "\n")
            for _, probe in ipairs(api.SUITABILITY_PROBES) do
                local raw, ok
                if probe.kind == "func" then
                    ok = pcall(function() raw = w[probe.name](w) end)
                else
                    ok = pcall(function() raw = w[probe.name] end)
                end
                local as_int = api.as_int(raw)
                if ok and raw ~= nil then
                    f:write(string.format("    %-4s %-28s -> %s (int %s)\n",
                        probe.kind, probe.name, tostring(raw), tostring(as_int)))
                end
            end
        end
    end

    if sampled == 0 then
        f:write("  no works reachable — load into a world with a base and retry\n")
    end
end

-- Sweeps a wider integer range than the mod uses, so the enum's real base
-- is visible rather than assumed.
local function probe_ranks(f)
    f:write("=== suitability rank sweep\n")
    f:write("offset currently assumed: " .. workdefs.enum_offset .. "\n")
    f:write("if a pal's ranks look shifted by one, change enum_offset in workdefs.lua\n")

    local camps = api.base_camps()
    local shown = 0

    for _, camp in ipairs(camps) do
        local pals = api.camp_pals(camp)
        for _, pal in ipairs(pals) do
            if shown >= 6 then break end
            shown = shown + 1

            f:write(string.format("  pal '%s' (species %s)\n",
                pal.name, tostring(pal.species)))
            for v = 0, 14 do
                local rank = api.suitability_rank(pal.param, v)
                if rank and rank > 0 then
                    local guess_0 = workdefs.ORDER[v + 1] or "?"
                    local guess_1 = workdefs.ORDER[v] or "?"
                    f:write(string.format(
                        "    value %2d -> rank %d   (offset0: %s | offset1: %s)\n",
                        v, rank, guess_0, guess_1))
                end
            end
        end
    end

    if shown == 0 then
        f:write("  no base pals reachable — load into a world with a staffed base\n")
    end
end

local function enum_names(f)
    f:write("=== EPalWorkSuitability\n")
    local ok = pcall(function()
        local e = StaticFindObject("/Script/Pal.EPalWorkSuitability")
        if not api.valid(e) then
            f:write("  enum object not found (normal on some builds)\n")
            return
        end
        f:write("  found: " .. tostring(e:GetFullName()) .. "\n")
        for v = 0, 14 do
            local name
            pcall(function() name = e:GetNameByValue(v):ToString() end)
            if name then f:write(string.format("  %2d = %s\n", v, name)) end
        end
    end)
    if not ok then f:write("  enum walk unavailable\n") end
end

function M.run(out_path)
    local f, open_err = io.open(out_path, "wb")
    if not f then
        log.error("could not write " .. out_path .. ": " .. tostring(open_err))
        return false
    end

    f:write("Pal Work Priority discovery dump\n")
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n\n")

    pcall(function() enum_names(f) end)
    f:write("\n")
    pcall(function() probe_ranks(f) end)
    f:write("\n")
    pcall(function() probe_works(f) end)
    f:write("\n")
    for _, c in ipairs(CLASSES) do
        pcall(function() dump_schema(f, c) end)
        f:write("\n")
    end

    f:close()
    log.say("discovery written to " .. out_path)
    return true
end

return M
