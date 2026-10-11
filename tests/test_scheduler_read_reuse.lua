-- Real scheduler, scalar engine snapshots; no game or filesystem writes.
local noop = function() end
local now, reads, sends, fixture, mode, on_read = 100, {}, {}, {}, 'sync', nil
os.clock = function() return now end
local profiler = require('perf').new({clock=function() return now end,
    wall_clock=function() return now end, resolution_ms=1})
profiler:set_enabled(true)
package.loaded.log = {perf=true, info=noop, debug=noop, warn=noop,
    around=function(...) return profiler:around(...) end}
package.loaded.trace = {at=noop, done=noop}
package.loaded.demand = {live=function() return true end,
    for_camp=function() return {}, 0, {} end}
local store = {decided=true, state='saved', baseline=false, data={}}
store.durable_key = function() return true end
store.effective = function(cfg, pal, name, value)
    local row=store.data[pal.key]
    if row and row[value]~=nil then return row[value] end
    return cfg.work_priority[name]
end
package.loaded.store = store
package.loaded.caps = {decided=true, state='saved', any=function() return false end,
    all=function() return {} end, for_work=function() return nil end, offer_adopt=noop}
local api = {
    camps_available=true, base_camps=function() return {{id='camp'}} end,
    camp_id=function(c) return c.id end, camp_guild=function() return 'guild' end,
    guid_key=function(id) return id end, latch_authority=function() return true end,
    has_authority=function() return true end, owned_network_component=function() return 'owned' end,
    current_work_suitability=function(p) assert(not p.dead); return nil end,
    suitability_rank=function(p,v) assert(not p.dead); return p.ranks[v] or 0 end,
    camp_pals=function()
        if mode=='roster_error' then error('roster failed') end
        local out={}
        for _,p in ipairs(fixture) do out[#out+1]={key=p.key,id=p.key,param=p,name=p.key} end
        return out
    end,
    work_off_set=function(p)
        assert(not p.dead,'old native wrapper reused')
        reads[p.key]=(reads[p.key] or 0)+1
        if on_read and on_read(p,reads[p.key])==false then return nil end
        local off={}; for v,on in pairs(p.off) do off[v]=on end
        return off
    end,
    set_work_enabled=function(id,v,on,comp)
        assert(comp=='owned')
        sends[#sends+1]={id=id,value=v,on=on}
        if mode=='sync' then
            for _,p in ipairs(fixture) do if p.key==id then p.off[v]=not on end end
        end
        return mode~='failed'
    end,
}
package.loaded.palapi=api
local scheduler=require('scheduler')
local workdefs=require('workdefs')
local cfg={work_priority={},max_pals_per_work_type=false,min_suitability_rank=1,
    assignment_mode='fill',interval_seconds=10,storage_scope='camp',dry_run=false}
for _,name in ipairs(workdefs.ORDER) do cfg.work_priority[name]=1 end
local function setup(n)
    scheduler.forget(); profiler:reset()
    fixture,reads,sends,store.data={}, {}, {}, {}
    mode,on_read,now='sync',nil,100
    for i=1,n or 1 do fixture[i]={key='pal'..i,ranks={[5]=1,[8]=1},off={}} end
    scheduler.assignment_reader=function() return {state='ready',manual=false} end
end
local function run()
    local stats=scheduler.run_pass(cfg)
    assert(not stats.blocked and stats.failed==0,stats.blocked_reason or 'pass failed')
    return stats
end

setup(14)
local stats=run()
assert(#sends==0 and stats.pending_writes==0 and stats.unreadable==0)
for _,p in ipairs(fixture) do
    assert(reads[p.key]==4,'unchanged Pal must read four times, got '..tostring(reads[p.key]))
end
-- A new pass must reacquire even same-name replacements; explicit X still applies.
local old=fixture
fixture={}
for i,p in ipairs(old) do
    p.dead=true
    fixture[i]={key=p.key,ranks={[5]=1,[8]=1},off={[8]=true}}
    store.data[p.key]={[8]=false}
end
reads={}; now=110; stats=run()
assert(#sends==0 and stats.pending_writes==0)
for _,p in ipairs(fixture) do assert(reads[p.key]==4 and p.off[8]) end

-- A successful withdrawal earlier in the pass still requires final native readback.
setup(); store.data.pal1={[8]=false}; stats=run()
assert(reads.pal1==5 and #sends==1 and not sends[1].on and fixture[1].off[8])
assert(stats.pending_writes==0)
-- An enable attempt must not confirm its pre-write snapshot.
setup(); fixture[1].off[5]=true; stats=run()
assert(reads.pal1==5 and #sends==1 and sends[1].on and not fixture[1].off[5])
assert(stats.pending_writes==0)

for _,failure in ipairs({'delayed','failed'}) do
    setup(); mode=failure; store.data.pal1={[8]=false}; fixture[1].off[5]=true
    stats=scheduler.run_pass(cfg)
    assert(#sends==1 and not sends[1].on,'enable crossed outstanding withdrawal')
    assert(reads.pal1==4 and stats.pending_writes==1 and stats.awaiting_withdrawal==1)
    assert(stats.failed==(failure=='failed' and 1 or 0))
    reads={}; now=131; stats=scheduler.run_pass(cfg)
    assert(#sends==1 and stats.pending_writes==1 and stats.expired_writes==1)
    assert(reads.pal1==4,'pending withdrawal lost fresh final read')
    -- Delivery before a later pass can clear pending, but that pass still reads freshly.
    fixture[1].off[8]=true; fixture[1].off[5]=false
    reads={}; now=132; stats=run()
    assert(reads.pal1==5 and stats.pending_writes==0 and #sends==1)
end

-- Final read remains required when a request just failed and readback is unavailable.
setup(); mode='failed'; fixture[1].off[5]=true
on_read=function(_,n) if n==5 then return false end end
stats=scheduler.run_pass(cfg)
assert(reads.pal1==5 and stats.failed==1 and stats.pending_writes==1)
-- The withdrawal barrier must notice failure independently of the planning read.
setup(); on_read=function(_,n) if n==3 then return false end end
stats=run()
assert(stats.awaiting_withdrawal==1 and #sends==0 and reads.pal1==4)

setup(); run()
for _,label in ipairs({'scheduler: camp roster','scheduler: plan fences',
    'scheduler: withdraw permissions','scheduler: verify withdrawals','scheduler: enable and confirm permissions'}) do
    assert(profiler.marks[label] and profiler.marks[label].timed_n==1,'missing aggregate scope: '..label)
end
setup(); mode='roster_error'; stats=scheduler.run_pass(cfg)
assert(stats.failed==1 and profiler.marks['scheduler: camp roster'].timed_n==1,
    'throw abandoned timing scope')
print('Scheduler read reuse: unchanged 14-Pal pass 70 -> 56 reads; barriers, attempted writes, pending state and fresh wrappers preserved')
