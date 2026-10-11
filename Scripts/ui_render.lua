local M = {}
function M.write(tb, text, colour)
    if not tb or not text then return 'failed' end
    local ok, written = pcall(function()
        -- UE void calls may return nil. Only explicit refusal or an exception
        -- fails the write; both setters must succeed before committing paint.
        if tb:SetText(text) == false then return false end
        if tb:SetColorAndOpacity({SpecifiedColor=colour, ColorUseRule=0}) == false then return false end
        return true
    end)
    return ok and written == true and 'rendered' or 'failed'
end
function M.collect(cells, paint)
    local result = {rendered=0, skipped=0, failed=0}
    for _, cell in ipairs(cells) do
        local ok, status = pcall(paint,cell)
        if not ok or status == 'failed' then result.failed = result.failed + 1
        elseif status == 'rendered' then result.rendered = result.rendered + 1
        else result.skipped = result.skipped + 1 end
    end
    return result
end
return M
