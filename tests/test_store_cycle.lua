local store = require('store')
local states = {1, 2, 3, 4, 5, false} -- false is X, never an unset choice.
for i, current in ipairs(states) do
    local forward = states[i % #states + 1]
    local backward = states[(i - 2) % #states + 1]
    assert(store.cycle(current, 1) == forward, 'forward ring from ' .. tostring(current))
    assert(store.cycle(current, -1) == backward, 'reverse ring from ' .. tostring(current))
    assert(store.cycle(store.cycle(current, 1), -1) == current, 'directions must undo each other')
    for _, dir in ipairs({-1, 1}) do
        local value = current
        for _ = 1, #states do value = store.cycle(value, dir) end
        assert(value == current, 'six steps must return to the starting choice')
    end
end
assert(store.cycle(nil, 1) == 2, 'unset retains the priority-1 starting point')
assert(store.cycle(nil, -1) == false, 'unset reverse follows priority 1 to X')
print('priority cycle: six-state wraparound in both directions passed')
