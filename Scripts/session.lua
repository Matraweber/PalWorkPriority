-- Plain-data generations and a bounded queue drained on the game thread.
local M = { epoch = 0, ui_epoch = 0, world = nil }
local queue = {}
local draining_left = 0

function M.begin(world)
    M.epoch, M.ui_epoch, M.world = M.epoch + 1, M.ui_epoch + 1, world
    queue = {}
    draining_left = 0
    return M.epoch
end

function M.invalidate_ui()
    M.ui_epoch = M.ui_epoch + 1
end

function M.enqueue(fn, ui_action, ...)
    if #queue + draining_left >= 128 or type(fn) ~= 'function' then return false end
    queue[#queue+1] = { fn=fn, epoch=M.epoch, ui=ui_action and M.ui_epoch or nil,
        args=table.pack(...) }
    return true
end

function M.has_pending()
    return #queue > 0
end

function M.drain(on_error, budget_ms)
    local pending = queue
    queue = {}
    local started = budget_ms and os.clock()
    local epoch = M.epoch
    draining_left = #pending
    for index, action in ipairs(pending) do
        draining_left = #pending-index
        if action.epoch == M.epoch and (not action.ui or action.ui == M.ui_epoch) then
            local ok, err = pcall(action.fn, table.unpack(action.args,1,action.args.n))
            if not ok and on_error then on_error(err) end
        end
        -- Never interrupt an action or reduce a run of directional edits to a
        -- net delta (saturating 1/X cycles depend on order). Yield BETWEEN
        -- actions; old accepted actions precede anything enqueued during them.
        if started and (os.clock()-started)*1000 >= budget_ms then
            local remainder={}
            if epoch == M.epoch then
                for i=index+1,#pending do remainder[#remainder+1]=pending[i] end
            end
            for _,next_action in ipairs(queue) do remainder[#remainder+1]=next_action end
            queue=remainder
            break
        end
    end
    draining_left=0
end

function M.guard(fn)
    local epoch = M.epoch
    return function(...)
        if M.epoch == epoch then return fn(...) end
    end
end

return M
