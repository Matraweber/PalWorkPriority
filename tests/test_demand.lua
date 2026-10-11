local hook
local warnings = {}
package.loaded.palapi = {
    guid_key = function(id) return id end,
    work_id = function(w) return w.id end,
    work_full_name = function(w) return w.name or "<unknown work>" end,
    work_suitability = function(w) return w.value end,
    prop = function(o, k) return o[k] end,
    valid = function(o) return type(o) == "table" end,
    has_authority = function() return true end,
}
package.loaded.log = { count = function() return {ms = 0} end,
    debug = function() end, warn = function(message) warnings[#warnings + 1] = message end, perf = false }
RegisterHook = function(_, fn) hook = fn end
local demand = require("demand")

-- Public-hook regressions also run against the former implementation: no
-- helper-only API is needed to demonstrate the old cross-camp contamination.
assert(demand.install() and hook)
local early_work = {id = "early", value = 8}
local early_director = {}
hook({get = function() return early_director end}, {get = function() return early_work end})
local early_counts = demand.for_camp("camp-early")
assert(early_counts[8] == nil, "unknown camp must not contribute demand to arbitrary bases")
early_director.BaseCampId = "camp-early"
hook({get = function() return early_director end}, {get = function() return early_work end})
early_counts = demand.for_camp("camp-early")
assert(early_counts[8] == 1, "repeat pulse must repair a previously unreadable camp")
demand.reset()

-- Unknown scope is isolated; nil requested scope cannot mean every base.
demand.observe("unknown", nil, 8, 100)
demand.observe("a", "camp-a", 5, 100)
demand.observe("b", "camp-b", 8, 100)
local counts, live, evidence = demand.for_camp("camp-a", 100)
assert(counts[5] == 1 and counts[8] == nil and live == 1)
assert(evidence.unknown_scope == 1)
counts, live = demand.for_camp(nil, 100)
assert(next(counts) == nil and live == 0)

-- A later pulse repairs both initially missing camp and suitability.
demand.observe("partial", nil, nil, 100)
demand.observe("partial", "camp-a", nil, 110)
counts, live, evidence = demand.for_camp("camp-a", 110)
assert(live == 2 and evidence.unknown_type == 1)
demand.observe("partial", nil, 8, 120)
counts = demand.for_camp("camp-a", 120)
assert(counts[8] == 1 and counts[5] == 1)
demand.observe("partial", nil, nil, 125)
counts = demand.for_camp("camp-a", 125)
assert(counts[8] == 1, "missing evidence must not erase resolved fields")

-- A conflicting known scope/type is a new generation, not stale merged data.
demand.observe("partial", "camp-b", nil, 130)
counts, live, evidence = demand.for_camp("camp-b", 130)
assert(counts[8] == 1 and evidence.unknown_type == 1)
demand.observe("partial", "camp-b", 4, 140)
counts = demand.for_camp("camp-b", 140)
assert(counts[4] == 1)
counts, live = demand.for_camp("camp-b", 186)
assert(next(counts) == nil and live == 0, "expired requests are not ready work")

-- Exercise the installed callback, including the formerly broken repeat path.
assert(demand.install() and hook)
local work = {id = "repeated"}
local director = {}
local context = {get = function() return director end}
local parameter = {get = function() return work end}
hook(context, parameter)
director.BaseCampId, work.value = "camp-c", 4
hook(context, parameter)
counts = demand.for_camp("camp-c")
assert(counts[4] == 1 and demand.last_pulse_at ~= nil)
demand.reset()
assert(demand.last_pulse_at == nil)
work = {name = "<unknown work>"}
hook(context, parameter)
assert(demand.last_pulse_at == nil, "an unidentified object is not authority evidence")
counts = demand.for_camp("camp-c")
assert(next(counts) == nil)

-- The hook wrapper must surface a body failure instead of silently looking
-- like a healthy pulse stream with no demand. The shared logger aggregates.
hook(context, {get = function() error("injected work read failure") end})
assert(#warnings == 1 and warnings[1]:find("required-work pulse could not be read", 1, true))
assert(warnings[1]:find("injected work read failure", 1, true) and demand.last_pulse_at == nil)
counts = demand.for_camp("camp-c")
assert(next(counts) == nil)
