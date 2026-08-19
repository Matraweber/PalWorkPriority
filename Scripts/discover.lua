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
local ui = require("ui")
local demandidx = require("demand")

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

-- Reads the fields PalWorkBase actually has, and reports whether each work
-- could be classified. The tail of this section is the important part: any
-- work listed as UNRESOLVED is one the scheduler will skip, and its text is
-- what a new entry in workdefs.KEYWORDS has to match.
local function text_of(w, kind, name)
    local raw
    if kind == "func" then
        local ok = pcall(function() raw = w[name](w) end)
        if not ok then return nil end
    else
        local ok = pcall(function() raw = w[name] end)
        if not ok then return nil end
    end
    if raw == nil then return nil end
    if type(raw) == "string" then return raw end

    local out
    pcall(function()
        if raw.ToString then out = raw:ToString() end
    end)
    if type(out) == "string" and out ~= "" then return out end
    return nil
end

-- Required works next to total works. If the two numbers are equal the
-- required list is filtering nothing and demand is being overstated, which
-- is what fences a pal onto a station that has nothing to do.
local function probe_demand(f)
    f:write("=== required works vs all works\n")

    for ci, camp in ipairs(api.base_camps()) do
        local required = api.camp_required_works(camp)
        local all = api.camp_works(camp)

        f:write(string.format("camp %d: required=%s  all=%d\n", ci,
            required and tostring(#required) or "UNREADABLE", #all))

        -- What the raw entries of RequiredAssignWorks actually are. Two
        -- attempts at reading that list have now failed, and the reference
        -- avoids it entirely in favour of hooking the event, so the shape of
        -- an entry is the thing still not established.
        local director = api.prop(camp, "WorkerDirector")
        local raw = director and api.prop(director, "RequiredAssignWorks") or nil
        if raw ~= nil then
            local shown = 0
            pcall(function()
                raw:ForEach(function(_, entry)
                    if shown >= 3 then return end
                    shown = shown + 1
                    local e = api.unwrap(entry)

                    local cls = "?"
                    pcall(function() cls = e:GetClass():GetFName():ToString() end)

                    local wid, has_id = nil, false
                    if pcall(function() wid = e:GetWorkId() end) then
                        has_id = api.guid_key(wid) ~= nil
                    end

                    local as_guid = api.guid_key(e)
                    local sub = api.guid_key(api.prop(e, "WorkId"))

                    f:write(string.format(
                        "    entry %d: class=%s  GetWorkId=%s  isGuid=%s  .WorkId=%s\n",
                        shown, tostring(cls), tostring(has_id),
                        tostring(as_guid ~= nil), tostring(sub ~= nil)))
                end)
            end)
        else
            f:write("    RequiredAssignWorks property did not read at all\n")
        end

        if required then
            local by_type = {}
            for _, w in ipairs(required) do
                local v = api.work_suitability(w)
                local n = v and workdefs.name(v) or "?"
                by_type[n] = (by_type[n] or 0) + 1
            end

            local names = {}
            for n in pairs(by_type) do names[#names + 1] = n end
            table.sort(names)
            for _, n in ipairs(names) do
                f:write(string.format("    %-22s %d\n", n, by_type[n]))
            end
        end
    end
end

-- Per work type: how many exist, how many still have a free slot, how many
-- have nobody on them, and every CurrentState seen. Plus how many pulses that
-- type has ever produced.
--
-- The question this answers: what distinguishes a tree waiting to be chopped
-- from a campfire with nothing to burn? Both exist as work objects, and using
-- the wrong predicate either idles pals at cold stations or hides real work.
local function probe_readiness(f)
    f:write("=== work readiness by type\n")
    f:write("  pulses counts every announcement ever seen this session\n")

    local agg = {}
    for _, camp in ipairs(api.base_camps()) do
        for _, w in ipairs(api.camp_works(camp)) do
            local value = api.work_suitability(w)
            local name = (value and workdefs.name(value)) or "?"

            local e = agg[name]
            if not e then
                e = { n = 0, slot = 0, unmanned = 0, states = {}, value = value }
                agg[name] = e
            end
            e.n = e.n + 1

            local free
            pcall(function() free = w:IsExistAssignableSlot() end)
            if free == true then e.slot = e.slot + 1 end

            local assigned
            pcall(function()
                local list = w:GetAssignedCharacters()
                local n = 0
                if list then list:ForEach(function() n = n + 1 end) end
                assigned = n
            end)
            if assigned == 0 then e.unmanned = e.unmanned + 1 end

            local st = api.as_int(api.prop(w, "CurrentState"))
            if st then e.states[st] = (e.states[st] or 0) + 1 end
        end
    end

    local names = {}
    for name in pairs(agg) do names[#names + 1] = name end
    table.sort(names)

    f:write(string.format("  %-22s %5s %6s %9s %8s  %s\n",
        "type", "works", "free", "unmanned", "pulses", "CurrentState counts"))
    for _, name in ipairs(names) do
        local e = agg[name]
        local states = {}
        for st, c in pairs(e.states) do states[#states + 1] = st .. "x" .. c end
        table.sort(states)

        f:write(string.format("  %-22s %5d %6d %9d %8s  %s\n",
            name, e.n, e.slot, e.unmanned,
            tostring(e.value and demandidx.pulses_by_value[e.value] or 0),
            table.concat(states, " ")))
    end
end

local function probe_works(f)
    f:write("=== live work probes\n")

    local camps = api.base_camps()
    f:write("camps loaded: " .. #camps .. "\n")

    local total, resolved = 0, 0
    local unresolved = {}
    local by_type = {}
    -- OverrideWorkType value -> how many works reported it, and one example
    -- of each. This is the raw material for WORKTYPE_TO_SUIT: pair each
    -- number with its name from the EPalWorkType dump above.
    local worktypes = {}

    for ci, camp in ipairs(camps) do
        local works, err = api.camp_works(camp)
        f:write(string.format("camp %d: %d work(s)%s\n",
            ci, #works, err and (" (" .. err .. ")") or ""))

        for wi, w in ipairs(works) do
            total = total + 1

            local assign_id = text_of(w, "prop", "AssignDefineDataId")
            local work_name = text_of(w, "func", "GetWorkName")
            local full = api.work_full_name(w)
            local override = api.as_int(api.prop(w, "OverrideWorkType"))

            if override then
                local slot = worktypes[override]
                if slot then
                    slot.n = slot.n + 1
                else
                    worktypes[override] = {
                        n = 1,
                        assign = assign_id or "?",
                        work_name = work_name or "?",
                        class = full:gsub("%s.*$", ""),
                    }
                end
            end

            local value = api.work_suitability(w)
            local resolved_name = value and workdefs.name(value) or nil

            if resolved_name then
                resolved = resolved + 1
                by_type[resolved_name] = (by_type[resolved_name] or 0) + 1
            else
                local key = (assign_id or "?") .. " | " .. (work_name or "?") ..
                    " | " .. full:gsub("%s.*$", "")
                unresolved[key] = (unresolved[key] or 0) + 1
            end

            -- Full detail for a sample only; the summary below covers the rest.
            if wi <= 8 then
                f:write("  work " .. full .. "\n")
                f:write("    AssignDefineDataId = " .. tostring(assign_id) .. "\n")
                f:write("    GetWorkName        = " .. tostring(work_name) .. "\n")
                f:write("    OverrideWorkType   = " .. tostring(override) .. "\n")
                f:write("    resolved as        = " .. tostring(resolved_name) .. "\n")
            end
        end
    end

    f:write(string.format("\n  resolved %d of %d work(s)\n", resolved, total))

    if next(by_type) then
        f:write("  by work type:\n")
        local names = {}
        for name in pairs(by_type) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            f:write(string.format("    %-22s %d\n", name, by_type[name]))
        end
    end

    if next(worktypes) then
        f:write("  OverrideWorkType values seen (match against the EPalWorkType dump):\n")
        local vals = {}
        for v in pairs(worktypes) do vals[#vals + 1] = v end
        table.sort(vals)
        for _, v in ipairs(vals) do
            local e = worktypes[v]
            f:write(string.format("    %3d  x%-4d %s | %s | %s\n",
                v, e.n, e.assign, e.work_name, e.class))
        end
    end

    if next(unresolved) then
        f:write("  UNRESOLVED (AssignDefineDataId | GetWorkName | class):\n")
        for key, n in pairs(unresolved) do
            f:write(string.format("    x%-4d %s\n", n, key))
        end
    end

    if total == 0 then
        f:write("  no works reachable. Load into a world with a base and retry\n")
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
        f:write("  no base pals reachable. Load into a world with a staffed base\n")
    end
end

local function dump_enum(f, path, upto)
    f:write("=== " .. path .. "\n")
    local ok = pcall(function()
        local e = StaticFindObject(path)
        if not api.valid(e) then
            f:write("  enum object not found (normal on some builds)\n")
            return
        end
        f:write("  found: " .. tostring(e:GetFullName()) .. "\n")
        for v = 0, upto do
            local name
            pcall(function() name = e:GetNameByValue(v):ToString() end)
            if name then f:write(string.format("  %2d = %s\n", v, name)) end
        end
    end)
    if not ok then f:write("  enum walk unavailable\n") end
end

-- EPalWorkType is the enum behind a work's OverrideWorkType, and it is NOT
-- EPalWorkSuitability. The two are different sets with overlapping small
-- integers, which is exactly how a wrong reading gets filed as plausible.
-- Its names are what WORKTYPE_TO_SUIT in palapi.lua has to be built from.
local function enum_names(f)
    dump_enum(f, "/Script/Pal.EPalWorkSuitability", 16)
    f:write("\n")
    dump_enum(f, "/Script/Pal.EPalWorkType", 60)
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
    pcall(function() ui.dump(f) end)
    f:write("\n")
    pcall(function() probe_ranks(f) end)
    f:write("\n")
    pcall(function() probe_demand(f) end)
    f:write("\n")
    pcall(function() probe_readiness(f) end)
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
