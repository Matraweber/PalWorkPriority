-- Which work types currently want a worker.
--
-- The game announces this itself: PalBaseCampWorkerDirector fires
-- OnRequiredAssignWork_ServerInternal every few seconds for each work still
-- needing someone. Catching that pulse is the only reliable source.
--
-- Two simpler sources were tried on this build and both failed, so do not
-- simplify back to either. Counting every work object overstates demand
-- enormously: a base with a few ripe bushes reported 78 gathering works.
-- Reading WorkerDirector.RequiredAssignWorks reads an EMPTY array almost
-- always, since a work sits there only for the instant it is asking.
--
-- Demand is recounted from the live set each pass rather than kept as a
-- running total, so a missed event cannot leave a phantom job behind.

local api = require("palapi")
local log = require("log")

local M = {}

-- How long a job survives without another pulse.
--
-- The most delicate number here. Work types announce at wildly different
-- rates: on one base all 77 gathering works pulsed while only 2 of 16
-- lumbering works ever did, so a short window starved lumbering entirely.
--
-- The real end-of-job signal is the work OBJECT dying, checked separately and
-- pruned within a pass. This is only the backstop, so it can afford to be
-- generous: overstating demand costs a fenced pal, understating it stops the
-- mod governing that work type at all.
-- Shorter now that it is the only pruning there is.
--
-- A finished job simply stops pulsing, so age is the honest signal that it is
-- over. Three minutes was tolerable while a validity check caught the dead
-- ones sooner; as the sole test it would count finished work as wanted for far
-- too long and over-assign against it.
M.FRESH_SECONDS = 45

M.pulses = 0                -- total ever seen
-- Pulses per work type, never pruned. This distinguishes "that work type
-- announced itself once at world load and never again" from "it re-announces
-- constantly", which decides whether standing work can be seen at all.
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

-- Registering the hook and receiving from it are different things. The hook
-- is on a _ServerInternal function, so on a client connected to a dedicated
-- server it registers cleanly and then never fires. Callers need to know that
-- an empty index means "cannot see the work" rather than "there is no work",
-- because those two call for opposite behaviour.
function M.live()
    return M.hooked and api.has_authority()
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

                    -- The work object itself is deliberately not kept.
                    --
                    -- It was stored for one purpose, asking it later whether
                    -- it was still valid, and that question is the crash: a
                    -- wrapper held since an earlier frame points at memory the
                    -- game has since reused, and IsValid on it dereferences
                    -- that memory rather than checking anything. With around
                    -- five hundred and fifty tracked jobs it was asked eleven
                    -- hundred times a pass, of objects up to three minutes
                    -- old, which is why the fault counted passes rather than
                    -- seconds and why it survived every other fix tried.
                    --
                    -- Everything read from it is read now, while the engine
                    -- has just handed it over and it is certainly alive.
                    jobs[key] = {
                        camp = camp,
                        value = api.work_suitability(w),
                        seen = os.time(),
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
        log.warn("could not hook OnRequiredAssignWork_ServerInternal, " ..
            "demand will fall back to counting every work object")
    end
    return M.hooked
end

-- Prunes finished jobs and returns { [work value] = count } for one camp,
-- plus how many live jobs are known overall. A job whose camp will not read
-- counts for every camp: placing it twice beats losing it.
function M.for_camp(camp_key)
    local now = os.time()
    local out, live = {}, 0

    for key, e in pairs(jobs) do
        local dead = (now - e.seen) > M.FRESH_SECONDS

        -- The riskiest read in the mod, and the comment below says why
        -- without meaning to: this expects the object to have died, then
        -- asks it whether it is valid. IsValid is a member call, so on a
        -- freed object the question is the crash.

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
