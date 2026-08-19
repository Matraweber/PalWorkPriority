-- Which work types currently want a worker.
--
-- Palworld announces this itself: PalBaseCampWorkerDirector fires
-- OnRequiredAssignWork_ServerInternal repeatedly, every few seconds, for
-- every work still needing someone. Catching that pulse is the only reliable
-- source, and it is what the reference implementation uses.
--
-- Two simpler approaches were tried against this build and both failed:
--
--   Counting every work object in a camp overstates demand enormously. A
--   station keeps its work object for as long as it stands, so a base with a
--   handful of ripe bushes reported 78 gathering works, and pals were fenced
--   onto stations with nothing to do while real work went undone.
--
--   Reading WorkerDirector.RequiredAssignWorks reads an EMPTY array almost
--   every time, because a work sits in that list only for the instant it is
--   asking. Polling it every 30 seconds sees nothing, which looks identical
--   to an idle base and made the mod stop governing anything at all.
--
-- A job is considered finished when it stops pulsing. Demand is recounted
-- from the live set on every pass rather than kept as a running total, so a
-- missed event cannot leave a permanent phantom job behind.

local api = require("palapi")
local log = require("log")

local M = {}

-- How long a job survives without a pulse. This must exceed the worst gap
-- between re-fires or jobs oscillate in and out of demand and the toggles
-- flip at pulse frequency; the reference settled on 6 for that reason and
-- this is deliberately more generous still.
--
-- It also has to comfortably exceed the pass interval, or a job can live and
-- die entirely between two passes and never be seen at all.
M.FRESH_SECONDS = 25

M.pulses = 0                -- total ever seen
-- Pulses per work type, never pruned. This distinguishes "that work type
-- announced itself once at world load and never again" from "it re-announces
-- constantly" — which decides whether standing work can be seen at all.
M.pulses_by_value = {}
-- Whether the hook is in place. This, NOT the pulse count, is what says
-- demand can be trusted: a base whose pals are all asleep produces no pulses
-- at all, and treating that as a broken hook would fall back to counting
-- every work object and fence the whole roster onto imaginary night work.
M.hooked = false

local jobs = {}             -- work key -> { camp, value, seen, work }

function M.reset()
    jobs = {}
end

local function work_key(w)
    local key = api.guid_key(api.work_id(w))
    if key then return key end
    return api.work_full_name(w)
end

function M.install()
    if M.hooked then return true end

    local ok = pcall(function()
        RegisterHook("/Script/Pal.PalBaseCampWorkerDirector:OnRequiredAssignWork_ServerInternal",
            function(Context, Work)
                pcall(function()
                    local w = Work:get()
                    if not api.valid(w) then return end

                    local key = work_key(w)
                    if key == nil then return end

                    -- A repeat pulse for a job already known only refreshes
                    -- it. Resolving its type again every few seconds would be
                    -- pure waste, and the type cannot change.
                    local known = jobs[key]
                    if known then
                        known.seen = os.time()
                        return
                    end

                    local camp
                    local dir = Context:get()
                    if api.valid(dir) then
                        camp = api.guid_key(api.prop(dir, "BaseCampId"))
                    end

                    jobs[key] = {
                        camp = camp,
                        value = api.work_suitability(w),
                        seen = os.time(),
                        work = w,
                    }
                    M.pulses = M.pulses + 1
                    local v = jobs[key].value
                    if v then
                        M.pulses_by_value[v] = (M.pulses_by_value[v] or 0) + 1
                    end
                end)
            end)
    end)

    if ok then
        M.hooked = true
        log.debug("required-work pulse hook installed")
    else
        log.warn("could not hook OnRequiredAssignWork_ServerInternal — " ..
            "demand will fall back to counting every work object")
    end
    return M.hooked
end

-- Prunes finished jobs and returns { [work value] = count } for one camp,
-- plus how many live jobs are known across all camps.
--
-- A job whose camp could not be read is counted for every camp rather than
-- dropped: a job nobody can place is worse than one placed twice, since the
-- first leaves work undone and the second only fences a spare pal.
function M.for_camp(camp_key)
    local now = os.time()
    local out, live = {}, 0

    for key, e in pairs(jobs) do
        local dead = (now - e.seen) > M.FRESH_SECONDS
        if not dead and e.work ~= nil and not api.valid(e.work) then
            -- The work object died, which is the fast path: a finished job
            -- leaves within a pass instead of aging out.
            dead = true
        end

        if dead then
            jobs[key] = nil
        else
            live = live + 1
            if e.value and (e.camp == nil or camp_key == nil or e.camp == camp_key) then
                out[e.value] = (out[e.value] or 0) + 1
            end
        end
    end

    return out, live
end

return M
