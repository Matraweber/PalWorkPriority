-- Reuse the real renderer's existing UMG fixture, including its lifecycle and
-- layout assertions, then exercise public refresh/fill with a controlled clock.
dofile(TEST_ROOT .. '/tests/test_panel_render.lua')
local panel, icons, overlay = require('panel'), require('icons'), require('overlay')
local function upvalue(fn, wanted)
    for i=1,100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value, i end
    end
    error('missing upvalue ' .. wanted)
end
local rb = upvalue(panel.refresh, 'RB')
local cfg = rb.cfg
local original_clock, original_clear = os.clock, icons.new_frame
local now, retained, clears = 100, nil, 0
os.clock = function() return now end
icons.new_frame = function() retained = nil; clears = clears + 1 end

-- Error before the old tail cleanup, through the REAL refresh body. Preserve
-- the exact error object, clear icon scope, and permit the next maintenance.
local host, failure = overlay.host, {reason='fresh root unavailable'}
overlay.host = function() retained = {texture=true}; error(failure, 0) end
local ok, err = pcall(panel.refresh, cfg)
assert(not ok and err == failure and retained == nil and not rb.refreshing)
overlay.host = host
local host_calls = 0
overlay.host = function(...) host_calls = host_calls + 1; return host(...) end
panel.refresh(cfg)
panel.refresh(cfg)
assert(host_calls == 2, 'maintenance skipped current-tree discovery at the same timestamp')
overlay.host = host

-- Substitute only the inner draw to isolate scheduling and arbitrary return
-- shapes. Public refresh/fill and their scope/coordination remain real.
local body, body_index = upvalue(panel.refresh, 'refresh')
local calls, remaining, duration = 0, 4, 0
rb.pending = true
debug.setupvalue(panel.refresh, body_index, function(...)
    assert(select('#', ...) == 2 and select(2, ...) == 'argument')
    assert(retained == nil, 'refresh inherited an older texture scope')
    retained = {texture=true}
    assert(panel.fill_tick() == false, 'fill reentered the active refresh')
    calls = calls + 1
    return nil, false, 3, nil
end)
local result = table.pack(panel.refresh(cfg, 'argument'))
assert(result.n == 4 and result[1] == nil and result[2] == false
    and result[3] == 3 and result[4] == nil and retained == nil)

-- A closed-panel refresh may open and synchronously refresh again. Nested
-- maintenance is allowed, and the outer call must keep its fill guard.
debug.setupvalue(panel.refresh, body_index, function(_, nested)
    if nested then return 'opened' end
    assert(panel.refresh(cfg, true) == 'opened', 'immediate nested draw was skipped')
    assert(rb.refreshing and not panel.fill_tick(), 'nested draw released the outer guard')
end)
panel.refresh(cfg)
assert(not rb.refreshing)

debug.setupvalue(panel.refresh, body_index, function(received)
    assert(received == cfg)
    calls = calls + 1
    remaining = remaining - 1
    rb.pending = remaining > 0
    retained = {texture=true}
    now = now + duration
end)
panel.open, rb.pending = true, true
local before = calls
assert(not panel.fill_tick() and calls == before, 'same-time fill followed maintenance')
now = now + 0.015
assert(not panel.fill_tick(), 'continuation ran before its deadline')
now = now + 0.002
assert(panel.fill_tick() and calls == before + 1 and retained == nil)
assert(not panel.fill_tick(), 'duplicate fill ran without elapsed time')

-- The reverse order must not suppress maintenance or lose changed data.
panel.refresh(cfg)
assert(calls == before + 2, 'fill suppressed mandatory maintenance')
while rb.pending do now = now + 0.017; assert(panel.fill_tick()) end
assert(not panel.fill_tick(), 'completed page kept filling')

-- Deadline starts at completion, so a slow draw does not immediately refill.
remaining, duration, rb.pending = 3, 0.030, true
panel.refresh(cfg)
assert(not panel.fill_tick())
now = now + 0.017
assert(panel.fill_tick())
assert(not panel.fill_tick())

-- Failed continuation releases its scope and retries on a bounded next turn.
duration, rb.pending = 0, true
debug.setupvalue(panel.refresh, body_index, function()
    retained = {texture=true}
    error(failure, 0)
end)
now = now + 0.017
ok, err = pcall(panel.fill_tick)
assert(not ok and err == failure and retained == nil and not rb.refreshing)
assert(not panel.fill_tick(), 'failed fill retried immediately')
debug.setupvalue(panel.refresh, body_index, body)
panel.close()
now = now + 1
assert(not panel.fill_tick(), 'closed panel resumed a pending fill')
panel.refresh(cfg) -- closed/early return also owns and clears its icon scope
assert(retained == nil and clears > 0)
icons.new_frame, os.clock = original_clear, original_clock
