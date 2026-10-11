-- Actual scheduler + store + caps + datafile; only engine/file boundaries are
-- replaced. No installation files or native game objects are touched.
local noop = function() end
package.loaded.log = {info = noop, debug = noop, warn = noop, error = noop, say = noop}
package.loaded.trace = {at = noop, done = noop}
package.loaded.demand = {live = function() return true end,
    for_camp = function() return {}, 0, {} end}
local file = require("datafile")
local fs = require("memory_fs")()
file.fs = fs
local store, caps = require("store"), require("caps")
local roster, sent = {}, {}
local api = {
    camps_available = true,
    base_camps = function() return {{}} end,
    camp_id = function() return "camp" end,
    camp_guild = function() return "guild" end,
    guid_key = function(id) return id end,
    latch_authority = function() return true end,
    has_authority = function() return true end,
    owned_network_component = function() return "component" end,
    current_work_suitability = function() return nil end,
    suitability_rank = function(param, value) return param.ranks[value] or 0 end,
    work_off_set = function(param)
        local out = {}; for value in pairs(param.off) do out[value] = true end; return out
    end,
    camp_pals = function()
        local out = {}
        for _, p in ipairs(roster) do out[#out + 1] = {key = p.key, id = p.key, name = p.key, param = p} end
        return out
    end,
    set_work_enabled = function(id, value, on)
        assert(store.state == "saved" and store.decided and not store.is_client)
        assert(caps.state == "saved" and caps.decided and not caps.is_client)
        sent[#sent + 1] = {id = id, value = value, on = on}
        for _, p in ipairs(roster) do if p.key == id then p.off[value] = not on end end
        return true
    end,
}
package.loaded.palapi = api
local scheduler = require("scheduler")
local workdefs = require("workdefs")
local cfg = {work_priority = {}, assignment_mode = "fill", max_pals_per_work_type = 1,
    min_suitability_rank = 1, interval_seconds = 10, storage_scope = "camp", dry_run = false}
for _, name in ipairs(workdefs.ORDER) do cfg.work_priority[name] = 1 end
local function reset()
    fs.files, fs.fault, fs.operations = {}, nil, {}
    assert(file.write("priorities", "# baseline=vanilla\n", 0))
    assert(file.write("caps", "# no limits\n", 0))
    store.load("priorities"); store.set_role("authority")
    caps.load("caps"); caps.set_role("authority", 1)
    scheduler.forget()
    scheduler.assignment_reader = function() return {state = "ready", manual = false} end
    roster = {
        {key = "weak", ranks = {[8] = 1}, off = {}},
        {key = "strong", ranks = {[8] = 4}, off = {}},
    }
    sent = {}
end

reset()
local previous = fs.files.priorities
fs.fault = function(op, path) return op == "write" and path == "priorities.tmp" end
local stats = scheduler.run_pass(cfg)
assert(store.state == "error" and store.data.weak and store.data.weak[8] == 1)
assert(#sent == 0 and stats.blocked, "failed baseline capture must prevent fencing")
assert(fs.files.priorities == previous)

-- A second edit changes error -> saving, but the newly captured baseline is
-- still only in memory. Merely checking the state for 'error' misses this.
assert(store.apply_set("other", 5, false) and store.state == "saving")
stats = scheduler.run_pass(cfg)
assert(#sent == 0 and stats.blocked and fs.files.priorities == previous)
fs.fault = nil
assert(store.flush(nil, true))
stats = scheduler.run_pass(cfg)
assert(#sent == 1 and sent[1].id == "weak" and not sent[1].on)
assert(store.state == "saved" and store.data.strong[8] == 1)
store.load("priorities"); store.set_role("authority")
assert(store.data.weak[8] == 1 and store.data.strong[8] == 1 and store.data.other[5] == false)

-- Durable capture callbacks can change role. The scheduler must recheck
-- after saving, before native writes or preparing the next Pal's baseline.
reset()
store.on_change = function() store.set_role("client") end
stats = scheduler.run_pass(cfg)
assert(stats.blocked and #sent == 0 and store.data.strong == nil)

-- Native bit changes cannot identify a deliberate player edit. They must not
-- rewrite a saved priority, dirty the file, or attempt a save at all.
reset()
cfg.max_pals_per_work_type = 3
scheduler.run_pass(cfg) -- durable baselines and readback-confirmed permissions
assert(#sent == 0)
roster[1].off[8] = true -- unattributed unchecked change
local persisted, operations = fs.files.priorities, #fs.operations
fs.fault = function(op, path) return op == "close" and path == "priorities.tmp" end
stats = scheduler.run_pass(cfg)
assert(not stats.blocked and store.state == "saved" and store.data.weak[8] == 1)
assert(fs.files.priorities == persisted and #fs.operations == operations,
    "native observation attempted to save a new priority")

-- An explicit priority edit still must save successfully before the scheduler
-- can apply any other permission changes in the pass.
sent = {}
assert(store.apply_set("weak", 8, false))
assert(not store.flush(nil, true))
stats = scheduler.run_pass(cfg)
assert(stats.blocked and #sent == 0 and store.state == "error" and store.data.weak[8] == false)
fs.fault = nil
assert(store.flush(nil, true))
stats = scheduler.run_pass(cfg)
assert(#sent == 0 and not stats.blocked)
store.load("priorities"); store.set_role("authority")
assert(store.data.weak[8] == false)

-- Public scheduling/restoration cannot use in-memory rules while their
-- persistence module is undecided, client-owned, failed, or unknown state.
for _, state in ipairs({"error", "unavailable", "unexpected"}) do
    caps.state = state
    assert(scheduler.run_pass(cfg).blocked and scheduler.restore(cfg).blocked and #sent == 0)
end
caps.state, caps.decided = "saved", false
assert(scheduler.run_pass(cfg).blocked and #sent == 0)

-- Recovery can begin in a reflected lookup after the initial readiness check.
-- It must stop both the RPC and its pending-permission bookkeeping.
reset();cfg.max_pals_per_work_type=1
local Gate=require('settings_gate')
local token
api.owned_network_component=function()token=assert(Gate.acquire());return 'component'end
stats=scheduler.run_pass(cfg)
assert(stats.blocked and #sent==0 and token)
assert(Gate.release(token))
api.owned_network_component=function()return 'component'end
stats=scheduler.run_pass(cfg)
assert(#sent==1 and sent[1].id=='weak','blocked lookup must not poison pending permissions')
