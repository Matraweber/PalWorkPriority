-- Checked, recoverable text generations. No in-place truncation of live data.
local M = {}
local log = require('log')
M.fs = { open = io.open, rename = os.rename, remove = os.remove }
local MAX_BYTES = 8 * 1024 * 1024

local function call(label, fn, ...)
    -- Only explicit profiling records these phases. Never log from the writer:
    -- the log sink itself writes files and would distort the measured work.
    local token = log.perf and log.begin(label) or nil
    local ok, a, b, c = pcall(fn, ...)
    if token then
        log.finish(token, (not ok or a == false or (a == nil and b ~= nil))
            and 'operation failed' or nil)
    end
    if not ok then return nil, tostring(a) end
    return a, b, c
end

local function checksum(s)
    local h = 2166136261
    for i = 1, #s do h = ((h ~ s:byte(i)) * 16777619) & 0xffffffff end
    return string.format('%08x', h)
end

function M.read_raw(path, phase)
    phase = phase or 'read'
    local f, err, code = call('save: '..phase..' open', M.fs.open, path, 'rb')
    if not f then return nil, err, code end
    local text, read_err = call('save: '..phase..' read', f.read, f, MAX_BYTES + 1)
    local closed, close_err = call('save: '..phase..' close', f.close, f)
    if not closed then return nil, close_err or 'close failed' end
    if text == nil then
        if read_err then return nil, read_err end
        text = '' -- read(n) returns nil at EOF for an empty file.
    end
    if #text > MAX_BYTES then return nil, 'file exceeds size limit' end
    return text
end

function M.write_raw(path, text)
    local f, err = call('save: temporary open write', M.fs.open, path, 'wb')
    if not f then return false, err end
    local wrote, write_err = call('save: temporary write', f.write, f, text)
    -- Diagnostic split only: fclose normally includes the buffered write.
    -- An explicit checked flush isolates that cost while profiling; it is not
    -- an async save, an fsync guarantee, or evidence that the stall disappeared.
    local flushed, flush_err = true, nil
    if wrote and log.perf then
        flushed, flush_err = call('save: temporary flush write', f.flush, f)
    end
    local closed, close_err = call('save: temporary close write', f.close, f)
    if not wrote then return false, write_err or 'write failed' end
    if not flushed then return false, flush_err or 'flush failed' end
    if not closed then return false, close_err or 'close failed' end
    return true
end

local function unpack_file(text)
    if text:sub(1, 11) ~= '# PWP-DATA ' then return text, 0 end
    local gen, size, sum, payload = text:match('^# PWP%-DATA 1 (%d+) (%d+) (%x+)\n(.*)$')
    gen, size = math.tointeger(tonumber(gen)), math.tointeger(tonumber(size))
    if not gen or not size or gen < 1 or #payload ~= size or checksum(payload) ~= sum then
        return nil, 'incomplete or corrupt generation'
    end
    return payload, gen
end

-- An editor may put a UTF-8 byte order mark in front of a hand edit. It used
-- to make the edit invalid, so a .bak quietly replaced it (review round 4).
local BOM = '\239\187\191'
local function without_bom(bytes)
    if bytes:sub(1, 3) == BOM then return bytes:sub(4) end
    return bytes
end

-- No envelope at all: a 0.4.1 file, or a hand edit that removed the line.
local function legacy(bytes) return bytes:sub(1, 11) ~= '# PWP-DATA ' end

-- The payload of a live file this version did not write, or nil. 0.5 installs
-- a live file only by renaming a verified .tmp into place, so a live file
-- with no envelope (gen 0) or a failed checksum came from 0.4.1 or from a
-- person editing it (review round 3).
local function outside_payload(bytes)
    -- Never an empty file: 0.4.1 always writes its header lines, so zero
    -- bytes is a failed write, not an edit.
    if bytes == '' then return nil end
    local payload, gen = unpack_file(bytes)
    if payload then return gen == 0 and payload or nil end
    return bytes:match('^# PWP%-DATA [^\n]*\n(.*)$')
end

-- validate(payload, lenient) returns a decoded table or nil,error. lenient
-- asks for 0.4.1's rule, which skipped a bad line and kept the rest: it is
-- used only for a live file with no envelope when nothing else can be read
-- (review round 4: one such line in a 0.4.1 file stopped the mod for good,
-- while a hand edit beside a good .bak still falls back to that .bak).
-- Never execute saves.
function M.read(path, validate)
    local best, errors, found, outside, highest, backed_up = nil, {}, false, nil, 0, false
    local old_format, unreadable = nil, false
    for _, suffix in ipairs({ '', '.tmp', '.pending', '.bak' }) do
        local bytes, err, code = M.read_raw(path .. suffix)
        if bytes and suffix == '' then bytes = without_bom(bytes) end
        if bytes then
            found = true
            if suffix == '.bak' then backed_up = true end
            local payload, gen = unpack_file(bytes)
            if type(gen) == 'number' and gen > highest then highest = gen end
            if payload and (suffix == '.tmp' or suffix == '.pending') and gen == 0 then
                payload, gen = nil, 'unfinished temporary generation has no integrity envelope'
            end
            local edited = suffix == '' and outside_payload(bytes) or nil
            if edited then
                -- A hand edit that kept the envelope line keeps its number too.
                local stated = math.tointeger(tonumber(bytes:match('^# PWP%-DATA 1 (%d+) ')))
                if stated and stated > highest then highest = stated end
                payload, gen = edited, 0
            end
            if payload then
                local value, why = validate(payload)
                if value == nil and edited and legacy(bytes) then old_format = payload end
                if value ~= nil then
                    if edited then
                        -- The newest edit there is: it wins over any older
                        -- generation, whose number it takes so saving goes on.
                        -- A body shorter than its envelope says may be a
                        -- copy cut off at a line end, not an edit.
                        local stated = math.tointeger(tonumber(bytes:match('^# PWP%-DATA 1 %d+ (%d+) ')))
                        outside = { value = value, generation = 0, source = path, recovered = false,
                            payload = payload, enveloped = bytes:sub(1, 11) == '# PWP-DATA ',
                            short = stated ~= nil and #payload < stated }
                    elseif not best or gen > best.generation then
                        best = { value = value, generation = gen, source = path .. suffix,
                            recovered = suffix ~= '', payload = payload }
                    end
                else errors[#errors + 1] = tostring(why) end
            else errors[#errors + 1] = tostring(gen) end
        elseif code ~= 2 then
            -- ENOENT alone proves absence; access errors must not mean a new install.
            errors[#errors + 1] = tostring(err)
            unreadable = true
        end
    end
    if old_format and not best and not outside and not unreadable then
        local value = validate(old_format, true)
        if value ~= nil then
            outside = { value = value, generation = 0, source = path, recovered = false,
                payload = old_format, enveloped = false }
        end
    end
    -- Every finished save of this version leaves a .bak. Without one, an
    -- unfinished .tmp or .pending is this version's interrupted first save on
    -- top of that live file, so it stays the newer copy.
    if outside and best and not backed_up and best.source ~= path .. '.bak' then outside = nil end
    if outside then
        -- Alone and without an envelope it is a plain 0.4.1 upgrade: read as
        -- it is and left unchanged on disk.
        if highest > 0 or outside.enveloped then
            outside.generation, outside.recovered = highest, true
            if outside.short then
                -- Review round 4: a copy cut off at a line end reads like an
                -- edit that removed rows. Say which it may be.
                log.warn(path .. " is shorter than its first line says: cut off by a crash or a sync "
                    .. "tool, or rows removed by hand. Using it; check your settings")
            else
                log.warn(path .. " was changed outside this version (by hand or by 0.4.1); "
                    .. "using it instead of the older saved copy")
            end
        end
        outside.enveloped, outside.short = nil, nil
        return outside.value, outside
    end
    if best then return best.value, best end
    if found or #errors > 0 then return nil, { error = table.concat(errors, '; '), state = 'error' } end
    return nil, { state = 'missing', generation = 0 }
end

-- One warning per skipped row, with the row itself, so the player can find it.
function M.warn_skipped(what, path, skipped)
    for i, line in ipairs(skipped or {}) do
        if i > 20 then
            log.warn(string.format('%s: %d more unreadable row(s) skipped', what, #skipped - 20))
            break
        end
        log.warn(string.format("%s: skipped unreadable row '%s' in %s, as 0.4.1 did",
            what, #line > 80 and (line:sub(1, 77) .. '...') or line, tostring(path)))
    end
end

function M.write(path, payload, generation, validate)
    local gen = (generation or 0) + 1
    if gen < 1 then return false, "generation out of range" end
    local bytes = string.format('# PWP-DATA 1 %d %d %s\n', gen, #payload, checksum(payload)) .. payload
    local tmp, bak = path .. '.tmp', path .. '.bak'
    -- A recovered temporary file may be the only surviving valid generation.
    -- Move it out of the write target BEFORE opening that target with wb.
    local old_tmp, tmp_err, tmp_code = M.read_raw(tmp, 'inspect temporary')
    if old_tmp == nil and tmp_code ~= 2 then return false, 'cannot inspect temporary save: ' .. tostring(tmp_err) end
    if old_tmp then
        local prior_payload, prior_gen = unpack_file(old_tmp)
        if prior_payload and prior_gen > 0 and (not validate or validate(prior_payload) ~= nil) then
            local pending = path .. '.pending'
            local older, pending_err, pending_code = M.read_raw(pending, 'inspect recovery')
            if older == nil and pending_code ~= 2 then return false, 'cannot inspect recovery copy: ' .. tostring(pending_err) end
            local keep_newer = false
            if older then
                local protected_payload, protected_gen = unpack_file(older)
                keep_newer = protected_payload ~= nil and protected_gen >= prior_gen
                    and (not validate or validate(protected_payload) ~= nil)
                if not keep_newer then
                    local removed, remove_err = call('save: rotate recovery', M.fs.remove, pending)
                    if not removed then return false, 'cannot rotate recovery copy: ' .. tostring(remove_err) end
                end
            end
            if not keep_newer then
                local protected, protect_err = call('save: protect temporary', M.fs.rename, tmp, pending)
                if not protected then return false, 'cannot protect recovered save: ' .. tostring(protect_err) end
            end
        end
    end
    local wrote, err = M.write_raw(tmp, bytes)
    if not wrote then return false, 'temporary write: ' .. tostring(err) end
    local checked, check_err = M.read_raw(tmp, 'verify temporary')
    if checked ~= bytes then return false, 'temporary verification: ' .. tostring(check_err or 'content mismatch') end
    local live, live_err, live_code = M.read_raw(path, 'inspect live')
    if not live and live_code ~= 2 then return false, 'cannot inspect previous save: ' .. tostring(live_err) end
    local previous, dropped = bak, false
    if live then
        -- A live file read as written by hand or by 0.4.1 was the one loaded,
        -- so it rotates to .bak like any other good generation.
        local plain = without_bom(live)
        local old_payload = unpack_file(plain) or outside_payload(plain)
        local valid_old = old_payload ~= nil and (not validate or validate(old_payload) ~= nil)
        if not valid_old and old_payload ~= nil and legacy(plain) then
            -- A 0.4.1 file read with 0.4.1's rule rotates to .bak like any
            -- loaded generation. Beside a .bak it was a refused edit.
            local _, _, bak_code = M.read_raw(bak, 'inspect backup')
            valid_old = bak_code == 2 and validate(old_payload, true) ~= nil
        end
        if not valid_old then
            -- Kept under a name of its own. A second bad edit in a row used to
            -- meet the first one's name and refuse every save for good
            -- (review round 3); the same bytes twice are kept once.
            previous = nil
            local base = path .. ".rejected." .. tostring(gen)
            for n = 1, 100 do
                local name = n == 1 and base or (base .. "." .. n)
                local kept, kept_err, kept_code = M.read_raw(name, 'inspect rejected')
                if kept == nil and kept_code ~= 2 then
                    return false, 'cannot inspect rejected copy: ' .. tostring(kept_err)
                end
                if kept == nil or kept == live then previous, dropped = name, kept == live; break end
            end
            if previous == nil then
                -- Nothing is overwritten to make room: saving stops until
                -- the player moves the old copies away (review round 4).
                return false, "too many rejected copies of " .. path .. " (100 for this generation); "
                    .. "move the " .. path .. ".rejected.* files out of the folder so saving can go on"
            end
        end
        if previous == bak then
            local old_bak, bak_err, bak_code = M.read_raw(bak, 'inspect backup')
            if not old_bak and bak_code ~= 2 then return false, 'cannot inspect backup: ' .. tostring(bak_err) end
            if old_bak then
                local removed, remove_err = call('save: rotate backup', M.fs.remove, bak)
                if not removed then return false, 'cannot rotate backup: ' .. tostring(remove_err) end
            end
        end
        if dropped then
            local removed, remove_err = call('save: drop duplicate rejected', M.fs.remove, path)
            if not removed then return false, 'cannot replace rejected save: ' .. tostring(remove_err) end
        else
            local moved, move_err = call('save: preserve live', M.fs.rename, path, previous)
            if not moved then return false, 'cannot preserve previous save: ' .. tostring(move_err) end
        end
    end
    local moved, move_err = call('save: install temporary', M.fs.rename, tmp, path)
    if not moved then
        -- Best effort restore. Even if this fails, .bak and the verified .tmp
        -- remain; a dropped duplicate still has its rejected copy.
        if live and not dropped then call('save: restore live', M.fs.rename, previous, path) end
        return false, 'cannot install save: ' .. tostring(move_err)
    end
    return true, nil, gen
end

return M
