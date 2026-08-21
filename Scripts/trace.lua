-- A breadcrumb that survives a hard crash.
--
-- The fault this exists to find kills the process outright: no Lua error, no
-- message, nothing appended to the log after it. Anything buffered dies with
-- it, so the ordinary log cannot say what was being touched at the time.
--
-- This writes one line to its own file and closes it immediately, overwriting
-- rather than appending. Only the last one matters. After a crash the file
-- holds the operation that was in flight, which is the whole point.
--
-- It is deliberately noisy in cost: a file write per risky touch. That is a
-- diagnostic price for one run, not something to leave switched on, and
-- M.on is here so it can be switched off without unpicking the call sites.

local M = {}

M.path = nil

-- Off unless a hunt is on. Issue #1372's reporter partially mitigated the
-- same crash class by removing file I/O from hook callbacks, and every mark
-- here is a file write inside the pass. "pwp trace on" switches it back on
-- for a session that needs the breadcrumb.
M.on = false

-- Marks are cleared when the risky call survives, and they NEST.
--
-- The first version wrote "idle" on every done(), which made nested marks
-- lie: an outer mark covering a whole stage was erased the moment any inner
-- mark cleared, so a crash later in that stage read as "idle" and the stage
-- looked exonerated. That is exactly how the crash on 21 August at 23:09
-- hid: it was in the back half of run_camp, after the chest sweep's done(),
-- and the file swore the mod was idle.
--
-- So this is a stack. at() pushes, done() pops, and the file always names
-- the innermost mark still in flight, or "idle" only when nothing is.
--
-- The name matters as much as the place. "ui cell" narrows it to a loop,
-- "ui cell WBP_Row_3.Cell_2" names the object.
local stack = {}

local function write_top()
    pcall(function()
        local f = io.open(M.path, "w")
        if f then
            f:write(os.date("%H:%M:%S ") .. (stack[#stack] or "idle"))
            f:close()
        end
    end)
end

function M.at(where)
    if not M.on or not M.path then return end
    stack[#stack + 1] = where
    write_top()
end

-- Survived. The file goes back to naming whatever enclosing call is still
-- in flight, rather than to "idle" while a stage is mid-run.
function M.done()
    if not M.on or not M.path then return end
    stack[#stack] = nil
    write_top()
end

-- Read back at startup, so a crash announces itself in the ordinary log the
-- next time the mod runs rather than waiting to be asked.
function M.last()
    if not M.path then return nil end

    local text
    pcall(function()
        local f = io.open(M.path, "r")
        if f then
            text = f:read("*a")
            f:close()
        end
    end)

    if type(text) == "string" and text ~= "" then return text end
    return nil
end

return M
