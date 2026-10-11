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

-- validate(payload) returns a decoded table or nil,error. Never execute saves.
function M.read(path, validate)
    local best, errors, found = nil, {}, false
    for _, suffix in ipairs({ '', '.tmp', '.pending', '.bak' }) do
        local bytes, err, code = M.read_raw(path .. suffix)
        if bytes then
            found = true
            local payload, gen = unpack_file(bytes)
            if payload and (suffix == '.tmp' or suffix == '.pending') and gen == 0 then
                payload, gen = nil, 'unfinished temporary generation has no integrity envelope'
            end
            if payload then
                local value, why = validate(payload)
                if value ~= nil then
                    if not best or gen > best.generation then
                        best = { value = value, generation = gen, source = path .. suffix,
                            recovered = suffix ~= '', payload = payload }
                    end
                else errors[#errors + 1] = tostring(why) end
            else errors[#errors + 1] = tostring(gen) end
        elseif code ~= 2 then
            -- ENOENT alone proves absence; access errors must not mean a new install.
            errors[#errors + 1] = tostring(err)
        end
    end
    if best then return best.value, best end
    if found or #errors > 0 then return nil, { error = table.concat(errors, '; '), state = 'error' } end
    return nil, { state = 'missing', generation = 0 }
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
    local previous = bak
    if live then
        local old_payload = unpack_file(live)
        local valid_old = old_payload ~= nil and (not validate or validate(old_payload) ~= nil)
        if not valid_old then previous = path .. ".rejected." .. tostring(gen) end
        local old_bak, bak_err, bak_code = M.read_raw(previous, 'inspect backup')
        if not old_bak and bak_code ~= 2 then return false, 'cannot inspect backup: ' .. tostring(bak_err) end
        if old_bak then
            if previous ~= bak then return false, "rejected generation already preserved" end
            local removed, remove_err = call('save: rotate backup', M.fs.remove, bak)
            if not removed then return false, 'cannot rotate backup: ' .. tostring(remove_err) end
        end
        local moved, move_err = call('save: preserve live', M.fs.rename, path, previous)
        if not moved then return false, 'cannot preserve previous save: ' .. tostring(move_err) end
    end
    local moved, move_err = call('save: install temporary', M.fs.rename, tmp, path)
    if not moved then
        -- Best effort restore. Even if this fails, .bak and the verified .tmp remain.
        if live then call('save: restore live', M.fs.rename, previous, path) end
        return false, 'cannot install save: ' .. tostring(move_err)
    end
    return true, nil, gen
end

return M
