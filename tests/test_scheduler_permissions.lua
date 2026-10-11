local permissions = require("scheduler_permissions")
local h, capable = permissions.new(), {[5] = true, [8] = true}
assert(next(permissions.observe(h, {[8] = true}, capable)) == nil,
    "first observation has no confirmed comparison state")
permissions.confirm(h, {}, {[5] = true, [8] = true}, capable)
local changes = permissions.observe(h, {[8] = true}, capable)
assert(changes[8] == false and changes[5] == nil)
permissions.accept(h, 8, false)
assert(next(permissions.observe(h, {[8] = true}, capable)) == nil)
changes = permissions.observe(h, {}, capable)
assert(changes[8] == true)

-- Sent writes stay pending until native readback matches them. In particular,
-- false must survive the table/value handling rather than acting like nil.
permissions.sent(h, 5, false)
assert(h.pending[5] == false and h.confirmed[5] == true)
changes = permissions.observe(h, {}, capable)
assert(changes[5] == nil and h.pending[5] == false)
permissions.confirm(h, {}, {}, capable)
assert(h.pending[5] == false and h.confirmed[5] == true)
changes = permissions.observe(h, {[5] = true, [8] = true}, capable)
assert(changes[5] == nil and h.pending[5] == nil and h.confirmed[5] == false)
changes = permissions.observe(h, {[8] = true}, capable)
assert(changes[5] == true)

local fresh = permissions.new()
assert(not permissions.confirm(fresh, nil, {}, capable))
assert(next(fresh.confirmed) == nil and next(permissions.observe(fresh, nil, capable)) == nil)

-- A request's diagnostic deadline never restarts, and opposite requests may
-- not overwrite it. Expiry is unresolved delivery, NOT an external edit.
local stuck = permissions.new()
permissions.confirm(stuck, {}, {[5] = true, [8] = true}, capable)
assert(permissions.sent(stuck, 5, false, 100))
assert(not permissions.sent(stuck, 5, false, 110))
assert(not permissions.sent(stuck, 5, true, 120))
local n, expired = permissions.status(stuck, 131)
assert(n == 1 and expired == 1 and stuck.sent_at[5] == 100)
changes = permissions.observe(stuck, {[8] = true}, capable)
assert(changes[8] == false and changes[5] == nil,
    "one uncertain type must not mask confirmed external changes to other types")
permissions.accept(stuck, 8, false)
changes = permissions.observe(stuck, {[5] = true, [8] = true}, capable)
assert(next(changes) == nil and permissions.status(stuck, 140) == 0,
    "late mod delivery is an acknowledgement, never a fabricated vanilla edit")
