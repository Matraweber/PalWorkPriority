-- Real scheduler/rule merging, fake engine snapshots and clock. No native IO.
local noop = function() end
package.loaded.log = {info=noop, debug=noop, warn=noop, error=noop, say=noop}
package.loaded.trace = {at=noop, done=noop}
package.loaded.demand = {live=function() return true end,
    for_camp=function() return {}, 0, {} end}
local store = {decided=true, state="saved", data={}, baseline=false}
store.durable_key = function() return true end
store.effective = function(cfg, pal, name, value)
    local row = store.data[pal.key]
    if row and row[value] ~= nil then return row[value] end
    return cfg.work_priority[name]
end
package.loaded.store = store
local caps = require("caps")
local state, now = nil, 100
local clock_before = os.clock
os.clock = function() return now end
local function scan()
    state.scans = state.scans + 1
    state.times[#state.times+1] = now
    if state.scan_cost then now=now+state.scan_cost end
    if state.events then state.events[#state.events+1]={kind='scan',phase=state.phase} end
    local evidence = {complete=state.complete, deduplicated=state.deduplicated,
        unknown_scope=state.unknown, failed_reads=state.unknown,
        reasons={scope_zero_guid=state.unknown}}
    return {a={Stone=state.amount}, b={Stone=state.amount}}, {a=1,b=1}, evidence
end
local api = {
    camps_available=true,
    base_camps=function()
        if state.pass_cost then now=now+state.pass_cost end
        return state.camps
    end,
    camp_id=function(camp) return camp.id end,
    camp_guild=function(camp) return camp.guild end,
    guid_key=function(id) return id end,
    latch_authority=function() return true end,
    has_authority=function() return true end,
    owned_network_component=function() return "component" end,
    current_work_suitability=function() return nil end,
    suitability_rank=function(pal, value) return pal.ranks[value] or 0 end,
    work_off_set=function(pal)
        local off = {}; for value, disabled in pairs(pal.off) do off[value]=disabled end
        return off
    end,
    camp_pals=function(camp)
        local out = {}
        for _, pal in ipairs(state.pals) do
            if pal.camp == camp.id then
                out[#out+1] = {key=pal.key, id=pal.key, name=pal.key, param=pal}
            end
        end
        return out
    end,
    chest_totals_by_camp=scan,
    camp_item_totals=function(key)
        local totals, counts, evidence = scan()
        return totals[key], counts[key], evidence
    end,
    set_work_enabled=function(id, value, on)
        state.sends[#state.sends+1] = {id=id, value=value, on=on}
        if state.sync then
            for _, pal in ipairs(state.pals) do
                if pal.key == id then pal.off[value] = not on end
            end
        end
        return true
    end,
}
package.loaded.palapi = api
local scheduler = require("scheduler")
local workdefs = require("workdefs")
local cfg = {work_priority={}, interval_seconds=10, max_pals_per_work_type=3, leave_unordered_pals_to_game=false,
    min_suitability_rank=1, assignment_mode="fill", dry_run=false}
for _, name in ipairs(workdefs.ORDER) do cfg.work_priority[name]=1 end
local function setup(mode)
    now = 100
    state = {scans=0, times={}, sends={}, sync=true, complete=false,
        deduplicated=true, unknown=533, amount=100,
        camps={{id="a", guild="g"}},
        pals={{key="a-pal", camp="a", ranks={[8]=1}, off={[8]=true}}}}
    if mode ~= "direct" then
        state.camps[2] = {id="b", guild="g"}
        state.pals[2] = {key="b-pal", camp="b", ranks={[8]=1}, off={[8]=true}}
    end
    cfg.storage_scope, cfg.work_caps = mode == "global" and "global" or "camp", {}
    cfg.max_pals_per_work_type = 3
    caps.data, caps.state, caps.decided, caps.is_client = {g={Mining={Stone=10}}}, "saved", true, false
    store.data = {}
    scheduler.forget()
    scheduler.stock_ttl, scheduler.want_totals = 30, false
    scheduler.assignment_reader = function() return {state="ready", manual=false} end
    return state
end
local function run()
    local result = scheduler.run_pass(cfg)
    assert(not result.blocked and result.failed == 0, result.blocked_reason or "camp failed")
    return result
end
local failures, passed = {}, 0
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then passed=passed+1 else failures[#failures+1]=name .. ": " .. tostring(err) end
end
for _, mode in ipairs({"direct", "camp", "global"}) do
    check(mode .. ": no applicable limits skip storage and restore allowed permissions", function()
        local s = setup(mode)
        caps.data = {other={Mining={Stone=10}}}
        scheduler.last_totals = {Stone=7}
        local result = run()
        assert(s.scans == 0, "another guild's limits triggered " .. s.scans .. " scan(s)")
        assert(not s.pals[1].off[8] and result.storage_unverified == 0)
        assert(next(scheduler.last_storage_by_camp) == nil and scheduler.last_totals.Stone == 7,
            "skipping storage must not publish known empty stock")
        caps.data.g = {Mining={Stone=10}}
        result = run()
        assert(s.scans == 1 and result.storage_unverified == #s.pals,
            "adding an applicable limit must sample storage and remain conservative")
    end)
    check(mode .. ": OFF masks and nonnumeric ceilings are not applicable", function()
        local s = setup(mode)
        cfg.work_caps = {Mining={Stone=10}, Handcraft={Parts="bad"}}
        caps.data = {["*"]={Mining={Stone=20}}, g={Mining={Stone=false}}}
        assert(caps.for_work(cfg, "Mining", "g") == nil)
        run()
        assert(s.scans == 0 and not s.pals[1].off[8], "masked/invalid rule triggered storage")
    end)
    check(mode .. ": panel-only unknown storage does not restrict a rule-free guild", function()
        local s = setup(mode)
        caps.data = {other={Mining={Stone=10}}}
        scheduler.want_totals = true
        s.pals[1].ranks[5], s.pals[1].off[5] = 1, true
        store.data["a-pal"] = {[8]=false}
        local result = run()
        assert(s.scans == 1 and result.storage_unverified == #s.pals)
        assert(scheduler.last_storage_by_camp.a.verified == false,
            "no applicable limit is not proof of known stock")
        assert(not s.pals[1].off[5] and s.pals[1].off[8], "unrelated limits blocked reconciliation")
        assert(scheduler.last_capped.Mining.unknown == 0, "no rule cannot have an unknown cap verdict")
    end)
    check(mode .. ": incomplete retries reduce repeated scans without resolving stock", function()
        local s = setup(mode)
        for offset=0,120,10 do
            now = 100 + offset
            local result = run()
            assert(result.storage_unverified == #s.pals and #s.sends == 0)
            assert(scheduler.last_storage_by_camp.a.verified == false)
            assert(scheduler.last_capped.Mining.unknown == #s.pals)
        end
        print(mode .. " incomplete: " .. s.scans .. " scans / 13 passes")
        assert(s.scans == 6, "expected bounded retries at 0,10,20,40,70,100 seconds")
    end)
    check(mode .. ": retry boundaries, explicit X and verified recovery", function()
        local s = setup(mode)
        s.pals[1].ranks[5], s.pals[1].off[5] = 1, false
        for _, step in ipairs({{100,1},{104,1},{105,2},{114,2},{115,3},{134,3},{135,4},{164,4}}) do
            now = step[1]
            if now == 114 then store.data["a-pal"] = {[5]=false, [8]=4} end
            local result = run()
            assert(s.scans == step[2], "retry boundary at " .. now)
            assert(result.storage_unverified == #s.pals and s.pals[1].off[8])
            if now >= 114 then assert(s.pals[1].off[5] and store.data["a-pal"][8] == 4) end
        end
        now, s.complete, s.unknown, s.amount = 165, true, 0, 0
        local result = run()
        assert(s.scans == 5 and result.storage_unverified == 0)
        assert(not s.pals[1].off[8] and s.pals[1].off[5], "verified recovery lost numeric/X policy")
        now = 194; run(); assert(s.scans == 5, "verified TTL changed")
        now, s.complete, s.unknown = 195, false, 533
        run(); assert(s.scans == 6)
        now = 199; run(); assert(s.scans == 6)
        now = 200; run(); assert(s.scans == 7, "success must reset the first unknown retry to 5s")
    end)
    check(mode .. ": forced scans, shorter TTL, resets and clock rollback", function()
        for _, invalidate in ipairs({scheduler.forget_stock, scheduler.forget_policy, scheduler.forget}) do
            local s = setup(mode)
            run(); now=105; run(); now=115; run()
            invalidate(); run(); assert(s.scans == 4, "reset retained retry delay")
            now=119; run(); assert(s.scans == 4)
            now=120; run(); assert(s.scans == 5)
        end
        local s = setup(mode)
        scheduler.stock_ttl = 2
        run(); now=102; run(); now=104; run(); assert(s.scans == 3)
        scheduler.stock_ttl = 0
        local before = s.scans
        run(); run()
        assert(s.scans == before + (mode == "camp" and 4 or 2), "zero TTL stopped forcing scans")
        scheduler.stock_ttl = 30
        now=90; before=s.scans; run(); assert(s.scans == before+1, "clock rollback reused a future result")
    end)
end
check("config, wildcard and guild overrides retain effective ceilings", function()
    for _, mode in ipairs({"direct", "camp", "global"}) do
        for _, layer in ipairs({"config", "wildcard", "guild"}) do
            local s = setup(mode)
            s.complete, s.unknown, s.amount = true, 0, 15
            caps.data = {}
            if layer == "config" then cfg.work_caps = {Mining={Stone=10}}
            elseif layer == "wildcard" then caps.data["*"] = {Mining={Stone=10}}
            else
                cfg.work_caps = {Mining={Stone=1}}
                caps.data = {["*"]={Mining={Stone=2}}, g={Mining={Stone=40}}}
            end
            local result = run()
            assert(s.scans == 1 and result.storage_unverified == 0)
            assert((s.pals[1].off[8] == true) == (layer ~= "guild"), "rule precedence changed")
        end
    end
end)
check("unknown camp ownership remains restricted even for another guild's rule", function()
    for _, mode in ipairs({"direct", "camp", "global"}) do
        local s = setup(mode)
        caps.data = {other={Mining={Stone=10}}}
        for _, camp in ipairs(s.camps) do camp.guild = nil end
        s.complete, s.unknown = true, 0
        local result = run()
        assert(s.scans == 1 and result.storage_unverified == #s.pals and #s.sends == 0)
    end
end)
check("mixed guilds share a scan without restricting the guild with no limits", function()
    for _, mode in ipairs({"camp", "global"}) do
        local s = setup(mode)
        s.camps[1].guild = "free"
        local result = run()
        assert(s.scans == 1 and not s.pals[1].off[8] and s.pals[2].off[8])
        assert(result.storage_unverified == 1 and scheduler.last_capped.Mining.unknown == 1)
    end
end)
check("empty guild grouping keeps incomplete-read retry progression", function()
    local s=setup("global")
    for _,camp in ipairs(s.camps) do camp.guild=nil end
    for _,step in ipairs({{100,1},{104,1},{105,2},{114,2},{115,3},{134,3},{135,4}}) do
        now=step[1]
        local result=run()
        assert(s.scans==step[2],"unknown ownership retry boundary at "..now)
        assert(result.storage_unverified==#s.pals and #s.sends==0,
            "empty grouping established known storage or enabled work")
    end
end)
check("assignment uncertainty survives the no-limit path", function()
    local s = setup("direct")
    caps.data = {other={Mining={Stone=10}}}
    scheduler.assignment_reader = nil
    cfg.max_pals_per_work_type = 1
    s.pals[1].off[8] = false -- possibly fixed worker still owns this seat
    s.pals[2] = {key="strong", camp="a", ranks={[8]=4}, off={[8]=true}}
    local result = run()
    assert(s.scans == 0 and #s.sends == 0 and not s.pals[1].off[8] and s.pals[2].off[8])
    assert(result.assignment_unknown == 2 and result.manual_unavailable == 2 and result.held == 0)
end)
check("pending writes survive entering and leaving storage restriction", function()
    local s = setup("direct")
    caps.data, s.sync = {}, false
    local result = run()
    assert(#s.sends == 1 and result.pending_writes == 1)
    caps.data.g = {Mining={Stone=10}}
    now=101; result=run()
    assert(s.scans == 1 and result.storage_unverified == 1 and result.pending_writes == 1)
    caps.data = {other={Mining={Stone=10}}}
    now=102; result=run()
    assert(s.scans == 1 and #s.sends == 1 and result.pending_writes == 1)
    s.pals[1].off[8] = false
    now=103; result=run()
    assert(#s.sends == 1 and result.pending_writes == 0)
end)
check("verified global stock prefetch separates real scheduler and clock beats", function()
    local s=setup('global')
    s.complete,s.unknown,s.events,s.phase=true,0,{},'initial'
    s.scan_cost,s.pass_cost=.022,.020
    run()
    assert(s.scans==1)
    local beat
    LoopInGameThreadWithDelay=function(_,fn) beat=fn end
    package.loaded.clock=nil
    package.loaded.log.begin,package.loaded.log.finish=noop,noop
    local clock=require('clock')
    local passes=0
    clock.every('pass',10000,function() s.phase='pass'; run(); passes=passes+1 end,true)
    clock.every('stock check',1000,function()
        if scheduler.stock_refresh_due(cfg) then clock.defer('stock refresh',function()
            s.phase='background'; scheduler.refresh_stock(cfg)
        end) end
    end)
    clock.start()
    local worst=0
    for _=1,1050 do
        now=now+.1; local before=now; beat(); worst=math.max(worst,now-before)
    end
    assert(passes==10 and s.scans==4,'prefetch duplicated or lost scans')
    for i,event in ipairs(s.events) do if i>1 then assert(event.phase=='background','recurring scan landed inside pass') end end
    assert(worst<.023,'scan and scheduler accumulated into the same clock beat')
    assert(scheduler.last_storage.g.verified and s.pals[1].off[8] and s.pals[2].off[8])
end)
check("prefetch keeps original sample age and rejects changed ownership", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run()
    now=128; assert(scheduler.refresh_stock(cfg) and s.scans==2)
    now=131; run(); assert(s.scans==2 and scheduler.last_storage.g.sampled_at==128)
    now=140; run(); now=150; run()
    now=156; assert(scheduler.refresh_stock(cfg) and s.scans==3)
    s.camps[1].guild='different'
    now=159; run(); assert(s.scans==4,'changed camp ownership reused old scope')
end)
check("prefetch failures retain unknown evidence and bounded retry timestamps", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run(); s.complete,s.unknown=false,1
    now=128; assert(scheduler.refresh_stock(cfg) and s.scans==2)
    now=131; local result=run()
    assert(s.scans==2 and result.storage_unverified==2 and not scheduler.last_storage.g.verified)
    assert(not scheduler.stock_refresh_due(cfg),'incomplete data started an eager retry loop')
    now=132; run(); assert(s.scans==2)
    now=133; run(); assert(s.scans==3,'prefetch failure postponed the first retry')
end)
check("new incomplete prefetch overrides still-fresh old stock", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run(); s.complete,s.unknown=false,1
    now=128; assert(scheduler.refresh_stock(cfg))
    now=129; local result=run()
    assert(s.scans==2 and result.storage_unverified==2 and not scheduler.last_storage.g.verified,
        'old verified cache concealed newer failed evidence')
end)
check("delayed failed prefetch expires at the bounded retry interval", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run(); s.complete,s.unknown=false,1
    now=128; assert(scheduler.refresh_stock(cfg))
    s.complete,s.unknown,s.amount=true,0,0
    now=140; local result=run()
    assert(s.scans==3 and result.storage_unverified==0 and not s.pals[1].off[8],
        'stale incomplete candidate postponed a successful read')
end)
check("prefetch neither retains native camps nor survives reset or changed filters", function()
    for _,invalidate in ipairs({scheduler.forget_stock,scheduler.forget_policy,scheduler.forget}) do
        local s=setup('global'); s.complete,s.unknown=true,0
        run(); now=120; run()
        for _,camp in ipairs(s.camps) do
            for key in pairs(camp) do camp[key]=nil end
            setmetatable(camp,{__index=function() error('retained native camp') end})
        end
        s.camps={{id='a',guild='g'},{id='b',guild='g'}}
        now=128; assert(scheduler.refresh_stock(cfg))
        invalidate(); assert(not scheduler.stock_refresh_due(cfg))
        now=131; run(); assert(s.scans==3,'reset retained prefetched quantities')
    end
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run(); now=128; assert(scheduler.refresh_stock(cfg))
    cfg.uncounted_containers={'SomeClass'}
    assert(not scheduler.stock_refresh_due(cfg))
    now=131; run(); assert(s.scans==3,'in-place filter change adopted old quantities')
    cfg.uncounted_containers=nil
end)
check("prefetch interest ends with limits, session readiness and TTL", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=120; run(); now=128
    caps.data={}; assert(not scheduler.stock_refresh_due(cfg))
    scheduler.want_totals=true; assert(scheduler.stock_refresh_due(cfg))
    store.decided=false; assert(not scheduler.stock_refresh_due(cfg)); store.decided=true
    scheduler.stock_ttl=0; assert(not scheduler.stock_refresh_due(cfg))
    scheduler.stock_ttl=30; scheduler.want_totals=false
    caps.data={other={Mining={Stone=10}}}
    now=146; assert(not scheduler.stock_refresh_due(cfg),'old interest scanned forever for another guild')
end)
check("panel invalidation refreshes in background before the next pass", function()
    local s=setup('global'); s.complete,s.unknown=true,0
    run(); now=110; scheduler.want_totals=true
    scheduler.forget_stock(true)
    assert(scheduler.stock_refresh_due(cfg),'panel discarded the background refresh plan')
    s.amount=0
    now=111; assert(scheduler.refresh_stock(cfg) and s.scans==2)
    now=112; local result=run()
    assert(s.scans==2 and result.storage_unverified==0,'panel forced a duplicate inline scan')
    assert(scheduler.last_storage.g.sampled_at==111 and not s.pals[1].off[8])
    now=112.2; scheduler.forget_stock(true); s.complete,s.unknown=false,1
    assert(scheduler.refresh_stock(cfg)); local failed=run()
    assert(s.scans==3 and failed.storage_unverified==2 and not scheduler.last_storage.g.verified,
        'a newer failed panel refresh reused old verified quantities')
    s.complete,s.unknown=true,0
    now=112.3; run(); assert(s.scans==3,'failed panel refresh retried immediately')
    -- A pass winning the race still reads synchronously and cancels the request.
    now=113; scheduler.forget_stock(true); run()
    assert(s.scans==4 and not scheduler.stock_refresh_due(cfg),'inline fallback left redundant work queued')
    -- No plan, changed scope, and disabled prefetch retain the old fallback.
    scheduler.forget(); scheduler.forget_stock(true)
    assert(not scheduler.stock_refresh_due(cfg)); run(); assert(s.scans==5)
    now=114; scheduler.forget_stock(true); cfg.storage_scope='camp'
    assert(not scheduler.stock_refresh_due(cfg))
    cfg.storage_scope='global'; scheduler.prefetch_enabled=false
    scheduler.forget_stock(true); assert(not scheduler.stock_refresh_due(cfg)); run()
    assert(s.scans==6); scheduler.prefetch_enabled=true
end)
check('remote storage interest is scoped, expires, and retains original sample age', function()
    local s=setup('camp'); caps.data={}; s.complete,s.unknown=true,0
    assert(scheduler.request_stock('other'))
    run(); assert(s.scans==0,'foreign interest triggered storage')
    assert(scheduler.request_stock('g')); assert(s.scans==0,'request scanned inline')
    run(); assert(s.scans==1)
    assert(scheduler.last_storage_by_camp.a.sampled_at==100)
    now=110; run(); assert(s.scans==1)
    assert(scheduler.last_storage_by_camp.a.sampled_at==100,'pass renewed old sample')
    now=161; run(); assert(s.scans==1,'abandoned interest lived forever')
    assert(scheduler.request_stock('g')); scheduler.forget(); run()
    assert(s.scans==1,'world reset retained remote interest')
end)
check('requested empty-base storage does not depend on a worker roster', function()
    local s=setup('camp'); caps.data={}; s.pals={}; s.complete,s.unknown=true,0
    run(); assert(s.scans==0)
    scheduler.request_stock('g');run()
    assert(s.scans==1 and #s.sends==0)
    local view=require('storage_snapshot').build(cfg,scheduler,'g','a',now)
    assert(view.verified and view.totals.Stone==100 and #view.choices==2)
    now=110;run();assert(s.scans==1 and scheduler.last_storage_by_camp.a.sampled_at==100)
end)
check('a reading the scheduler still uses is shown as verified until the next pass', function()
    -- 2026-10-17: global scope, a 30 s reuse window and 10 s passes made every
    -- other '!pwp limit' say "stock unavailable" while Mining stayed stopped
    -- on that very reading. Valid for the reuse window plus one interval.
    local s=setup('global'); s.complete,s.unknown=true,0
    now=100; run(); assert(s.scans==1)
    now=129; run(); assert(s.scans==1 and scheduler.last_storage.g.sampled_at==100, 'reading was not reused')
    now=135
    local view=require('storage_snapshot').build(cfg,scheduler,'g',nil,now)
    assert(view.verified, 'display rejected the reading the last pass used')
    assert(scheduler.last_storage.g.ttl==40, 'published validity is not reuse window plus one interval')
    now=141
    view=require('storage_snapshot').build(cfg,scheduler,'g',nil,now)
    assert(not view.verified, 'a reading past the next pass stayed verified')
end)
os.clock = clock_before
assert(#failures == 0, table.concat(failures, "\n"))
print(passed .. " scheduler storage cost checks passed")
