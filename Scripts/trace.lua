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
M.on = true

-- Marks are cleared when the risky call survives, which is the whole design
-- and was missing from the first version of this file.
--
-- Without clearing, the most frequent site is the last breadcrumb whatever
-- actually crashed, and it proves nothing at all. With clearing, the file
-- holds a mark only while a call is in flight: a crash during one names it,
-- and a crash anywhere else leaves "idle" behind, which is just as useful an
-- answer because it rules all three of them out.
--
-- The name matters as much as the place. "ui cell" narrows it to a loop,
-- "ui cell WBP_Row_3.Cell_2" names the object.
function M.at(where)
    if not M.on or not M.path then return end

    pcall(function()
        local f = io.open(M.path, "w")
        if f then
            f:write(os.date("%H:%M:%S ") .. where)
            f:close()
        end
    end)
end

-- Survived. Anything that crashes from here on did not crash in that call.
function M.done()
    if not M.on or not M.path then return end

    pcall(function()
        local f = io.open(M.path, "w")
        if f then
            f:write(os.date("%H:%M:%S ") .. "idle")
            f:close()
        end
    end)
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
