-- Pure Lua wire validation. No engine wrappers or partial state escape here.
-- Schema 4 adds selected-scope storage; schema 3 peers must not receive S.
-- Session-bound server availability control remains required. The existing
-- PWP_V2 envelope framing is retained; Hello/Welcome negotiate this schema.
local M = { SCHEMA = 4, WORKS = 14, MAX_PACKET = 768,
    MAX_PALS = 512, MAX_RULES = 500, MAX_BYTES = 524288, TIMEOUT = 10,
    MAX_STORAGE_ITEMS = 512, MAX_STORAGE_CAMPS = 32, MAX_STORAGE_CHUNKS = 32,
    MAX_STORAGE_BYTES = 16384, MAX_STORAGE_MS = 60000, MAX_STORAGE_AMOUNT = 2147483647 }

function M.integer(value, low, high)
    local n = tonumber(value)
    if not n or n ~= n or n ~= math.floor(n) or n < low or n > high then return nil end
    return n
end

function M.token(value, maximum)
    return type(value) == "string" and #value > 0 and #value <= (maximum or 128)
        and value:match("^[%w_%-]+$") ~= nil
end

-- Item identifiers share the durable rule grammar; dots in a legitimate item
-- ID must survive a snapshot or the whole valid rule set becomes unavailable.
function M.item(value)
    return type(value) == "string" and #value > 0 and #value <= 64
        and value:match("^[%w_%.%-]+$") ~= nil
end

function M.parts(text)
    if type(text) ~= "string" or #text > M.MAX_PACKET or text:find("[%c]") then return nil end
    local result = {}
    for s in (text .. "|"):gmatch("(.-)|") do result[#result + 1] = s end
    return result
end

function M.priority(value)
    if value == false then return "X" end
    if value == nil then return "-" end
    local n = M.integer(value, 1, 5)
    if n then return tostring(n) end
    return nil
end

function M.decode_priority(value)
    if value == "X" then return false end
    if value == "-" then return nil end
    return M.integer(value, 1, 5)
end

function M.pal_key(key)
    return M.token(key) and not key:lower():match("^slot%d+$")
end

function M.row(stream, payload)
    local p = M.parts(payload)
    if not p or #p ~= 3 then return nil end
    if stream == "P" then
        if not M.pal_key(p[1]) or #p[2] ~= M.WORKS or #p[3] ~= M.WORKS
            or p[2]:find("[^0-9]") or p[3]:find("[^1-5X%-]") then return nil end
        local ranks, prios = {}, {}
        for i = 1, M.WORKS do
            local r = tonumber(p[2]:sub(i, i))
            if r > 0 then ranks[i] = r end
            prios[i] = M.decode_priority(p[3]:sub(i, i))
        end
        return p[1], { key = p[1], ranks = ranks, prios = prios }
    elseif stream == "R" then
        local n = M.integer(p[3], 1, 9999999)
        if not M.token(p[1], 64) or not M.item(p[2]) or not n then return nil end
        return p[1] .. "|" .. p[2], { work = p[1], item = p[2], amount = n }
    elseif stream == "S" then
        return M.storage_row(p)
    end
    return nil
end

function M.edit(parts)
    local verb = parts[1]
    if verb == "Prio" and #parts == 4 then
        if not M.pal_key(parts[2]) or not M.integer(parts[3], 1, M.WORKS)
            or not parts[4]:match("^[1-5X%-]$") then return nil end
    elseif verb == "Set" and #parts == 4 then
        if not M.token(parts[2], 64) or not M.item(parts[3])
            or not M.integer(parts[4], 1, 9999999) then return nil end
    elseif verb == "Clear" and #parts == 3 then
        if not M.token(parts[2], 64) or not M.item(parts[3]) then return nil end
    else return nil end
    return "PWP_" .. table.concat(parts, "|")
end

-- Adler-style checksum detects omitted, reordered or altered row payloads.
-- Authorization still comes from the actual RPC sender, not this checksum.
function M.checksum(rows)
    local a, b = 1, 0
    for _, row in ipairs(rows) do
        for i = 1, #row do
            a = (a + row:byte(i)) % 65521
            b = (b + a) % 65521
        end
        a = (a + 10) % 65521
        b = (b + a) % 65521
    end
    return tostring(b * 65536 + a)
end

local function envelope(kind, server, client, guild)
    return table.concat({ "PWP_V2", kind, server, client, guild }, "|")
end

local function storage_scope(scope, camp)
    if scope == "guild" and camp == nil then return "G" end
    if scope == "camp" and camp == nil then return "N" end -- unavailable, no camp resolved
    if scope == "camp" and M.token(camp) then return "C:" .. camp end
end

local function finite_time(now)
    return type(now) == "number" and now == now and now >= 0 and now < math.huge
end

-- Decimal fields only: no exponent, sign, whitespace or NaN.
local function decimal(value, high)
    if type(value) ~= "string" or not value:match("^%d+$") then return nil end
    return M.integer(value, 0, high)
end

function M.storage_row(p)
    local scope = p[1]
    if scope ~= "G" and scope ~= "N"
        and not (scope:sub(1, 2) == "C:" and M.token(scope:sub(3))) then return nil end
    local request, age, remaining, verified, items, camps = p[2]:match(
        "^M:([%w_%-]+):(%d+):(%d+):([01]):(%d+):(%d+)$")
    if request then
        age, remaining = decimal(age, M.MAX_STORAGE_MS), decimal(remaining, M.MAX_STORAGE_MS)
        items, camps = decimal(items, M.MAX_STORAGE_ITEMS), decimal(camps, M.MAX_STORAGE_CAMPS)
        if not M.token(request, 64) or not age or not remaining or not items or not camps
            or p[3] ~= "-" or age + remaining > M.MAX_STORAGE_MS then return nil end
        if verified == "0" and (items ~= 0 or age ~= 0 or remaining ~= 0) then return nil end
        if verified == "1" and (remaining == 0 or scope == "N") then return nil end
        return "M", { scope_key = scope, kind = "M", request = request, age_ms = age,
            remaining_ms = remaining, verified = verified == "1", item_count = items, camp_count = camps }
    end
    local kind, index = p[2]:match("^([CI]):(%d+)$")
    index = index and decimal(index, M.MAX_STORAGE_CHUNKS)
    if not index or index < 2 or p[3] == "" then return nil end
    local values, count = {}, 0
    for pair in (p[3] .. ","):gmatch("(.-),") do
        local key, amount = pair:match("^([^=]+)=(%d+)$")
        amount = amount and decimal(amount, M.MAX_STORAGE_AMOUNT)
        if not key or not amount or values[key] ~= nil
            or (kind == "C" and (not M.token(key) or amount ~= 1))
            or (kind == "I" and not M.item(key)) then return nil end
        values[key], count = amount, count + 1
        if count > (kind == "C" and M.MAX_STORAGE_CAMPS or M.MAX_STORAGE_ITEMS) then return nil end
    end
    return kind .. ":" .. index, { scope_key = scope, kind = kind, index = index, values = values }
end

-- Structural completeness is checked across ALL chunks before a candidate
-- escapes. A sender must supply complete, ownership-verified totals; a checksum
-- establishes neither RPC authority nor the completeness of an engine scan.
local function storage_rows(rows)
    if #rows < 1 or #rows > M.MAX_STORAGE_CHUNKS then return nil end
    local _, meta = M.row("S", rows[1])
    if not meta or meta.kind ~= "M" then return nil end
    local totals, choices, seen, items, bytes = {}, {}, {}, 0, #rows[1]
    for i = 2, #rows do
        local _, row = M.row("S", rows[i])
        if not row or row.kind == "M" or row.index ~= i or row.scope_key ~= meta.scope_key then return nil end
        bytes = bytes + #rows[i]
        if bytes > M.MAX_STORAGE_BYTES then return nil end
        for key, amount in pairs(row.values) do
            if row.kind == "C" then
                if seen[key] then return nil end
                seen[key], choices[#choices + 1] = true, key
                if #choices > M.MAX_STORAGE_CAMPS then return nil end
            else
                if totals[key] ~= nil then return nil end
                totals[key], items = amount, items + 1
                if items > M.MAX_STORAGE_ITEMS then return nil end
            end
        end
    end
    if items ~= meta.item_count or #choices ~= meta.camp_count then return nil end
    local camp = meta.scope_key:sub(1, 2) == "C:" and meta.scope_key:sub(3) or nil
    if meta.verified and camp and not seen[camp] then return nil end
    table.sort(choices)
    return { scope = meta.scope_key == "G" and "guild" or "camp", camp = camp, choices = choices,
        verified = meta.verified, totals = totals, age_ms = meta.age_ms,
        remaining_ms = meta.remaining_ms }, meta.request
end

-- view = {scope, camp?, choices=array, verified=boolean, totals=FULL map,
--         age_ms, remaining_ms}. Age comes from the underlying sampled_at,
-- never from a scheduler pass/cache reuse. Encode when the drip begins, not
-- when it is queued; every queued batch remains bound to its request/session.
-- nil, reason means unavailable: send an explicit verified=false view instead.
function M.storage_snapshot(server, client, guild, revision, request, view)
    if type(view) ~= "table" or not M.token(request, 64)
        or type(view.verified) ~= "boolean" or type(view.totals) ~= "table"
        or type(view.choices) ~= "table" then return nil, "invalid_storage" end
    local scope = storage_scope(view.scope, view.camp)
    local age = M.integer(view.age_ms, 0, M.MAX_STORAGE_MS)
    local remaining = M.integer(view.remaining_ms, 0, M.MAX_STORAGE_MS)
    if not scope or not age or not remaining or age + remaining > M.MAX_STORAGE_MS
        or (view.verified and (remaining == 0 or scope == "N"))
        or (not view.verified and (age ~= 0 or remaining ~= 0)) then return nil, "invalid_storage" end
    local items, camps, seen = {}, {}, {}
    for item, amount in pairs(view.totals) do
        if not M.item(item) or type(amount) ~= "number" or not M.integer(amount, 0, M.MAX_STORAGE_AMOUNT)
            or not view.verified then return nil, "invalid_storage" end
        items[#items + 1] = item
        if #items > M.MAX_STORAGE_ITEMS then return nil, "storage_too_large" end
    end
    for index, camp in pairs(view.choices) do
        if type(index) ~= "number" or not M.integer(index, 1, M.MAX_STORAGE_CAMPS)
            or not M.token(camp) or seen[camp] then return nil, "invalid_storage" end
        seen[camp], camps[#camps + 1] = true, camp
        if #camps > M.MAX_STORAGE_CAMPS then return nil, "storage_too_large" end
    end
    for i = 1, #camps do if view.choices[i] == nil then return nil, "invalid_storage" end end
    if view.verified and view.camp and not seen[view.camp] then return nil, "invalid_storage" end
    table.sort(items); table.sort(camps)
    if not M.token(server, 64) or not M.token(client, 64) or not M.token(guild)
        or not M.integer(revision, 1, 2147483647) then return nil, "invalid_storage" end
    local rows = { scope .. "|M:" .. request .. ":" .. string.format("%.0f:%.0f", age, remaining) .. ":"
        .. (view.verified and "1" or "0") .. ":" .. #items .. ":" .. #camps .. "|-" }
    local function chunks(kind, keys, values)
        local chunk = ""
        local function prefix()
            return scope .. "|" .. kind .. ":" .. (#rows + 1) .. "|"
        end
        for _, key in ipairs(keys) do
            local pair = key .. "=" .. string.format("%.0f", values and values[key] or 1)
            local joined = chunk == "" and pair or chunk .. "," .. pair
            local overhead = #envelope("D", server, client, guild) + #( "|S|" .. revision .. "|" .. (#rows + 1) .. "|")
            if overhead + #prefix() + #joined > M.MAX_PACKET then
                if chunk == "" then return false end
                rows[#rows + 1], chunk = prefix() .. chunk, pair
                overhead = #envelope("D", server, client, guild) + #( "|S|" .. revision .. "|" .. (#rows + 1) .. "|")
                if overhead + #prefix() + #pair > M.MAX_PACKET then return false end
            else chunk = joined end
            if #rows >= M.MAX_STORAGE_CHUNKS then return false end
        end
        if chunk ~= "" then rows[#rows + 1] = prefix() .. chunk end
        return true
    end
    if not chunks("C", camps) or not chunks("I", items, view.totals) then return nil, "storage_too_large" end
    local batch = M.snapshot(server, client, guild, "S", revision, "F", rows)
    if not batch then return nil, "storage_too_large" end
    return batch
end

function M.snapshot(server, client, guild, stream, revision, mode, rows)
    local limit = stream == "S" and M.MAX_STORAGE_CHUNKS or (stream == "P" and M.MAX_PALS or M.MAX_RULES)
    if not M.token(server, 64) or not M.token(client, 64) or not M.token(guild)
        or (stream ~= "P" and stream ~= "R" and stream ~= "S") or (mode ~= "F" and mode ~= "D")
        or (stream ~= "P" and mode ~= "F") or not M.integer(revision, 1, 2147483647)
        or #rows > limit or (mode == "D" and #rows ~= 1) then return nil end
    if stream == "S" and not storage_rows(rows) then return nil end
    local seen, bytes = {}, 0
    local batch = { envelope("B", server, client, guild) .. "|" .. stream .. "|"
        .. revision .. "|" .. mode .. "|" .. #rows }
    for i, payload in ipairs(rows) do
        local key = M.row(stream, payload)
        if not key or seen[key] then return nil end
        seen[key] = true
        bytes = bytes + #payload
        if mode == "D" then
            -- A single-row delta is intrinsically complete. Keep it one RPC,
            -- with the same scope, revision, width and checksum validation.
            local delta = envelope("U", server, client, guild) .. "|P|" .. revision
                .. "|" .. payload .. "|" .. M.checksum(rows)
            if #delta > M.MAX_PACKET then return nil end
            return { delta }
        end
        local wire = envelope("D", server, client, guild) .. "|" .. stream .. "|"
            .. revision .. "|" .. i .. "|" .. payload
        if #wire > M.MAX_PACKET or bytes > M.MAX_BYTES then return nil end
        batch[#batch + 1] = wire
    end
    batch[#batch + 1] = envelope("E", server, client, guild) .. "|" .. stream
        .. "|" .. revision .. "|" .. #rows .. "|" .. M.checksum(rows)
    return batch
end

function M.receiver(server, client, guild)
    return { server = server, client = client, guild = guild, buffers = {},
        pending = {}, revisions = { P = 0, R = 0, S = 0 }, full = { P = false, R = false, S = false },
        resync = { P = true, R = true, S = true } }
end

function M.invalidate(state, stream)
    if stream == "P" or stream == "R" or stream == "S" then
        state.buffers[stream], state.pending[stream] = nil, nil
        state.resync[stream] = true
        if stream == "S" then
            state.storage_request, state.storage_deadline, state.storage_ignored_revision = nil, nil, nil
        end
    else
        M.invalidate(state, "P")
        M.invalidate(state, "R")
        M.invalidate(state, "S")
    end
end

-- Call BEFORE sending; request IDs must be unique within a receiver session.
-- This also opts into S and invalidates the previous selection immediately.
-- scope=nil lets the server select its configured scope. With camp=nil any
-- selected camp is allowed; with camp=ID only that camp or guild scope is
-- allowed. N (unavailable, no camp resolved) is safe in either automatic mode.
function M.expect_storage(state, request, scope, camp, now)
    local key = storage_scope(scope, camp)
    if (not key and (scope ~= nil or (camp ~= nil and not M.token(camp))))
        or not M.token(request, 64) or not finite_time(now)
        or (state.storage_request and state.storage_request.id == request) then return false end
    M.invalidate(state, "S")
    state.storage_request = { id = request, scope_key = key, selected = camp, started = now }
    return true
end

function M.ready(state)
    return state.full.P and state.full.R and not state.resync.P and not state.resync.R
end

-- Validation produces a candidate. Only the consumer can confirm that its
-- domain state actually accepted it; an application failure consumes no revision.
function M.commit(state, event, now)
    if type(event) ~= "table" or state.pending[event.stream] ~= event
        or event.session ~= state.server or event.client_session ~= state.client
        or event.guild ~= state.guild or event.revision <= state.revisions[event.stream] then return false end
    if event.mode == "D" and state.resync[event.stream] then return false end
    if event.stream == "S" then
        local request = state.storage_request
        if not request or event.request ~= request.id or request.consumed
            or not finite_time(now) or now < event.started or now - event.started >= M.TIMEOUT
            or now - request.started >= M.MAX_STORAGE_MS / 1000
            or (event.storage.verified and now >= event.expires_at) then return false end
        request.consumed = true
        state.storage_deadline = event.storage.verified and event.expires_at or nil
    end
    state.revisions[event.stream], state.pending[event.stream] = event.revision, nil
    if event.mode == "F" then
        state.full[event.stream], state.resync[event.stream] = true, false
    end
    return true
end

local function stage(state, event, now)
    event.started = now
    state.pending[event.stream] = event
    return event
end

function M.expire(state, now)
    local expired, streams = false, {}
    if state.storage_request and (not finite_time(now) or now < state.storage_request.started
        or now - state.storage_request.started >= M.MAX_STORAGE_MS / 1000
        or (state.storage_deadline and now >= state.storage_deadline)) then
        M.invalidate(state, "S")
        expired, streams.S = true, true
    end
    for stream, batch in pairs(state.buffers) do
        if now - batch.started >= M.TIMEOUT then
            M.invalidate(state, stream)
            expired, streams[stream] = true, true
        end
    end
    for stream, event in pairs(state.pending) do
        if now - event.started >= M.TIMEOUT
            or (stream == "S" and event.storage.verified and now >= event.expires_at) then
            M.invalidate(state, stream)
            expired, streams[stream] = true, true
        end
    end
    return expired, streams
end

function M.receive(state, wire, now)
    local p = M.parts(wire)
    if not p or p[1] ~= "PWP_V2" then return nil, "invalid_packet" end
    if p[3] ~= state.server or p[4] ~= state.client or p[5] ~= state.guild then
        return nil, "wrong_session"
    end
    local kind, stream = p[2], p[6]
    if stream ~= "P" and stream ~= "R" and stream ~= "S" then
        M.invalidate(state)
        return nil, "invalid_stream"
    end
    if stream == "S" then
        local request = state.storage_request
        if not request or request.consumed then return nil, "storage_unrequested" end
        if not finite_time(now) or now < request.started
            or now - request.started >= M.MAX_STORAGE_MS / 1000 then
            M.invalidate(state, "S")
            return nil, "storage_expired"
        end
    end
    local revision = M.integer(p[7], 1, 2147483647)
    if not revision or revision <= state.revisions[stream] then return nil, "stale_revision" end
    if stream == "S" and revision == state.storage_ignored_revision then return nil, "wrong_storage_request" end
    local batch = state.buffers[stream]
    if batch and revision < batch.revision then return nil, "stale_revision" end
    if stream == "S" and state.pending.S and revision <= state.pending.S.revision then return nil, "stale_revision" end
    local function reject(reason)
        M.invalidate(state, stream)
        return nil, reason
    end
    if kind == "U" then
        if #p ~= 11 or stream ~= "P" or not state.full.P or state.resync.P then return reject("invalid_delta") end
        if revision ~= state.revisions.P + 1 then return reject("delta_revision_gap") end
        local payload = table.concat({p[8], p[9], p[10]}, "|")
        local key, row = M.row("P", payload)
        if not key or p[11] ~= M.checksum({payload}) then return reject("invalid_delta") end
        if batch and batch.revision <= revision then state.buffers.P = nil end
        return stage(state, { stream = "P", mode = "D", revision = revision,
            session = state.server, client_session = state.client, guild = state.guild, rows = {row} }, now)
    end
    if kind == "B" then
        local limit = stream == "S" and M.MAX_STORAGE_CHUNKS or (stream == "P" and M.MAX_PALS or M.MAX_RULES)
        local count = M.integer(p[9], 0, limit)
        if #p ~= 9 or not count or (stream == "S" and count == 0) or (p[8] ~= "F" and p[8] ~= "D")
            or (p[8] == "D" and (stream ~= "P" or count ~= 1 or not state.full.P or state.resync.P)) then
            return reject("invalid_begin")
        end
        if p[8] == "D" and revision ~= state.revisions.P + 1 then
            return reject("delta_revision_gap")
        end
        if batch and revision <= batch.revision then return nil, "stale_revision" end
        if stream == "S" then state.pending.S = nil end
        state.buffers[stream] = { revision = revision, mode = p[8], count = count,
            started = now, rows = {}, keys = {}, parsed = {}, received = 0, bytes = 0 }
        return nil
    end
    if not batch or batch.revision ~= revision then return reject("missing_begin") end
    if now - batch.started >= M.TIMEOUT then return reject("snapshot_timeout") end
    if kind == "D" then
        if #p ~= 11 then return reject("invalid_row") end
        local index = M.integer(p[8], 1, batch.count)
        local payload = table.concat({ p[9], p[10], p[11] }, "|")
        local key, row = M.row(stream, payload)
        if not index or not key then return reject("invalid_row") end
        if stream == "S" then
            local request = state.storage_request
            local matches = request.scope_key and row.scope_key == request.scope_key
                or (not request.scope_key and (row.scope_key == "G" or row.scope_key == "N"
                    or not request.selected or row.scope_key == "C:" .. request.selected))
            if not matches or (row.kind == "M" and row.request ~= request.id) then
                -- A delayed response must not cancel the outstanding selection.
                state.buffers.S, state.storage_ignored_revision = nil, revision
                return nil, "wrong_storage_request"
            end
            if (index == 1) ~= (row.kind == "M") or (row.kind ~= "M" and row.index ~= index) then
                return reject("invalid_row")
            end
        end
        if batch.rows[index] == payload then return nil end -- reliable duplicate
        if batch.rows[index] or batch.keys[key] then return reject("duplicate_row") end
        batch.bytes = batch.bytes + #payload
        if batch.bytes > (stream == "S" and M.MAX_STORAGE_BYTES or M.MAX_BYTES) then return reject("snapshot_too_large") end
        batch.rows[index], batch.parsed[index], batch.keys[key] = payload, row, true
        batch.received = batch.received + 1
        return nil
    elseif kind == "E" then
        if #p ~= 9 or M.integer(p[8], 0, M.MAX_PALS) ~= batch.count
            or batch.received ~= batch.count or p[9] ~= M.checksum(batch.rows) then
            return reject("incomplete_snapshot")
        end
        state.buffers[stream] = nil
        local event = { stream = stream, mode = batch.mode, revision = revision,
            session = state.server, client_session = state.client,
            guild = state.guild, rows = batch.parsed }
        if stream == "S" then
            local view, request = storage_rows(batch.rows)
            if not view or request ~= state.storage_request.id then return reject("invalid_storage") end
            local elapsed = math.ceil((now - state.storage_request.started) * 1000)
            if view.verified then
                if elapsed >= view.remaining_ms then return reject("storage_expired") end
                view.age_ms, view.remaining_ms = view.age_ms + elapsed, view.remaining_ms - elapsed
            end
            event.storage, event.request = view, request
            event.received_at, event.expires_at = now, now + view.remaining_ms / 1000
        end
        return stage(state, event, now)
    end
    return reject("invalid_kind")
end

M.envelope = envelope
return M
