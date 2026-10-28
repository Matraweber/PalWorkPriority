-- panel_status schema 5 interface: per_item, item_stopped, verdict on a
-- client, and the server side (server_limits). Plain data only.
local status = require('panel_status')
local saved = {caps=package.loaded.caps, net=package.loaded.net, item_sources=package.loaded.item_sources}
local function role(is_client, net, sources)
    package.loaded.caps = is_client ~= nil and {is_client=is_client} or nil
    package.loaded.net, package.loaded.item_sources = net, sources
end

-- per_item: the host reads its config, a client follows the server once known.
role(nil)
assert(status.per_item({}) == true and status.per_item(nil) == true)
assert(status.per_item({item_limits_on_rocks=false}) == false)
role(false, {server_item_limits=false})
assert(status.per_item({}) == true, 'host borrowed a server flag')
local net = {server_item_limits=nil}
role(true, net)
assert(status.per_item({}) == true and status.per_item({item_limits_on_rocks=false}) == false,
    'client without a server answer falls back to its own config')
net.server_item_limits = false
assert(status.per_item({}) == false, 'server off, client on: follow the server')
net.server_item_limits = true
assert(status.per_item({item_limits_on_rocks=false}) == true, 'server on, client off: follow the server')
net.server_item_limits = 'yes'
assert(status.per_item({item_limits_on_rocks=false}) == false, 'malformed flag ignored')

-- item_stopped: client from the server's count, host from item_sources.
net.item_stopped = function(item) return item == 'Stone' or nil end
assert(status.item_stopped('Stone') == true and status.item_stopped('Ore') == false)
net.item_stopped = function() error('transport gone') end
assert(status.item_stopped('Stone') == false)
role(true, nil, {item_stopped=function() return true end})
assert(status.item_stopped('Stone') == false, 'client used the host rock state')
role(false, nil, {item_stopped=function(item) return item == 'Ore' end})
assert(status.item_stopped('Ore') == true and status.item_stopped('Stone') == false)
role(false, nil, nil)
assert(status.item_stopped('Ore') == false)

-- verdict on a client: the server's numbers, never the local scheduler's.
role(true, {})
local empty_scheduler = {pass_id=3, last_capped={}, last_storage_by_camp={}}
local view = {verified=true, guild='g', scope='camp', camp='a', limits={verdicts={
    Mining={capped=1, camps=1, unknown=0}, Deforest={capped=0, camps=1, unknown=0},
    Watering={capped=0, camps=1, unknown=1}}}}
local reached, partly, bases = status.verdict(empty_scheduler, 'Mining', view)
assert(reached == true and partly == nil and bases == 1, 'client at its limit still has no verdict')
reached = status.verdict(empty_scheduler, 'Deforest', view)
assert(reached == false, 'running work type is a verdict too')
assert(status.verdict(empty_scheduler, 'Watering', view) == nil, 'unknown stock is not a verdict')
assert(status.verdict(empty_scheduler, 'Handcraft', view) == nil)
view.verified = false
assert(status.verdict(empty_scheduler, 'Mining', view) == nil, 'verdict outlived its count')
view.verified, view.limits = true, nil
assert(status.verdict(empty_scheduler, 'Mining', view) == nil, 'schema 4 view invented a verdict')
view.scope, view.camp, view.limits = 'guild', nil, {verdicts={Mining={capped=2, camps=3, unknown=0}}}
reached, partly, bases = status.verdict(empty_scheduler, 'Mining', view)
assert(reached == false and partly == 2 and bases == 3, 'partial guild verdict')
-- A client never reads its own scheduler, even if it holds stale numbers.
local stale = {pass_id=1, last_capped={Mining={pass=1, camps=1, capped=1, unknown=0}},
    last_storage_by_camp={a={pass=1, guild='g', verified=true}}}
assert(status.verdict(stale, 'Mining', {verified=true, guild='g', scope='camp', camp='a'}) == nil)

-- The host keeps its own path unchanged.
role(false)
reached, partly, bases = status.verdict(stale, 'Mining', {verified=true, guild='g', scope='camp', camp='a'})
assert(reached == true and partly == nil and bases == 1)

-- server_limits: exactly the guild and scope of the view being sent.
local cfg = {}
local caps = {all=function(_, guild)
    if guild == 'g' then return {Mining={Stone=100, Ore=50}, Deforest={Wood=10}} end
    return {Mining={Stone=1}}
end}
local one = {pass_id=7, last_capped={Mining={pass=7, camps=1, capped=1, unknown=0},
    Deforest={pass=7, camps=1, capped=0, unknown=0}, Watering={pass=7, camps=1, capped=0, unknown=0}},
    last_storage_by_camp={a={pass=7, guild='g', verified=true}}}
local camp_view = {verified=true, scope='camp', camp='a'}
local out = status.server_limits(cfg, one, 'g', camp_view, caps, {})
assert(out.per_item == true and out.verdicts.Mining.capped == 1 and out.verdicts.Mining.camps == 1)
assert(out.verdicts.Deforest.capped == 0 and out.verdicts.Watering == nil, 'verdict for a type without limits')
assert(status.server_limits({item_limits_on_rocks=false}, one, 'g', camp_view, caps, {}).per_item == false)
local blind = status.server_limits(cfg, one, 'g', {verified=false, scope='camp', camp='a'}, caps, {})
assert(blind.per_item == true and next(blind.verdicts) == nil and next(blind.stopped) == nil)
assert(next(status.server_limits(cfg, one, 'other', camp_view, caps, {}).verdicts) == nil, 'foreign guild')
-- Without a per-camp record, a server-wide count covering another guild's camp is no verdict.
local shared = {pass_id=7, last_capped=one.last_capped,
    last_storage_by_camp={a={pass=7, guild='g', verified=true}, b={pass=7, guild='h', verified=true}}}
assert(next(status.server_limits(cfg, shared, 'g', camp_view, caps, {}).verdicts) == nil,
    'another guild leaked into the verdict')
-- With per-camp records the verdict is exact on a server with many guilds.
shared.last_capped_by_camp = {a={pass=7, works={Mining=true, Deforest=false}},
    b={pass=7, works={Mining=false, Deforest=true}}, c={pass=7, works={Mining=true, Deforest='unknown'}}}
shared.last_storage_by_camp.c = {pass=7, guild='g', verified=false}
local exact = status.server_limits(cfg, shared, 'g', camp_view, caps, {})
assert(exact.verdicts.Mining.capped == 1 and exact.verdicts.Mining.camps == 1 and exact.verdicts.Deforest.capped == 0)
local whole = status.server_limits(cfg, shared, 'g', {verified=true, scope='guild'}, caps, {})
assert(whole.verdicts.Mining.capped == 2 and whole.verdicts.Mining.camps == 2 and whole.verdicts.Mining.unknown == 0)
assert(whole.verdicts.Deforest.capped == 0 and whole.verdicts.Deforest.unknown == 1)
shared.last_capped_by_camp.a.pass = 6
assert(status.server_limits(cfg, shared, 'g', camp_view, caps, {}).verdicts.Mining == nil,
    'old pass counted as a verdict')
-- Rocks held: per camp when item_sources can say so, else only when unambiguous.
local held = {a={Stone=true}, b={Ore=true}}
local sources = {held_items=function(camp) return held[camp] end}
out = status.server_limits(cfg, shared, 'g', camp_view, caps, sources)
assert(out.stopped.Stone and not out.stopped.Ore, 'another guild\'s rocks reported')
assert(next(status.server_limits({item_limits_on_rocks=false}, shared, 'g', camp_view, caps, sources).stopped) == nil)
local global = {blocked={a={rock1=true}}, item_stopped=function(item) return item == 'Stone' end}
out = status.server_limits(cfg, one, 'g', camp_view, caps, global)
assert(out.stopped.Stone and not out.stopped.Ore)
global.blocked.b = {rock2=true}
assert(next(status.server_limits(cfg, one, 'g', camp_view, caps, global).stopped) == nil,
    'rocks held at a camp outside the scope made the global answer ambiguous')

-- Plain reasons.
assert(status.plain_reason('too_many_limits') == 'This guild already has 500 limits. Remove one first.')
assert(status.plain_reason('Item-specific limits await a verified producer adapter and scope')
    == 'Item-specific limits await a verified producer adapter and scope', 'dead mapping still listed')

package.loaded.caps, package.loaded.net, package.loaded.item_sources = saved.caps, saved.net, saved.item_sources
print('panel_status schema 5: per_item follows the server both ways, client verdicts and rock state from the server, scoped server limits')
