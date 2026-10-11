-- Real icon queue/pump; no native calls, filesystem writes or elapsed claims.
local now, cost, loaded, timers, registrations, cancellations = 0, 0, {}, {}, 0, 0
local failing, on_load
package.loaded.log = {say=function() end, debug=function() end, warn=function() end}
package.loaded.clock = {
    every=function(name, ms, fn)
        assert(ms == 100)
        registrations = registrations + 1
        timers[name] = fn
    end,
    cancel=function(name) cancellations = cancellations + 1; timers[name] = nil end,
}
package.loaded.icondex = {NAMES={}, PATHS={}, FOLDER='/Test/Icons/'}
package.loaded.palapi = {}
local original_clock, original_open = os.clock, io.open
os.clock = function() return now end
io.open = function(_, mode) assert(mode == 'r', 'unexpected learned-name write'); return nil end
LoadAsset = function(path)
    loaded[#loaded + 1] = path
    now = now + cost
    if on_load then on_load(path) end
    if failing then error('load refused') end
end
local icons = require('icons')
io.open = original_open

-- Reach the real private enqueue routine without exporting a production API.
local function find_upvalue(fn, wanted, seen)
    seen = seen or {}
    if seen[fn] then return end
    seen[fn] = true
    for i=1,100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
        if type(value) == 'function' then
            local found = find_upvalue(value, wanted, seen)
            if found ~= nil then return found end
        end
    end
end
local want = assert(find_upvalue(icons.get, 'want'))
local function enqueue(prefix, n)
    for i=1,n do want(prefix .. i) end
end
local function beat()
    assert(timers.icons_pump, 'remaining queue lost its timer')()
end
local function leaf(path) return path:match('T_itemicon_([^%.]+)$') end

-- Coarse/non-advancing clock still respects the original twelve-load ceiling.
enqueue('Fast', 25)
assert(registrations == 1)
beat(); assert(#loaded == 12 and timers.icons_pump)
beat(); assert(#loaded == 24 and timers.icons_pump)
beat(); assert(#loaded == 25 and not timers.icons_pump and cancellations == 1)
for i=1,25 do assert(leaf(loaded[i]) == 'Fast' .. i, 'FIFO order changed') end

-- Stop between costly loads; every queued item eventually gets its turn.
loaded, cost = {}, 0.003
enqueue('Slow', 5)
beat(); assert(#loaded == 2 and timers.icons_pump)
beat(); assert(#loaded == 4 and timers.icons_pump)
beat(); assert(#loaded == 5 and not timers.icons_pump)
for i=1,5 do assert(leaf(loaded[i]) == 'Slow' .. i) end

-- Reaching the budget exactly must also yield before another native call.
loaded, now, cost = {}, 0, 0.004
enqueue('Boundary', 2)
beat(); assert(#loaded == 1 and timers.icons_pump)
beat(); assert(#loaded == 2 and not timers.icons_pump)

-- One native call may overrun. Failure does not stall or discard the suffix;
-- the existing requested/awaiting semantics remain unknown until discovery.
loaded, cost, failing = {}, 0.020, true
enqueue('Fault', 3)
beat(); assert(#loaded == 1 and timers.icons_pump)
want('Fault1'); want('Fault2') -- no duplicate retry/queued entry
failing = false
beat(); assert(#loaded == 2)
beat(); assert(#loaded == 3 and not timers.icons_pump)
for i=1,3 do assert(leaf(loaded[i]) == 'Fault' .. i) end

-- New work enqueued while loading joins the same FIFO and registration.
loaded, cost = {}, 0.005
enqueue('Append', 2)
local before = registrations
on_load = function() want('Append3'); on_load = nil end
beat(); beat(); beat()
assert(registrations == before and #loaded == 3 and not timers.icons_pump)
for i=1,3 do assert(leaf(loaded[i]) == 'Append' .. i) end
enqueue('Cancel', 2)
icons.shutdown()
assert(not timers.icons_pump, 'shutdown left a pump scheduled')
os.clock = original_clock
