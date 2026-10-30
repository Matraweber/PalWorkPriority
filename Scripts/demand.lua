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

-- A recent request is an estimate of vacant work, not proof that a job is
-- still ready, occupied or completed. No stored work object is dereferenced;
-- age only expires the request estimate. Assignment retention uses separate
-- evidence for the individual assignment in scheduler_plan.lua.
M.FRESH_SECONDS = 45

M.pulses = 0                -- total ever seen
-- Pulses per work type, never pruned. This distinguishes "that work type
-- announced itself once at world load and never again" from "it re-announces
-- constantly", which decides whether standing work can be seen at all.
M.pulses_by_value = {}
-- Diagnostic timestamp of a validated work pulse. main must not use it as
-- authority evidence until the callback's native world/session association is
-- verified. Cumulative counters cannot establish the current session's role.
M.last_pulse_at = nil
-- Whether the hook is in place. This, NOT the pulse count, is what says
-- demand can be trusted: a base whose pals are all asleep produces no pulses
-- at all, and treating that as a broken hook would fall back to counting
-- every work object and fence the whole roster onto imaginary night work.
M.hooked = false

local jobs = {}             -- work key -> plain { camp, value, seen } only

function M.reset()
    jobs = {}
    M.last_pulse_at = nil
end

local function work_key(w)
    local key = api.guid_key(api.work_id(w))
    if key then return key end
    local name = api.work_full_name(w)
    if type(name) == "string" and name ~= "" and name ~= "<unknown work>" then
        return name
    end
    return nil
end

-- Accept plain pulse evidence. Missing fields may be repaired by a later
-- pulse, but an unreadable field never erases a previously verified one.
-- Conflicting known camp/type data is treated as a new identity generation.
-- `reason` is work_suitability's second answer: "ignored" marks a work that
-- is deliberately not work (the egg incubator), so it is reported as ignored
-- rather than untyped (review round 4, scheduler P3-4).
function M.observe(key, camp, value, now, reason)
    if type(key) ~= "string" or key == "" then return false end
    if type(camp) ~= "string" or camp == "" then camp = nil end
    if type(value) ~= "number" or math.tointeger(value) == nil or value <= 0 then
        value = nil
    end
    if type(now) ~= "number" then now = nil end
    local known = jobs[key]
    if known and ((camp and known.camp and camp ~= known.camp)
        or (value and known.value and value ~= known.value)) then
        known = nil
    end
    if not known then
        known = {}
        jobs[key] = known
        M.pulses = M.pulses + 1
    end
    if value and not known.value then
        M.pulses_by_value[value] = (M.pulses_by_value[value] or 0) + 1
    end
    known.camp = camp or known.camp
    known.value = value or known.value
    if known.value then known.ignored = nil elseif reason == "ignored" then known.ignored = true end
    known.seen = now or os.time()
    return true
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
                -- Counted at the top, before the validity test and before the
                -- known-job early out.
                --
                -- The game fires this once every few seconds per work still
                -- wanting a worker, so the rate is a function of how busy the
                -- base is - which is exactly the shape of "significantly
                -- worse once I enter the base". M.pulses below counts only
                -- jobs never seen before, so it goes quiet precisely when the
                -- hook is busiest.
                local _b = log.count("hook: demand")
                local _t0 = log.perf and os.clock() or nil

                local read_ok, read_error = pcall(function()
                    local w = Work:get()
                    if not api.valid(w) then return end

                    local key = work_key(w)
                    if key == nil then return end

                    -- Resolve missing data again. The original fast path
                    -- permanently retained nil camp/type fields from a pulse
                    -- received before world data finished loading.
                    local known = jobs[key]
                    if known then
                        log.count("hook: demand repeat pulse")
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
                    -- Both answers, named: passed straight through, the
                    -- reason "ignored" landed in observe's `now` and became
                    -- the pulse's timestamp, a string that for_camp then
                    -- compared with a number (review round 4).
                    local value, reason = api.work_suitability(w)
                    if M.observe(key, camp, value, nil, reason) then
                        -- Only a validated work pulse may support authority.
                        -- reset() clears this evidence at a session boundary.
                        M.last_pulse_at = os.clock()
                    end
                end)
                if not read_ok then
                    log.warn("required-work pulse could not be read: " .. tostring(read_error))
                end
                if _t0 then _b.ms = _b.ms + (os.clock() - _t0) * 1000 end
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

-- Recent pulses are evidence of a request, not proof of current occupancy or
-- completion. Return only the requested camp's ready estimate. Unknown scope
-- is quarantined and reported separately, never broadcast to every camp.
function M.for_camp(camp_key, at)
    local now = at or os.time()
    local out, live = {}, 0
    local evidence = { source = "recent pulses", ready = out, unknown_scope = 0,
        unknown_type = 0, ignored = 0, jobs = {} }

    for key, e in pairs(jobs) do
        local dead = now < e.seen or (now - e.seen) > M.FRESH_SECONDS

        if dead then
            jobs[key] = nil
        else
            if e.camp == nil then
                evidence.unknown_scope = evidence.unknown_scope + 1
            elseif camp_key ~= nil and e.camp == camp_key then
                live = live + 1
                if e.value then
                    out[e.value] = (out[e.value] or 0) + 1
                    evidence.jobs[key] = { value = e.value, seen = e.seen }
                elseif e.ignored then
                    evidence.ignored = evidence.ignored + 1
                else
                    evidence.unknown_type = evidence.unknown_type + 1
                end
            end
        end
    end

    return out, live, evidence
end

return M
