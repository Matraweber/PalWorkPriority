-- Selection stores identities, never live widgets.
local M = {}
function M.select(rows, selected, direction)
    if #rows == 0 then return nil end
    local index = 1
    for i, row in ipairs(rows) do
        if selected and row.key == selected.key and row.work == selected.work then index=i; break end
    end
    local current = rows[index]
    if direction == 'left' or direction == 'right' then
        local step = direction == 'left' and -1 or 1
        local next_row = rows[index+step]
        if next_row and next_row.key == current.key then current=next_row end
    elseif direction == 'up' or direction == 'down' then
        local step = direction == 'up' and -1 or 1
        local next_key, best, distance
        local i = index+step
        while rows[i] do
            local row=rows[i]
            if row.key ~= current.key then
                if next_key and row.key ~= next_key then break end
                next_key=row.key
                local d=math.abs(row.work-current.work)
                if not distance or d<distance then best,distance=row,d end
            end
            i=i+step
        end
        if best then current=best end
    end
    return {key=current.key, work=current.work}
end
return M
