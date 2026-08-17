-- Logging for Pal Work Priority.
--
-- Everything at or above the configured level goes to UE4SS.log through
-- print(). Anything at warn or above is additionally appended to
-- priority.log next to the mod, so a bug report does not require the user
-- to have the UE4SS console open.

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local TAG = "[PalWorkPriority] "

M.threshold = LEVELS.info
M.file_path = nil

function M.set_level(name)
    M.threshold = LEVELS[name] or LEVELS.info
end

local function emit(level, msg)
    local rank = LEVELS[level] or LEVELS.info
    if rank < M.threshold then return end

    local line = TAG .. string.upper(level) .. " " .. tostring(msg)
    pcall(function() print(line) end)

    if M.file_path and rank >= LEVELS.warn then
        pcall(function()
            local f = io.open(M.file_path, "a")
            if f then
                f:write(os.date("%Y-%m-%d %H:%M:%S ") .. line .. "\n")
                f:close()
            end
        end)
    end
end

function M.debug(msg) emit("debug", msg) end
function M.info(msg) emit("info", msg) end
function M.warn(msg) emit("warn", msg) end
function M.error(msg) emit("error", msg) end

-- Always reaches the log regardless of level: reserved for the banner and
-- for command output the user explicitly asked for.
function M.say(msg)
    pcall(function() print(TAG .. tostring(msg)) end)
end

return M
