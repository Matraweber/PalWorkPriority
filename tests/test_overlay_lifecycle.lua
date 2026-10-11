local lifecycle = require("panel_lifecycle")
local state = lifecycle.new()
lifecycle.open(state)
state.route = "GameAndUI"
assert(lifecycle.close(state, true))
assert(state.phase == "handoff" and state.route == nil)
assert(not lifecycle.recover(state, true))
lifecycle.open(state)
state.route = "GameAndUI"
assert(lifecycle.close(state,nil))
assert(state.phase=="handoff" and not lifecycle.recover(state,false),
    "unknown close later became permission to steal focus")
assert(not lifecycle.recover(state, false), "handoff was reclassified as a leaked route")
local generation = state.generation
assert(not lifecycle.close(state, false))
assert(state.generation == generation, "repeated close changed generation")
lifecycle.open(state)
state.route = "GameAndUI"
assert(lifecycle.close(state, false))
assert(state.phase == "closed" and not lifecycle.recover(state, false))
state.route = "leaked"
assert(lifecycle.recover(state, false))
assert(not lifecycle.recover(state, nil), "unknown UI state cannot permit stealing input")
assert(not lifecycle.recover(state, true))
