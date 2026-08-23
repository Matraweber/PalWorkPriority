-- Logging for Pal Work Priority.
--
-- Everything at or above the configured level goes to UE4SS.log through
-- print(). Anything at warn or above, plus anything a command was asked to
-- print, is additionally appended to priority.log next to the mod, so
-- reading the result does not require the UE4SS console to be open.

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAG = "[PalWorkPriority] "

M.threshold = LEVELS.info
M.file_path = nil

function M.set_level(name)
    M.threshold = LEVELS[name] or LEVELS.info
end

-- One place that appends to the file, so there is one escape to get right
-- rather than a copy of it per caller.
local function to_file(line)
    if not M.file_path then return end

    pcall(function()
        local f = io.open(M.file_path, "a")
        if f then
            f:write(os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n")
            f:close()
        end
    end)
end

local function emit(level, msg)
    local rank = LEVELS[level] or LEVELS.info
    if rank < M.threshold then return end

    local line = TAG .. string.upper(level) .. " " .. tostring(msg)
    pcall(function() print(line) end)

    -- The file gets whatever the level asks for.
    --
    -- This was hardcoded to warn and above, so log.info and log.debug reached
    -- the console and NOTHING else - and on a headless server the console is
    -- not somewhere anyone can look. Setting log_level = "debug" appeared to
    -- do nothing at all, and the scheduler pass, which reports at info, left
    -- no trace: a server running perfectly and a server doing nothing were
    -- the same empty log. That cost a long diagnosis of a bug that was not
    -- there.
    --
    -- The I/O worry behind the old rule is real - issue #1372 was mitigated
    -- by taking file writes out of hot callbacks - but the threshold is the
    -- control for that, and it defaults to info: one line per pass every ten
    -- seconds. Anyone who asks for debug has asked for the volume.
    to_file(line)
end

function M.debug(msg) emit("debug", msg) end
function M.info(msg) emit("info", msg) end
function M.warn(msg) emit("warn", msg) end
function M.error(msg) emit("error", msg) end

-- Always reaches the log regardless of level: reserved for the banner and
-- for command output the user explicitly asked for.
--
-- Written to the file as well as the console. Console only was wrong: a key
-- that answers into a window nobody has open is a key that did nothing, and
-- the transport test read as broken for exactly that reason when it had in
-- fact passed six times over.
function M.say(msg)
    local line = TAG .. tostring(msg)
    pcall(function() print(line) end)
    to_file(line)
end

return M
