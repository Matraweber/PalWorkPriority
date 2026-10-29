-- Execute the real composition root. Native boundaries are mocks; all user data
-- and log IO is routed to memory under a deliberately non-installable virtual path.
local source_handle = assert(io.open(TEST_ROOT .. "/Scripts/main.lua", "rb"))
local main_source = source_handle:read("*a")
source_handle:close()
local create_fs = require("memory_fs")
local original_io = { open=io.open, popen=io.popen }
local original_os = { rename=os.rename, remove=os.remove, execute=os.execute, clock=os.clock, time=os.time }
local native_names = {"print","RegisterHook","RegisterKeyBind","LoopInGameThreadWithDelay",
    "ExecuteInGameThread","FindAllOf","FindFirstOf","StaticFindObject","LoadAsset","FName","Key","ModifierKey"}
local original_native = {}
for _, name in ipairs(native_names) do original_native[name] = _G[name] end
local ROOT = "/__pwp_main_integration_only__/mod/"
local failures = {}
-- Set by a test to boot with the real darnmenu reading this as the player's
-- saved Mods/shared/PalWorkPriority_user.lua; nil boots with a stub.
local darnmenu_user = nil
-- Set by a test to boot on a UE4SS whose ModifierKey has no ALT.
local without_alt = false
-- Set by a test to boot with the real stand grid (ui.lua and its helpers).
local real_ui = false

local function upvalue(fn, wanted)
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value end
    end
    error("missing real main upvalue: "..wanted)
end

local function boot(authority,empty_caps,prepare,expected_error)
    local fs = create_fs()
    fs.files[ROOT.."config.lua"] = [[return {
        enabled=true, dry_run=false, interval_seconds=10, log_level="info",
        work_priority={}, work_caps={}, pal_overrides={}, assignment_mode="spread",
        max_pals_per_work_type=3, min_suitability_rank=1, run_on_world_load=false,
        chat_prefix="!pwp"
    }]]
    fs.files[ROOT.."priorities.txt"] = "PAL-A|1|X\n"
    if not empty_caps then fs.files[ROOT.."caps.txt"] = "guild-local|Mining|Stone|100\n" end
    if prepare then prepare(fs) end
    local state = { fs=fs, authority=authority, now=100, console={}, hooks={},
        timers={}, once={}, deferred={}, loops={}, keys={}, scheduler_calls=0, latch_calls=0,
        viewport_calls=0, ui_calls=0, stand_refreshes=0, maintenance_calls=0,
        viewport=false, native_writes=0, outgoing={} }
    local function noop() end
    local function virtual(path)
        assert(type(path)=="string" and path:sub(1,#ROOT)==ROOT, "unexpected disk path: "..tostring(path))
    end
    io.open=function(path,mode) virtual(path); return fs.open(path,mode) end
    io.popen=function() error("integration test forbids subprocess IO") end
    os.rename=function(a,b) virtual(a); virtual(b); return fs.rename(a,b) end
    os.remove=function(path) virtual(path); return fs.remove(path) end
    os.execute=function() error("integration test forbids external commands") end
    os.clock=function() return state.now end
    os.time=function() return 1900000000+math.floor(state.now) end
    print=function(line) state.console[#state.console+1]=tostring(line) end
    RegisterHook=function(path,before,after)
        state.hooks[path]={before=before,after=after}
        return 1,2
    end
    -- Stored as {fn, mods} so a test can see which keys carry Alt.
    RegisterKeyBind=function(key,mods,fn)
        if fn==nil then mods,fn=nil,mods end
        state.keys[key]={fn=fn,mods=mods}
    end
    LoopInGameThreadWithDelay=function(ms,fn) state.loops[ms]=fn end
    ExecuteInGameThread=function(fn) fn() end
    FindAllOf=function() return {} end
    FindFirstOf=function() return nil end
    StaticFindObject=function() return nil end
    LoadAsset=function() return nil end
    FName=function(value) return value end
    -- Only names UE4SS really has: a made-up one (DELETE, 2026-10-28) bound
    -- nothing in game while this stub happily answered for it. ALT is a
    -- ModifierKey, not a Key.
    Key=setmetatable({}, {__index=function(_,key)
        if key:match("^F%d+$") or ({ESCAPE=1,RETURN=1,DEL=1,BACKSPACE=1,TAB=1,
            UP_ARROW=1,DOWN_ARROW=1,LEFT_ARROW=1,RIGHT_ARROW=1,SPACE=1})[key] then return key end
    end})
    ModifierKey={ALT="ALT",CONTROL="CONTROL",SHIFT="SHIFT"}
    if without_alt then ModifierKey.ALT=nil end

    -- Use real persistence, configuration, transport/protocol, session and
    -- measurement modules; only native/UI adapters and the scheduler engine
    -- boundary are replaced. No fallback stub fabricates missing methods.
    for _, name in ipairs({"log","perf","datafile","store","caps","configuration","session",
        "measurement","net","protocol","demand","trace","workdefs","producers"}) do package.loaded[name]=nil end
    local comp={}
    function comp:Request_Server_int32(_,name,value)
        state.outgoing[#state.outgoing+1]={name=name,value=value}
    end
    local api={
        set_authority_hint=function(hint) assert(hint==nil) end,
        has_authority=function() return state.authority end,
        latch_authority=function() state.latch_calls=state.latch_calls+1; return state.authority end,
        has_viewport=function() state.viewport_calls=state.viewport_calls+1; return state.viewport end,
        local_player_controller=function() return nil end, player_controller=function() return nil end,
        base_camps=function() return {} end, owned_network_component=function() return comp end,
        valid=function(object) return type(object)=="table" end,
        pc_memo_begin=noop, pc_memo_end=noop, reset=noop,
        world_key=function() return "same-world-name" end,
    }
    state.api=api
    package.loaded.palapi=api
    local scheduler={stock_ttl=30,pass_id=0,forget=noop,forget_stock=noop,forget_policy=noop}
    scheduler.stock_refresh_due=function() return false end
    scheduler.refresh_stock=noop
    scheduler.prefetch_enabled=true
    scheduler.set_prefetch=function(enabled) scheduler.prefetch_enabled=enabled end
    function scheduler.run_pass(cfg)
        state.scheduler_calls=state.scheduler_calls+1
        state.seen_cfg, state.seen_dry, state.seen_ttl=cfg,cfg.dry_run,scheduler.stock_ttl
        if state.handler then return state.handler(cfg,scheduler) end
        scheduler.pass_id=scheduler.pass_id+1
        return {camps=2,pals=14,failed=0}
    end
    function scheduler.format_stats(_,stats)
        return string.format("%d camp(s), %d pal(s)",stats.camps,stats.pals)
    end
    state.scheduler=scheduler
    package.loaded.scheduler=scheduler
    local ui={bind_mouse=function(get_cfg) state.cfg=get_cfg; return 2 end,
        is_open=function() return false end, reset=noop, detach=noop}
    ui.refresh=function()
        state.ui_calls=state.ui_calls+1; state.stand_refreshes=state.stand_refreshes+1
    end
    state.ui=ui
    package.loaded.ui=ui
    if real_ui then
        for _,name in ipairs({"ui","ui_tree","ui_render","stand_input","stand_pointer","stand_lifecycle"}) do
            package.loaded[name]=nil
        end
    end
    package.loaded.panel={open=false,refresh=ui.refresh,hover_tick=ui.refresh,fill_tick=ui.refresh,reset=noop}
    state.panel=package.loaded.panel
    state.panel.refresh=function() state.ui_calls=state.ui_calls+1 end
    package.loaded.overlay={host=noop,reset=noop}
    package.loaded.icons={get=noop}
    package.loaded.pad={drive=noop,forget=noop}
    package.loaded.items={reset=noop}
    package.loaded.discover={}
    package.loaded.reload={}
    package.loaded.remote={poll=function() state.maintenance_calls=state.maintenance_calls+1 end,drain=noop}
    package.loaded.darnmenu={apply=noop,register=noop,binding=function() return nil end}
    if darnmenu_user then
        package.loaded.darnmenu=nil
        local real=require("darnmenu")
        real.user_settings=function() return darnmenu_user end
        real.register=noop -- writes beside the real Mods/shared; not under test here
        state.darnmenu=real
    end
    package.loaded.clock={
        every=function(name,ms,fn) assert(type(fn)=="function"); state.timers[name]={ms=ms,fn=fn} end,
        once=function(ms,fn) state.once[#state.once+1]={ms=ms,fn=fn} end,
        start=function() state.clock_started=true end,
        -- Real clock.reset preserves recurring entries and drops deferred work.
        reset=function() state.deferred={} end,
        defer=function(name,fn) state.deferred[name]=fn end,
        last_beat=state.now,
    }
    local loaded,why=pcall(assert(load(main_source,"@"..ROOT.."Scripts/main.lua","t",_G)))
    assert(loaded,"main.lua did not load: "..tostring(why))
    if real_ui then state.ui=package.loaded.ui end
    state.store,state.caps,state.net,state.session,state.log=package.loaded.store,package.loaded.caps,
        package.loaded.net,package.loaded.session,package.loaded.log
    state.commands=upvalue(upvalue(package.loaded.remote.command,"handle_command"),"COMMANDS")
    assert(state.clock_started and state.timers.role and state.timers.pass and state.timers.ui,
        "headless boot must arm role, pass and maintenance timers without ClientRestart")
    assert(type(state.net.on_snapshot)=="function" and state.net.installed,"main transport wiring is missing")
    for _, line in ipairs(state.console) do
        assert(not line:find("[PalWorkPriority] ERROR",1,true)
            or expected_error and line:find(expected_error,1,true),"boot logged an error: "..line)
    end
    function state:background()
        local pending=self.deferred; self.deferred={}
        for _,fn in pairs(pending) do fn() end
    end
    function state:ui_beat()
        self.timers.ui.fn()
        self:background() -- Separate dispatch; real clock budgeting has its own suite.
    end
    function state:ack(run,request)
        for i=#self.console,1,-1 do
            local line=self.console[i]
            if line:find("PWP_PASS run="..run.." request="..request.." ",1,true) then return line end
        end
        error("missing command-bound completion")
    end
    return state
end

local function test(name,fn)
    local ok,why=xpcall(fn,debug.traceback)
    if not ok then failures[#failures+1]=name..": "..tostring(why) end
end

test("new network limit is a saved group rule; absent clear returns bounded reason",function()
    local s=boot(true,true);s.timers.role.fn()
    s.net.guild_of_sender=function()return 'guild-local' end
    local ok,reason=s.net.on_command('PWP_Set|Mining|Stone|35001',0,{})
    assert(ok==true,'new network limit refused: '..tostring(reason))
    assert(s.caps.all({},'guild-local').Mining.Stone==35001 and s.fs.files[ROOT..'caps.txt'])
    assert(s.net.on_command('PWP_Clear|Mining|Stone',0,{}))
    local before=s.caps.serialize()
    ok,reason=s.net.on_command('PWP_Set|NotAWork|Stone|35001',0,{})
    assert(ok==false and s.caps.serialize()==before,'invalid network limit written')
    ok,reason=s.net.on_command('PWP_Clear|Mining|Stone',0,{})
    assert(ok==false and reason=='no_active_legacy_rule','main discarded absent rule reason')
    assert(s.caps.serialize()==before)
end)

test("unidentified and foreign restarts preserve the local session",function()
    for _,kind in ipairs({"foreign","throws","nil-owner","nil-name","empty-name","both-nil","both-empty"}) do
        local s=boot(true); s.timers.role.fn()
        s.api.local_player_controller=function()
            return {GetFullName=function()
                if kind=="both-nil" then return nil end
                if kind=="both-empty" then return "" end
                return "LocalController"
            end}
        end
        local context={get=function()
            if kind=="throws" then error("unavailable context") end
            if kind=="nil-owner" then return nil end
            return {GetFullName=function()
                if kind=="nil-name" or kind=="both-nil" then return nil end
                if kind=="empty-name" or kind=="both-empty" then return "" end
                return "ForeignController"
            end}
        end}
        local epoch=s.session.epoch
        local ran=false
        s.session.enqueue(function() ran=true end,true)
        s.hooks['/Script/Engine.PlayerController:ClientRestart'].before(context)
        assert(s.session.epoch==epoch,kind.." restart reset the local session")
        assert(s.store.decided and s.caps.decided,kind.." restart disabled local writers")
        s.session.drain()
        assert(ran,kind.." restart discarded a local edit")
    end
end)

test("identified local restart invalidates queued edits and resets writer roles",function()
    local s=boot(true); s.timers.role.fn()
    local pc={GetFullName=function() return "LocalController" end}
    s.api.local_player_controller=function() return pc end
    local epoch=s.session.epoch
    local ran=false
    s.session.enqueue(function() ran=true end,true)
    s.hooks['/Script/Engine.PlayerController:ClientRestart'].before({get=function() return pc end})
    assert(s.session.epoch==epoch+1,"local restart did not advance session")
    assert(not s.store.decided and not s.caps.decided,"local restart retained writer role")
    s.session.drain()
    assert(not ran,"old local edit survived a confirmed restart")
    assert(s.timers.role and s.timers.pass and s.timers.ui,"local restart lost recurring work: "..table.concat(s.console,"\n"))
end)

test("native Escape ownership suppresses only the duplicate raw panel action",function()
    local s=boot(true)
    local panel,overlay=package.loaded.panel,package.loaded.overlay
    local cancelled=0
    panel.open=true; panel.escape=function() cancelled=cancelled+1 end
    local function escape() s.keys.ESCAPE.fn(); s.session.drain() end
    overlay.native_cancel=true
    escape()
    assert(cancelled==0,'raw Escape duplicated the native widget request')
    overlay.native_cancel=false; escape()
    overlay.native_cancel=nil; escape()
    assert(cancelled==2,'old or missing pak lost its Escape fallback')
    panel.open=false; escape()
    assert(cancelled==2,'closed panel claimed vanilla Escape')
end)

test("synchronization status does not require an upstream connection on authority",function()
    local s=boot(true); s.timers.role.fn()
    local latches=s.latch_calls
    for _,status in ipairs({"connecting","ready","incompatible"}) do
        s.net.status=status -- A client transport field cannot describe host readiness.
        s.console={}; s.commands.status()
        assert(table.concat(s.console,'\n'):find('synchronization: not required; local authority',1,true),
            'authority reported client synchronization state: '..status)
        assert(s.net.status==status,'status changed transport state')
    end
    assert(s.latch_calls==latches and #s.outgoing==0 and s.scheduler_calls==0,
        'synchronization diagnostic initiated role discovery, transport or scheduling')
end)

test("both settings stores receive the same current role epoch",function()
    for _,authority in ipairs({true,false}) do
        local s=boot(authority);s.timers.role.fn()
        assert(s.store.session==s.session.epoch and s.caps.session==s.session.epoch)
        local next_epoch=s.session.epoch+1
        s.store.set_role(nil,next_epoch);s.net.on_session(next_epoch)
        assert(s.store.session==next_epoch and s.caps.session==next_epoch)
        assert(not s.store.decided and not s.caps.decided)
    end
end)

test("incompatible reported before the client role keeps the panel on incompatible",function()
    -- 2026-10-19, rc1 client joining a 0.4.1 server: net went incompatible
    -- before the role tick, caps.set_role reset the panel to "connecting", and
    -- net never re-sent an unchanged status.
    local s=boot(false)
    local net=s.net
    net.begin_session(s.session.epoch)
    assert(not net.receive_state("PWP_Rule|Mining|Stone|100"))
    assert(net.status=="incompatible" and net.status_reason=="server_requires_matching_mod")
    s.timers.role.fn()
    assert(s.caps.decided and s.caps.is_client)
    local state,reason=s.caps.view_status()
    assert(state=="incompatible" and reason=="server_requires_matching_mod",
        'panel status was reset to '..tostring(state)..' after the role decision')
    local label=require('panel_status').save(s.caps)
    assert(label=="incompatible", 'panel save state '..tostring(label))
end)

test("synchronization status follows real client handshake and complete snapshots",function()
    local s=boot(false); s.timers.role.fn()
    local net,wire=s.net,require("protocol")
    net.begin_session(s.session.epoch)
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; connecting',1,true))
    assert(net.receive_state(table.concat({"PWP_Welcome",net.SCHEMA,net.WORKS,net.local_nonce,"server-1","guild-A",1},"|")))
    for _,stream in ipairs({"R","P"}) do
        for _,packet in ipairs(assert(wire.snapshot("server-1",net.local_nonce,"guild-A",stream,1,"F",{}))) do
            assert(net.receive_state(packet))
        end
        s.console={}; s.commands.status()
        local expected=stream=="P" and "ready" or "connecting"
        assert(table.concat(s.console,'\n'):find('synchronization: client; '..expected,1,true),
            'client readiness did not follow both complete snapshots')
    end
    net.begin_session(s.session.epoch)
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; connecting',1,true),
        're-handshake retained ready status')
    assert(not net.receive_state(table.concat({"PWP_Welcome",net.SCHEMA+1,net.WORKS,net.local_nonce,"server-2","guild-A",1},"|")))
    assert(net.status=="incompatible")
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; incompatible',1,true))
    -- Other transport states must not be flattened into a success claim.
    for _,status in ipairs({"rejected","applied_unsaved"}) do
        net.status=status
        s.console={}; s.commands.status()
        assert(table.concat(s.console,'\n'):find('synchronization: client; '..status,1,true))
    end
    net.status=nil
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; unknown',1,true))
end)

test("synchronization status stays unknown through unsettled role and session transitions",function()
    local s=boot(nil)
    s.net.status="ready" -- Stale transport success is not role/session evidence.
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: unknown; session role not established',1,true))
    s.authority=true
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: unknown; session role not established',1,true),
        'authority observation bypassed undecided session settings')
    s.timers.role.fn()
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: not required; local authority',1,true))
    s.authority=false
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: unknown; session role not established',1,true),
        'changed native role reused the old authority decision')
    s.store.set_role(nil); s.caps.set_role(nil,s.session.epoch)
    s.net.begin_session(s.session.epoch); s.timers.role.fn()
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; connecting',1,true))
    s.net.status="ready"
    s.authority=nil
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: unknown; session role not established',1,true),
        'unknown authority retained client success')
    s.authority=false
    s.session.begin("replacement")
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: unknown; session role not established',1,true),
        'new session displayed an old ready connection')
    s.store.set_role("client"); s.caps.set_role("client",s.session.epoch)
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; unknown',1,true),
        'new client role accepted transport from the previous epoch')
    s.net.begin_session(s.session.epoch)
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('synchronization: client; connecting',1,true))
end)

test("status never presents client config as confirmed server staffing or storage policy",function()
    local s=boot(nil)
    local cfg=upvalue(s.commands.status,'cfg')
    cfg.assignment_mode='fill'; cfg.max_pals_per_work_type=17; cfg.storage_scope='global'
    cfg.enabled=false;cfg.dry_run=true;cfg.interval_seconds=7
    local function status()
        s.console={}; s.commands.status(); local output=table.concat(s.console,'\n')
        assert(output:find('| local configuration: disabled | dry run | every 7s',1,true),
            'local enabled/dry/interval settings lack their local configuration label')
        return output
    end
    local function no_local_policy(output)
        assert(not output:find('mode: fill',1,true)
            and not output:find('max per work type: 17',1,true)
            and not output:find('limits measured against:',1,true),
            'local config was advertised as active server policy')
    end
    local output=status()
    no_local_policy(output)
    assert(output:find('unavailable until authority is established',1,true))
    s.authority=false;s.timers.role.fn()
    for _,transport in ipairs({'connecting','ready'}) do
        s.net.status=transport
        output=status();no_local_policy(output)
        assert(output:find('server controlled; not synchronized',1,true))
        assert(output:find('confirmed scope in Production Limits',1,true))
    end
    local host=boot(true);host.timers.role.fn()
    local host_cfg=upvalue(host.commands.status,'cfg')
    host_cfg.assignment_mode='fill';host_cfg.max_pals_per_work_type=17;host_cfg.storage_scope='global'
    host.console={};host.commands.status();output=table.concat(host.console,'\n')
    assert(output:find('| local configuration: enabled | live | every 10s',1,true))
    assert(output:find('mode: fill, max per work type: 17',1,true))
    assert(output:find('limits measured against: every loaded base',1,true))
    host_cfg.storage_scope='camp';host.console={};host.commands.status()
    assert(table.concat(host.console,'\n'):find('limits measured against: each base on its own',1,true))
    assert(s.scheduler_calls==0 and host.scheduler_calls==0,'status ran scheduling')
end)

test("status reports only the cached storage diagnostic without another scan",function()
    local s=boot(true); s.timers.role.fn()
    local camps=0
    s.api.base_camps=function() camps=camps+1; return {} end
    local function forbidden() error("status initiated a new storage scan") end
    s.api.chest_totals_by_camp=forbidden
    s.api.camp_item_totals=forbidden
    s.api.all_chest_totals=forbidden
    s.console={}; s.commands.status()
    assert(table.concat(s.console,'\n'):find('last storage scan: unavailable',1,true),
        'status fabricated a complete scan before one occurred')
    s.api.last_storage_scan={reader='by_camp',complete=false,deduplicated=true,
        unknown_scope=2,failed_reads=3,reasons={scope=2,quantity=1}}
    s.console={}; s.commands.status()
    local output=table.concat(s.console,'\n')
    assert(output:find('last storage scan (by_camp; cached diagnostic)',1,true))
    assert(output:find('complete=false deduplicated=true unknown_scope=2 failed_reads=3',1,true))
    assert(output:find('quantity=1, scope=2',1,true))
    assert(camps==2,'storage status added another native camp lookup')
end)

test("input painting does not inline a scheduler pass or due maintenance",function()
    local s=boot(true); s.timers.role.fn(); s.viewport=true
    for _=1,9 do s:ui_beat() end
    local edited=false
    s.session.enqueue(function() edited=true; s.ui.wants_pass=true end,true)
    s.timers.ui.fn()
    assert(edited and s.scheduler_calls==0 and s.stand_refreshes==0,
        "input callback still combines painting, maintenance and reconciliation")
    assert(s.deferred.maintenance and s.deferred.reconcile)
    s:background()
    assert(s.scheduler_calls==1 and s.stand_refreshes==1)
    s.ui.wants_pass=true; s.timers.ui.fn()
    s.session.begin("replacement")
    s:background()
    assert(s.scheduler_calls==1,"deferred old-session reconciliation survived")
end)

test("queued keys drain on the first 100ms beat without accelerating maintenance",function()
    local s=boot(true); s.timers.role.fn(); s.viewport=true
    local values={}
    s.ui.raw_nav=function(_,direction)
        local value=direction=='up' and 1 or 2
        assert(s.store.set("PAL-A",1,value))
        assert(s.store.state=="saved" and s.fs.files[ROOT.."priorities.txt"]:find("PAL-A|1|"..value,1,true),
            "queued edit returned before its durable save")
        values[#values+1]=value
        s.ui.wants_pass=true
    end
    assert(s.keys.ONE==nil and s.keys.TWO==nil and s.keys.X==nil,
        'global number observer bypasses native stand keyboard ownership')
    s.keys.UP_ARROW.fn(); s.keys.DOWN_ARROW.fn()
    assert(#values==0 and s.store.get("PAL-A",1)==false,"key callback executed game-thread work inline")
    assert(s.timers.ui.ms==100)
    s.now=s.now+0.1; s:ui_beat()
    assert(table.concat(values,",")=="1,2","queued keys waited for the one-second maintenance gate")
    local input=s.log.marks["input: queued actions"]
    assert(input and input.n==1 and input.timed_n==0,"disabled input profiling recorded timings")
    assert(s.scheduler_calls==1,"one FIFO edit batch did not produce exactly one pass")
    assert(s.maintenance_calls==0 and s.stand_refreshes==0,"input accelerated full maintenance or stand redraw")
    for _=1,8 do s.now=s.now+0.1; s:ui_beat() end
    assert(s.scheduler_calls==1 and s.maintenance_calls==0 and s.stand_refreshes==0)
    s.now=s.now+0.1; s:ui_beat()
    assert(s.maintenance_calls==1 and s.stand_refreshes==1,"ordinary stand cadence is no longer one second")
    s.log.set_perf(true)
    s.session.enqueue(function() s.now=s.now+0.025 end,true)
    s.now=s.now+0.1; s:ui_beat()
    input=s.log.marks["input: queued actions"]
    assert(input.timed_n==1 and math.abs(input.ms-25)<0.001,"input timer omitted queued action work")
end)

test("slow rapid edits stay FIFO across beats and reconcile once after the burst",function()
    local s=boot(true); s.timers.role.fn()
    local values={}
    for _,value in ipairs({2,3,4}) do
        s.session.enqueue(function()
            assert(s.store.set('PAL-A',1,value))
            values[#values+1]=value; s.ui.wants_pass=true
            s.now=s.now+.020
        end,true)
    end
    s:ui_beat()
    assert(#values==1 and s.scheduler_calls==0 and s.session.has_pending())
    s:ui_beat()
    assert(#values==2 and s.scheduler_calls==0)
    s:ui_beat()
    assert(table.concat(values,',')=='2,3,4' and s.scheduler_calls==1 and not s.session.has_pending())
end)

test("one queued batch preserves real wrapping cycles and invalidation",function()
    local s=boot(true); s.timers.role.fn()
    assert(s.store.set("PAL-A",1,1))
    local values={}
    local function cycle(dir)
        local value=s.store.cycle(s.store.get("PAL-A",1),dir)
        assert(s.store.set("PAL-A",1,value))
        values[#values+1]=value; s.ui.wants_pass=true
    end
    s.session.enqueue(function() cycle(-1) end,true)
    s.session.enqueue(function() cycle(1) end,true)
    s.now=s.now+0.1; s:ui_beat()
    assert(#values==2 and values[1]==false and values[2]==1 and s.store.get("PAL-A",1)==1,
        "FIFO wraparound was collapsed to a net direction or clicks were lost")
    assert(s.scheduler_calls==1)
    s.session.enqueue(function() s.session.invalidate_ui() end,true)
    s.session.enqueue(function() cycle(1) end,true)
    s.now=s.now+0.1; s:ui_beat()
    assert(#values==2 and s.scheduler_calls==1,"UI invalidation did not cancel the rest of the batch")
    s.session.enqueue(function() cycle(1) end,true)
    s.session.begin("replacement world")
    s.now=s.now+0.1; s:ui_beat()
    assert(#values==2,"world change retained a queued edit")
end)

test("panel and stand requests share one pass and retain requests raised during it",function()
    local s=boot(true); s.timers.role.fn(); s.panel.open=true
    s.panel.wants_pass=true; s.ui.wants_pass=true
    s.handler=function()
        s.ui.wants_pass=true
        return {camps=2,pals=14}
    end
    s.now=s.now+0.1; s:ui_beat()
    assert(s.scheduler_calls==1,"panel and stand requests ran duplicate passes")
    assert(not s.panel.wants_pass and s.ui.wants_pass,"a request raised during the pass was consumed early")
    s.handler=nil
    s.now=s.now+0.1; s:ui_beat()
    assert(s.scheduler_calls==2 and not s.ui.wants_pass)
    s.now=s.now+0.1; s:ui_beat()
    assert(s.scheduler_calls==2,"consumed pass flags repeated")
end)

test("a periodic pass before queued edits does not suppress their reconciliation",function()
    local s=boot(true); s.timers.role.fn()
    local seen={}
    s.handler=function()
        seen[#seen+1]=s.store.get("PAL-A",1)
        return {camps=2,pals=14}
    end
    s.session.enqueue(function()
        assert(s.store.set("PAL-A",1,2))
        s.ui.wants_pass=true
    end,true)
    -- The clock may visit the periodic entry before the UI entry on one beat.
    s.now=s.now+0.1; s.timers.pass.fn(); s:ui_beat()
    assert(s.scheduler_calls==2 and seen[1]==false and seen[2]==2,
        "the periodic pass's old policy suppressed reconciliation of a later edit")
    assert(not s.ui.wants_pass)
    s.now=s.now+0.1; s:ui_beat()
    assert(s.scheduler_calls==2,"the consumed edit request repeated on the next beat")
end)

test("headless and authority idle beats do not poll client transport or inspect UI",function()
    for _,role in ipairs({"unknown","authority"}) do
        local s=boot(role=="authority" and true or nil); s.timers.role.fn()
        local polls=0; s.net.poll=function() polls=polls+1 end
        local viewport=s.viewport_calls
        for _=1,9 do s.now=s.now+0.1; s:ui_beat() end
        assert(polls==0 and s.viewport_calls==viewport and s.ui_calls==0,
            "idle input beats added client transport or native UI work")
        s.now=s.now+0.1; s:ui_beat()
        assert(polls==0 and s.ui_calls==0,"headless maintenance polled client transport or rendered UI")
    end
end)

test("real client coalescing sends the ordered final value on the next beat",function()
    local s=boot(false); s.timers.role.fn()
    local net,wire=s.net,require("protocol")
    net.begin_session(s.session.epoch)
    assert(net.receive_state(table.concat({"PWP_Welcome",net.SCHEMA,net.WORKS,net.local_nonce,"server-1","guild-A",1},"|")))
    local rows={R={},P={"PAL-A|"..string.rep("1",wire.WORKS).."|"..string.rep("1",wire.WORKS)}}
    for _,stream in ipairs({"R","P"}) do
        for _,packet in ipairs(assert(wire.snapshot("server-1",net.local_nonce,"guild-A",stream,1,"F",rows[stream]))) do
            assert(net.receive_state(packet))
        end
    end
    assert(net.status=="ready")
    s.outgoing={}
    local saved=s.fs.files[ROOT.."priorities.txt"]
    local values={}
    local function cycle(dir)
        local current,present=net.pending_priority("PAL-A",1)
        if not present then current=net.pals["PAL-A"].prios[1] end
        local value=s.store.cycle(current,dir)
        assert(s.store.set("PAL-A",1,value))
        values[#values+1]=value; s.ui.wants_pass=true
    end
    s.session.enqueue(function() cycle(-1) end,true)
    s.session.enqueue(function() cycle(1) end,true)
    s.now=s.now+0.1; s:ui_beat()
    assert(#values==2 and values[1]==false and values[2]==1 and net.pending_priority("PAL-A",1)==1,
        "client batch did not read its latest pending value")
    assert(#s.outgoing==0,"edit bypassed the transport coalescing deadline")
    s.now=s.now+0.1; s:ui_beat()
    assert(#s.outgoing==1 and s.outgoing[1].name:match("|Prio|PAL%-A|1|1$"),
        "client coalescing waited another maintenance second or sent intermediate values")
    assert(s.scheduler_calls==0 and s.fs.files[ROOT.."priorities.txt"]==saved,
        "client input ran authority scheduling or saved a local priority")
    assert(s.maintenance_calls==0 and s.stand_refreshes==0,"client polling accelerated full refresh")
end)

test("headless boot and unresolved authority",function()
    local s=boot(nil)
    assert(not s.store.decided and not s.caps.decided)
    assert(s.timers.role.ms==2000)
    s.timers.role.fn()
    s.timers.pass.fn()
    assert(s.scheduler_calls==0 and not s.store.decided and not s.caps.decided)
    assert(s.commands.run("unknown 1 normal")==false)
    assert(s:ack("unknown",1):find("status=aborted",1,true))
    assert(s.scheduler_calls==0)
    for _=1,10 do s:ui_beat() end
    if s.loops[16] then s.loops[16]() end
    assert(s.ui_calls==0,"headless maintenance called a native UI adapter")
    s.authority=true
    s.timers.role.fn()
    assert(s.store.decided and s.caps.decided and not s.store.is_client and not s.caps.is_client)
    assert(s.store.submit==nil and s.caps.submit==nil)
    assert(type(s.store.on_change)=="function" and type(s.caps.on_change)=="function")
    s.timers.pass.fn()
    assert(s.scheduler_calls==1,"headless authority never entered its scheduler")
end)

test("unknown native menu state never becomes a permission to recover input",function()
    local s=boot(true)
    local hook=s.hooks['/Script/Pal.PalHUDService:IsAnyOverlayUIActive'].after
    hook(nil,{get=function() return false end})
    assert(s.api.game_ui_active==false)
    hook(nil,{get=function() return nil end})
    assert(s.api.game_ui_active==nil,'nil UI observation was read as no vanilla menu')
    hook(nil,{get=function() return true end})
    assert(s.api.game_ui_active==true)
    hook(nil,{get=function() error('unavailable') end})
    assert(s.api.game_ui_active==nil,'failed UI observation retained stale focus evidence')
end)

test("stand snapshots distinguish a known empty roster from unavailable data",function()
    local s=boot(true)
    local rows=upvalue(s.net.on_command,'stand_rows')
    s.api.camps_available=true
    s.api.base_camps=function() return {} end
    assert(#assert(rows('guild-local'))==0)
    s.api.camps_available=false
    assert(rows('guild-local')==nil,'failed enumeration became a completed empty roster')
    s.api.camps_available=true
    s.api.base_camps=function() return {{}} end
    s.api.camp_guild=function() return 'guild-local' end
    s.api.camp_pals=function() return {{key='PAL-A',param={}}} end
    s.api.suitability_rank=function() return 1 end
    assert(#assert(rows('guild-local'))==1)
    s.api.suitability_rank=function() return nil end
    assert(rows('guild-local')==nil,'unknown rank was broadcast as zero capability')
    s.api.suitability_rank=function() return 1 end
    s.api.camp_pals=function() return {{key='PAL-A',param={}}},'slot 2 unreadable' end
    assert(rows('guild-local')==nil,'partial roster was broadcast as complete')
    s.authority=false
    assert(rows('guild-local')==nil,'stale host role permitted native Pal reads')
end)

test("one stand push shares discovery across guilds but not across pushes",function()
    local s=boot(true)
    local push=upvalue(s.net.on_command,'push_stand')
    local scans, reads=0,0
    s.api.camps_available=true
    s.api.base_camps=function() scans=scans+1; return {{guild='a'},{guild='b'}} end
    s.api.camp_guild=function(camp) return camp.guild end
    s.api.camp_pals=function(camp)
        reads=reads+1; return {{key='PAL-'..camp.guild,param={}}}
    end
    s.api.suitability_rank=function() return 1 end
    s.net.push_pals=function(rows)
        local a,b=assert(rows('a')),assert(rows('b'))
        assert(#a==1 and a[1].key=='PAL-a' and #b==1 and b[1].key=='PAL-b',
            'shared discovery leaked another guild roster')
        assert(rows('a')==a,'same guild rebuilt within one push')
        return true
    end
    local before=s.latch_calls
    push({})
    assert(scans==1 and s.latch_calls-before==1 and reads==2,
        'one push repeated authority/camp discovery per guild')
    push({})
    assert(scans==2 and s.latch_calls-before==2 and reads==4,
        'a later push reused engine observations')
    s.api.camps_available=false
    s.net.push_pals=function(rows)
        assert(rows('a')==nil and rows('b')==nil,'failed scan became an empty snapshot')
        return false
    end
    push({})
    assert(scans==3 and reads==4,'failed discovery was retried per guild or read Pals')
    s.api.camps_available=true
    s.net.push_pals=function(rows)
        assert(rows('a')); s.session.epoch=s.session.epoch+1
        assert(rows('b')==nil,'session transition reused prior camp observations')
        return false
    end
    push({})
end)

test("setprio edits through store.set from remote and is refused from chat",function()
    local s=boot(true); s.timers.role.fn()
    assert(s.store.decided and not s.store.is_client,'host role not decided')
    local ui=package.loaded.ui; ui.wants_pass=false
    assert(s.commands.setprio('PAL-A 2 3')==true,'remote setprio refused')
    assert(s.store.get('PAL-A',2)==3 and ui.wants_pass==true,'edit did not land or flag the pass')
    assert(s.fs.files[ROOT..'priorities.txt']:find('PAL-A|2|3',1,true),'host edit not saved at once')
    assert(s.commands.setprio('PAL-A 2 X')==true and s.store.get('PAL-A',2)==false)
    assert(s.fs.files[ROOT..'priorities.txt']:find('PAL-A|2|X',1,true),'X not written')
    assert(s.commands.setprio('PAL-A 2 9')==false and s.store.get('PAL-A',2)==false,'invalid value applied')
    assert(s.commands.setprio('only two')==false)
    assert(s.commands.setprio('PAL-A 2 clear')==true and s.store.get('PAL-A',2)==nil,'clear left the row')
    assert(not s.fs.files[ROOT..'priorities.txt']:find('PAL-A|2|',1,true),'cleared row still on disk')
    assert(s.store.get('PAL-A',1)==false,'clear touched another row')
    local handle=upvalue(package.loaded.remote.command,'handle_command')
    local before=s.store.get('PAL-A',2)
    assert(handle('!pwp setprio PAL-A 2 1',true,true)==true)
    assert(s.store.get('PAL-A',2)==before,'chat line from the host ran a remote-only command')
end)

test("command results are derived from completed scheduler stats",function()
    local s=boot(true); s.timers.role.fn()
    assert(s.commands.run("verified 1 normal")==true)
    assert(s:ack("verified",1):find("pass=1 session=0 status=completed mode=normal camps=2",1,true))
    package.loaded.remote.command("run verified 2 normal")
    assert(s:ack("verified",2):find("pass=2 ",1,true))
    assert(s.scheduler_calls==2)
    local bad={
        false,
        {camps=0,pals=0},
        {camps=2,pals=0},
        {camps=2,pals=14,blocked_reason="scope unavailable"},
        {camps=2,pals=14,failed=1},
        {camps=2,pals=14,unreadable=1},
        {camps=2,pals=14,baseline_unavailable=1},
    }
    for i,result in ipairs(bad) do
        s.handler=function(_,scheduler)
            scheduler.pass_id=scheduler.pass_id+1
            if result==false then return nil end
            return result
        end
        assert(s.commands.run("bad "..i.." normal")==false,"bad pass was acknowledged")
        assert(s:ack("bad",i):find("status=aborted",1,true))
    end
end)

-- Explicitly resolved scheduler evidence; zero requests can mean the observed
-- permissions already match. Native assignment/output behavior is not mocked
-- into existence by this fixture: it only tests the command receipt contract.
local function evidenced_stats(overrides)
    local stats={camps=2,pals=14,toggles=0,would_toggle=0,failed=0,unreadable=0,
        baseline_unavailable=0,assignment_unknown=0,manual_unavailable=0,
        unverified_limit_conflicts=0,storage_unverified=0,deferred=0,
        pending_writes=0,expired_writes=0,awaiting_withdrawal=0}
    for key,value in pairs(overrides or {}) do stats[key]=value end
    return stats
end

local function completed_stats(s,stats)
    s.handler=function(_,scheduler)
        scheduler.pass_id=scheduler.pass_id+1
        return stats
    end
end

test("live-shaped unknown assignment and storage cannot complete gameplay stress",function()
    local s=boot(true); s.timers.role.fn()
    completed_stats(s,evidenced_stats({assignment_unknown=14,manual_unavailable=14,
        unverified_limit_conflicts=7,storage_unverified=2}))
    assert(s.commands.run("native-evidence 1 normal")==false,
        "14 unknown assignments and unverified storage were accepted as completed")
    local marker=s:ack("native-evidence",1)
    assert(marker:find("pass=1 session=0 status=unverified mode=normal camps=2 dry=false pending=0",1,true))
    assert(marker:find("invocation=completed",1,true),"completed invocation was lost")
end)

for _,field in ipairs({"assignment_unknown","manual_unavailable",
    "unverified_limit_conflicts","storage_unverified"}) do
    test("command receipt rejects unverified evidence: "..field,function()
        local s=boot(true); s.timers.role.fn()
        completed_stats(s,evidenced_stats({[field]=1}))
        assert(s.commands.run("uncertain 1 normal")==false,field.." was accepted as completed")
        local marker=s:ack("uncertain",1)
        assert(marker:find("status=unverified ",1,true))
        assert(marker:find("invocation=completed",1,true))
    end)
end

for _,field in ipairs({"deferred","pending_writes","expired_writes","awaiting_withdrawal"}) do
    test("command receipt rejects unfinished work: "..field,function()
        local s=boot(true); s.timers.role.fn()
        -- A request count is not delivery evidence. Also test each unfinished
        -- field alone: withdrawal gates and budget deferrals need no pending RPC.
        completed_stats(s,evidenced_stats({[field]=1,
            toggles=field=="deferred" and 40 or (field=="pending_writes" and 1 or 0)}))
        assert(s.commands.run("unfinished 1 normal")==false,field.." was accepted as completed")
        local marker=s:ack("unfinished",1)
        assert(marker:find("status=incomplete ",1,true))
        assert(marker:find("invocation=completed",1,true))
        assert(marker:find("pending="..(field=="pending_writes" and "1" or "0").." ",1,true))
    end)
end

test("unverified evidence outranks pending work but existing failures stay aborted",function()
    local s=boot(true); s.timers.role.fn()
    local stats=evidenced_stats({storage_unverified=1,pending_writes=1})
    completed_stats(s,stats)
    assert(s.commands.run("precedence 1 normal")==false)
    assert(s:ack("precedence",1):find("status=unverified ",1,true))
    stats.failed=1
    assert(s.commands.run("precedence 2 normal")==false)
    local marker=s:ack("precedence",2)
    assert(marker:find("status=aborted ",1,true))
    assert(marker:find("invocation=aborted",1,true))
end)

test("resolved zero-request passes complete and mode overrides retain the actual dry state",function()
    local s=boot(true); s.timers.role.fn()
    local stats=evidenced_stats()
    completed_stats(s,stats)
    for i,mode in ipairs({"normal","sweep","dry"}) do
        -- Dry plans can propose changes without claiming those changes landed.
        stats.would_toggle=mode=="dry" and 3 or 0
        assert(s.commands.run("resolved "..i.." "..mode)==true)
        local marker=s:ack("resolved",i)
        assert(marker:find("status=completed mode="..mode,1,true))
        assert(marker:find("dry="..tostring(mode=="dry").." ",1,true))
        assert(marker:find("invocation=completed",1,true))
        assert(s.seen_dry==(mode=="dry") and s.seen_ttl==(mode=="sweep" and 0 or 30))
        assert(s.cfg().dry_run==false and s.scheduler.stock_ttl==30)
    end
    s.cfg().dry_run=true
    assert(s.commands.run("resolved 4 normal")==true)
    assert(s:ack("resolved",4):find("dry=true ",1,true),"normal mode concealed pre-existing dry state")
    assert(s.cfg().dry_run==true)
end)

test("dry and sweep overrides restore after unverified or incomplete receipts",function()
    local s=boot(true); s.timers.role.fn()
    for i,case in ipairs({{mode="dry",field="assignment_unknown",status="unverified"},
        {mode="sweep",field="deferred",status="incomplete"}}) do
        completed_stats(s,evidenced_stats({[case.field]=1}))
        assert(s.commands.run("uncertain-mode "..i.." "..case.mode)==false)
        local marker=s:ack("uncertain-mode",i)
        assert(marker:find("status="..case.status.." ",1,true))
        assert(marker:find("dry="..tostring(case.mode=="dry").." ",1,true))
        assert(marker:find("invocation=completed",1,true))
        assert(s.cfg().dry_run==false and s.scheduler.stock_ttl==30)
    end
end)

test("restoration cannot succeed from sent counts or an inert result",function()
    local s=boot(true); s.timers.role.fn()
    local restore=upvalue(s.commands.restore,'restore_all')
    for _,stats in ipairs({
        {camps=2,pals=14,toggles=3,pending_writes=3,deferred=3},
        {camps=2,pals=14,toggles=0,unreadable=1},
        {camps=2,pals=14,toggles=2,failed=1},
        {camps=0,pals=0,toggles=0},
    }) do
        s.scheduler.restore=function() return stats end
        assert(restore('test')==false,'unconfirmed restoration reported success')
    end
    s.scheduler.restore=function() return {camps=2,pals=14,toggles=0,deferred=0} end
    assert(restore('test')==true)
end)

test("network priority edits own exactly one notification including no-op and retry scopes",function()
    local s=boot(true); s.timers.role.fn()
    s.net.who=function() return 'owner' end
    s.net.guild_of_sender=function() return 'guild-local' end
    s.net.clients.owner={}
    s.api.camps_available=true
    s.api.base_camps=function() return {{}} end
    s.api.camp_guild=function() return 'guild-local' end
    s.api.camp_pals=function() return {{key='PAL-A',param={}},{key='PAL-B',param={}}} end
    s.api.suitability_rank=function() return 1 end
    local pushes={}
    s.net.push_pals=function(rows,_,key)
        assert(#assert(rows('guild-local'))==2)
        pushes[#pushes+1]={key=key}; return true
    end
    local function edit(value,expected)
        local before=#pushes
        s.now=s.now+31 -- distinct rate-limit window
        local result=s.net.on_command('PWP_Prio|PAL-A|1|'..value,0,{})
        assert(result==true and #pushes==before+1,'edit emitted duplicate or missing snapshot')
        assert(pushes[#pushes].key==expected,'edit narrowed or widened the committed scope incorrectly')
    end
    edit('2','PAL-A')
    edit('-','PAL-A')
    edit('-','PAL-A') -- clean no-op still needs a response revision
    assert(s.store.apply_set('PAL-B',1,3))
    edit('-',nil) -- no-op A must not hide dirty B
    assert(s.store.apply_set('PAL-A',1,3))
    assert(s.store.apply_set('PAL-B',1,2))
    edit('2',nil) -- successful deferred multi-key commit needs one full push
    s.fs.fault=function(op,path) return op=='write' and path==ROOT..'priorities.txt.tmp' end
    s.now=s.now+31
    local before=#pushes
    assert(s.net.on_command('PWP_Prio|PAL-A|1|4',0,{})=='applied_unsaved')
    assert(#pushes==before+1 and pushes[#pushes].key=='PAL-A')
    assert(s.store.apply_set('PAL-B',1,4))
    s.fs.fault=nil
    assert(s.store.flush(nil,true)) -- retry uses the regular callback, covering A and B
    assert(#pushes==before+2 and pushes[#pushes].key==nil)
    s.net.push_pals=function() return false end
    s.now=s.now+31
    assert(s.net.on_command('PWP_Prio|PAL-A|1|1',0,{})==true)
    assert(s.store.state=='saved','send failure was confused with a save failure')
end)

test("authenticated priority context avoids a second sender walk without bypassing authority",function()
    local s=boot(true); s.timers.role.fn()
    s.api.camps_available=true
    local lookups,reads=0,0
    s.net.who=function() return 'owner' end
    s.net.guild_of_sender=function() lookups=lookups+1; return 'guild-local' end
    s.net.clients.owner={server=s.net.local_nonce,client='client',guild='guild-local',
        acks={},order={},high=0,revisions={P=1,R=1}}
    s.api.base_camps=function() reads=reads+1; return {{}} end
    s.api.camp_guild=function() return 'guild-local' end
    s.api.camp_pals=function() return {{key='PAL-A',param={}}} end
    s.api.suitability_rank=function() return 1 end
    s.net.push_pals=function(rows) assert(#assert(rows('guild-local'))==1); return true end
    s.net.to_client=function() return true end
    local command=require('protocol').envelope('Q',s.net.local_nonce,'client','guild-local')
        ..'|1|Prio|PAL-A|1|2'
    assert(s.net.receive_command({},command,0)==true)
    assert(lookups==1,'main repeated the already authenticated sender lookup')
    s.now=s.now+31
    local original_apply=s.store.apply_set
    local attempted_write=false
    s.store.apply_set=function() attempted_write=true; return false end
    local original_rank=s.api.suitability_rank
    s.api.suitability_rank=function()
        s.net.receive_command({},'invalid',0) -- invalidate while reading roster
        return 1
    end
    assert(s.net.receive_command({},command:gsub('|1|Prio','|2|Prio'),0)==false)
    assert(not attempted_write,'invalidated invocation reached persistence')
    s.store.apply_set=original_apply
    s.api.suitability_rank=original_rank
    s.now=s.now+31
    local before=reads
    assert(not s.net.on_command('PWP_Prio|PAL-A|1|3',0,{},{}))
    assert(reads==before and lookups==2,'invalid context fell back to fresh authorization')
    for index,role in ipairs({false,'unknown'}) do
        s.now=s.now+31
        s.store.set_role(true)
        s.api.latch_authority=function() if role=='unknown' then return nil end return false end
        assert(s.net.receive_command({},command:gsub('|1|Prio','|'..(index+2)..'|Prio'),0)==false)
        assert(reads==before,'lost authority reached native roster reads')
    end
end)

test("network save failures distinguish applied memory from durable acceptance",function()
    local s=boot(true); s.timers.role.fn()
    s.net.who=function() return 'owner' end
    s.net.guild_of_sender=function() return 'guild-local' end
    local pushed=0
    s.net.push_rules=function() pushed=pushed+1; return true end
    s.fs.fault=function(op,path) return op=='write' and path==ROOT..'caps.txt.tmp' end
    local outcome=s.net.on_command('PWP_Set|Mining|Stone|300',0,{})
    assert(outcome=='applied_unsaved' and s.caps.data['guild-local'].Mining.Stone==300)
    assert(pushed==1 and s.caps.state=='error')
    s.fs.fault=nil
    assert(s.caps.flush(math.huge))
    s.authority=false
    assert(s.net.on_command('PWP_Set|Mining|Stone|400',0,{})==false)
    assert(not s.store.decided and not s.caps.decided)
    assert(s.caps.data['guild-local'].Mining.Stone==300)
end)

test("limit commands reject fractional amounts without changing a saved rule",function()
    local s=boot(true); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    s.commands.limit('Mining Stone 2.5')
    assert(s.caps.data['guild-local'].Mining.Stone==100,'fractional input was silently rounded')
end)

test("limit command does not call a queued client edit saved",function()
    local s=boot(false); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    s.caps.submit=function() return true end
    s.commands.limit('Mining Stone 300')
    local output=table.concat(s.console,'\n')
    assert(output:find('awaiting server confirmation',1,true),'queued change had no pending explanation')
    assert(not output:find('limit set:',1,true),'queued change was announced as set')
    assert(s.caps.data['guild-local'].Mining.Stone==100)
end)

test("limit clear save failure is not reported as a missing rule",function()
    local s=boot(true); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    s.fs.fault=function(op,path) return op=='write' and path==ROOT..'caps.txt.tmp' end
    s.commands.limit('Mining Stone off')
    local output=table.concat(s.console,'\n')
    assert(output:find('not saved',1,true),'failed clear did not explain durability failure')
    assert(not output:find('no limit was set',1,true),'save error was called an absent rule')
    assert(s.caps.state=='error')
end)

test("limit listing keeps unknown stock unavailable and labels legacy scope",function()
    local s=boot(true); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    s.commands.limit('')
    local output=table.concat(s.console,'\n')
    assert(output:find('unavailable',1,true),'unreadable stock was not disclosed')
    assert(output:find('switch their whole work type',1,true) and output:find('Mining limits stop only the rocks',1,true),
        'what a limit switches was not disclosed')
    assert(not output:find('0 / 100',1,true),'unreadable stock appeared as zero')
end)

test("a stale statistics table is not a newly completed pass",function()
    local s=boot(true); s.timers.role.fn()
    assert(s.commands.run("stale 1 normal")==true)
    s.handler=function() return {camps=2,pals=14,failed=0} end -- inert boundary; pass_id does not advance
    assert(s.commands.run("stale 2 normal")==false,"unchanged pass ID was reported as completed")
end)

test("per-command modes are restored after scheduler errors",function()
    local s=boot(true); s.timers.role.fn()
    for i,mode in ipairs({"dry","sweep"}) do
        s.handler=function(cfg,scheduler)
            if mode=="dry" then assert(cfg.dry_run==true and scheduler.stock_ttl==30)
            else assert(cfg.dry_run==false and scheduler.stock_ttl==0) end
            error("injected scheduler failure")
        end
        assert(s.commands.run("restore "..i.." "..mode)==false)
        assert(s:ack("restore",i):find("status=aborted",1,true))
        assert(s:ack("restore",i):find("invocation=aborted",1,true))
        assert(s.cfg().dry_run==false and s.scheduler.stock_ttl==30,"mode override escaped its command")
    end
    s.handler=nil
    assert(s.commands.run("restore 3 normal")==true,"failed pass left the reentrancy gate stuck")
end)

test("client writer routing and scoped snapshot callback",function()
    local s=boot(false); s.timers.role.fn()
    assert(s.store.is_client and s.caps.is_client and s.store.decided and s.caps.decided)
    assert(type(s.store.submit)=="function" and type(s.caps.submit)=="function")
    assert(s.store.on_change==nil and s.caps.on_change==nil)
    assert(s.commands.run("client 1 normal")==false and s.scheduler_calls==0)
    local before=s.fs.files[ROOT.."caps.txt"]
    local received
    local replace=s.caps.replace_all
    s.caps.replace_all=function(rows,epoch,guild)
        received={rows=rows,epoch=epoch,guild=guild}
        return replace(rows,epoch,guild)
    end
    local rows={{work="Mining",item="Ore",amount=250}}
    assert(s.net.on_snapshot(rows,{epoch=s.session.epoch,guild="guild-A"})==true)
    assert(received.epoch==s.session.epoch and received.guild=="guild-A")
    assert(s.caps.remote["guild-A"].Mining.Ore==250)
    assert(s.caps.data["guild-local"].Mining.Stone==100 and s.fs.files[ROOT.."caps.txt"]==before)
    assert(s.net.on_snapshot({}, {epoch=s.session.epoch,guild="guild-A"})==true,"empty valid snapshot is a successful clear")
    assert(s.net.on_snapshot(rows,{epoch=s.session.epoch+1,guild="guild-A"})==false)
    assert(s.net.on_snapshot(rows,{epoch=s.session.epoch,guild="bad|guild"})==false)
    assert(s.net.on_snapshot({{work="Mining",item="Ore",amount=0}}, {epoch=s.session.epoch,guild="guild-A"})==false)
    s.store.set_role(nil); s.caps.set_role(nil,s.session.epoch)
    assert(s.net.on_snapshot(rows,{epoch=s.session.epoch,guild="guild-A"})==false)
end)

test("real network receiver supplies metadata accepted by real main",function()
    local s=boot(false); s.timers.role.fn()
    local net,wire=s.net,require("protocol")
    net.begin_session(s.session.epoch)
    assert(net.receive_state(table.concat({"PWP_Welcome",net.SCHEMA,net.WORKS,net.local_nonce,"server-1","guild-A",1},"|")))
    local observed
    local callback=net.on_snapshot
    net.on_snapshot=function(rows,metadata)
        observed=metadata
        return callback(rows,metadata)
    end
    local packets=assert(wire.snapshot("server-1",net.local_nonce,"guild-A","R",1,"F",{"Mining|Ore|300"}))
    for _,packet in ipairs(packets) do assert(net.receive_state(packet)) end
    assert(observed and observed.epoch==s.session.epoch and observed.session==s.session.epoch)
    assert(observed.server_session=="server-1" and observed.guild=="guild-A")
    assert(s.caps.remote["guild-A"].Mining.Ore==300,"negotiated snapshot was discarded at composition boundary")
    assert(net.status_reason~="snapshot_apply_failed")
    assert(net.receive_state(wire.envelope('L','server-1',net.local_nonce,'guild-A')..'|settings_restart_required'))
    assert(s.caps.remote==nil and s.caps.remote_scope==nil,'server lock retained usable remote rules')
    local status,reason=s.caps.view_status()
    assert(status=='unavailable' and reason=='settings_restart_required')
    for _,packet in ipairs(packets)do assert(not net.receive_state(packet))end
    assert(s.caps.remote==nil and s.caps.data['guild-local'].Mining.Stone==100)
end)

test("local limit command distinguishes accepted async work from a rejection",function()
    local s=boot(true);s.timers.role.fn()
    s.api.my_guild=function()return 'guild-local'end
    local previous=package.loaded.panel_status
    package.loaded.panel_status={stock=function()return {verified=false,label='unavailable'}end}
    for _,outcome in ipairs({'pending','rejected'}) do
        s.console={}
        s.caps.set=function()return false,outcome end
        s.commands.limit('Mining Stone 101')
        local text=table.concat(s.console,'\n')
        assert((text:find('accepted; saving asynchronously',1,true)~=nil)==(outcome=='pending'))
        assert((text:find('limit change unconfirmed',1,true)~=nil)==(outcome=='rejected'))
        assert(not text:find('saved:',1,true),'pending/rejected result must not claim durability')
    end
    package.loaded.panel_status=previous
end)

test("remote pending mutations preserve receipts without publishing or scheduling",function()
    local s=boot(true);s.timers.role.fn()
    s.net.who=function()return 'owner'end
    s.net.guild_of_sender=function()return 'guild-local'end
    s.net.clients.owner={server=s.net.local_nonce,client='client',guild='guild-local',
        acks={},order={},high=0,revisions={P=1,R=1}}
    s.api.camps_available=true
    s.api.base_camps=function()return {{}}end
    s.api.camp_guild=function()return 'guild-local'end
    s.api.camp_pals=function()return {{key='PAL-A',param={}}}end
    s.api.suitability_rank=function()return 1 end
    local pushes,flushes,mutations=0,0,0
    s.net.push_rules=function()pushes=pushes+1;return true end
    s.net.push_pals=function()pushes=pushes+1;return true end
    s.store.flush=function()flushes=flushes+1;return true end
    local receipt={scope='internal receipt fixture',revision=1}
    local function pending()mutations=mutations+1;return false,'pending',receipt end
    s.store.apply_set=pending;s.store.apply_clear=pending
    s.caps.apply_set=pending;s.caps.apply_clear=pending
    local before=s.scheduler_calls
    for _,command in ipairs({'PWP_Prio|PAL-A|1|2','PWP_Prio|PAL-A|1|-',
        'PWP_Set|Mining|Stone|101','PWP_Clear|Mining|Stone'})do
        s.now=s.now+31
        local accepted,reason,r=s.net.on_command(command,0,{})
        assert(accepted==false and reason=='pending' and rawequal(r,receipt),
            'pending receipt lost: '..command)
    end
    assert(mutations==4 and pushes==0 and flushes==0 and s.scheduler_calls==before,
        'pending mutation published, polled again or ran scheduler')
    -- Actual transport must not turn this preserved pending result into a
    -- negative or positive ACK. Until completion integration is enabled, it
    -- remains unknown and the existing timeout/resync path owns recovery.
    local replies={}
    s.net.to_client=function(_,message)replies[#replies+1]=message;return true end
    s.now=s.now+31
    local request=require('protocol').envelope('Q',s.net.local_nonce,'client','guild-local')
        ..'|1|Set|Mining|Stone|102'
    assert(s.net.receive_command({},request,0)==false)
    assert(#replies==0,'pending mutation acknowledged as final outcome')
    assert(s.net.receive_command({},request,0)==false and #replies==0 and mutations==5,
        'pending duplicate reapplied or acquired a final outcome')
end)

test("orphaned async receipt cannot resume legacy writes or scheduling",function()
    for _,kind in ipairs({'present','denied','throws','close-failed'})do
        package.loaded.settings_gate=nil
        local s=boot(true,false,function(fs)
            local path=ROOT..'async-trial/receipt.lua'
            if kind=='present' or kind=='close-failed' then
                fs.files[path]='error("receipt must never execute")'
            end
            fs.fault=function(op,name)
                if name~=path then return false end
                if kind=='throws' and op=='open' then error('receipt probe failed') end
                return kind=='denied' and op=='open' or kind=='close-failed' and op=='close'
            end
        end,'async trial launcher missing but recovery receipt exists or is unreadable')
        local gate=require('settings_gate')
        assert(gate.blocked() and gate.status()=='restart_required',kind)
        s.timers.role.fn()
        local before=s.scheduler_calls
        local priorities=s.fs.files[ROOT..'priorities.txt']
        local limits=s.fs.files[ROOT..'caps.txt']
        s.commands.run('')
        assert(s.scheduler_calls==before,'orphaned trial scheduled old permissions: '..kind)
        assert(s.store.flush()~=true and s.caps.flush()~=true,'legacy writer admitted: '..kind)
        assert(s.fs.files[ROOT..'priorities.txt']==priorities and s.fs.files[ROOT..'caps.txt']==limits)
        assert(table.concat(s.console,'\n'):find('recovery receipt',1,true),kind)
    end
    package.loaded.settings_gate=nil
    local clean=boot(true)
    assert(not require('settings_gate').blocked(),'clean install fenced without receipt')
end)

test("cutover fence precedes settings recovery and launcher inspection",function()
    for _,kind in ipairs({'present','denied','throws','close-failed','close-throws','read-failed'})do
        package.loaded.settings_gate=nil
        local s=boot(true,false,function(fs)
            local marker=ROOT..'.settings-cutover'
            if kind~='denied' and kind~='throws' then
                fs.files[marker]='error("marker must never execute")'
            end
            fs.files[ROOT..'async-trial/launch.lua']='error("launcher must never execute")'
            fs.files[ROOT..'async-trial/receipt.lua']='error("receipt must never execute")'
            fs.fault=function(op,path)
                if path==marker then
                    if kind=='throws' and op=='open' or kind=='close-throws' and op=='close' then
                        error('marker IO exception')
                    end
                    return kind=='denied' and op=='open' or kind=='close-failed' and op=='close'
                        or kind=='read-failed' and op=='read'
                end
                return false
            end
        end,'settings cutover marker exists or is unreadable')
        local gate=require('settings_gate')
        assert(gate.blocked() and gate.status()=='restart_required',kind)
        assert(type(s.cfg())=='table','root config validation did not continue')
        s.timers.role.fn();s.timers.pass.fn();s:ui_beat();s.commands.run('')
        assert(s.scheduler_calls==0,'fenced startup ran scheduler: '..kind)
        assert(s.store.flush()~=true and s.caps.flush()~=true,'fenced startup flushed: '..kind)
        for _,operation in ipairs(s.fs.operations)do
            assert(not operation:find('priorities.txt',1,true) and not operation:find('caps.txt',1,true),
                'settings recovery touched while cutover fenced: '..operation)
            assert(not operation:find('async-trial/',1,true),'trial touched while cutover fenced: '..operation)
            assert(operation~='read:'..ROOT..'.settings-cutover','marker content read')
            assert(operation~='remove:'..ROOT..'.settings-cutover','marker auto-cleared')
        end
        assert(s.fs.files[ROOT..'priorities.txt']=='PAL-A|1|X\n')
        assert(s.fs.files[ROOT..'caps.txt']=='guild-local|Mining|Stone|100\n')
    end
    package.loaded.settings_gate=nil
    local clean=boot(true)
    assert(not require('settings_gate').blocked(),'positive marker absence fenced clean boot')
    local reads={}
    for _,op in ipairs(clean.fs.operations)do reads[op]=true end
    assert(reads['read:'..ROOT..'priorities.txt'] and reads['read:'..ROOT..'caps.txt'])
    assert(reads['open:'..ROOT..'async-trial/launch.lua'],'clean boot skipped normal trial check')
end)

test("a DarnMenu value validate refuses is skipped with a warning and the mod starts",function()
    -- Review A1: the page offered 2 seconds, validate wanted 5, and main.lua
    -- logged "did not start" on every launch.
    for _,bad in ipairs({2,7.5}) do
        darnmenu_user={interval_seconds=bad,dry_run=true}
        local ok,why=pcall(boot,true)
        darnmenu_user=nil
        package.loaded.darnmenu=nil
        assert(ok,"mod did not start with interval "..bad..": "..tostring(why))
        local s=why
        local output=table.concat(s.console,"\n")
        assert(not output:find("did not start",1,true),output)
        assert(s.cfg().interval_seconds==10 and s.cfg().dry_run==true,
            "bad menu value reached the config or cost the good one")
        assert(output:find('ignored "Seconds between rechecks" = '..tostring(bad),1,true),
            "no warning naming the option: "..output)
    end
end)

test("pwp rocks refuses on a client before touching base works",function()
    local s=boot(false); s.timers.role.fn()
    local camps=0
    s.api.base_camps=function() camps=camps+1; return {} end
    s.console={}; s.commands.rocks(); s.session.drain()
    local output=table.concat(s.console,"\n")
    assert(output:find("rocks: only the host or server can see this; run it there.",1,true),output)
    assert(camps==0,"client rocks read base camps")
end)

test("Delete asks the open panel to remove the selected limit and leaves the world alone",function()
    local s=boot(true)
    local panel=package.loaded.panel
    local calls={}
    panel.row_action=function(cfg,kind) calls[#calls+1]=kind; assert(cfg==s.cfg()) return true end
    assert(s.keys.DEL and type(s.keys.DEL.fn)=="function","Delete is not bound")
    panel.open=false; s.keys.DEL.fn(); s.session.drain()
    assert(#calls==0,"Delete acted with the panel closed")
    panel.open=true; s.keys.DEL.fn(); s.session.drain()
    assert(#calls==1 and calls[1]=="drop","Delete did not ask for drop")
end)

test("chat help and the load line are in player words",function()
    local s=boot(true)
    local loaded=table.concat(s.console,"\n")
    assert(loaded:find("help in chat (multiplayer) or see the README.",1,true),loaded)
    s.console={}; s.commands.help()
    local help=table.concat(s.console,"\n")
    for _,word in ipairs({"census","elimination","unfence","ceiling","authority","threshold"}) do
        assert(not help:lower():find(word,1,true),"help says "..word)
    end
    for _,want in ipairs({"list, set or remove production limits","Alt+F2 recheck now",
        "give every Pal all its work back (do this before removing the mod)"}) do
        assert(help:find(want,1,true),"help lacks "..want)
    end
end)

test("Alt hotkeys carry Alt and the panel keys carry no modifier",function()
    local s=boot(true)
    for _,key in ipairs({"F1","F2","F3","F5","F9","F10","F11","F12"}) do
        local bound=s.keys[key]
        assert(bound and type(bound.fn)=="function",key.." is not bound")
        assert(type(bound.mods)=="table" and #bound.mods==1 and bound.mods[1]=="ALT",
            key.." is bound without Alt")
    end
    for _,key in ipairs({"UP_ARROW","DOWN_ARROW","LEFT_ARROW","RIGHT_ARROW","RETURN","DEL","ESCAPE"}) do
        local bound=s.keys[key]
        assert(bound and type(bound.fn)=="function",key.." is not bound")
        assert(bound.mods==nil,key.." needs a modifier")
    end
end)

test("without an Alt modifier the Alt keys are not bound as plain keys",function()
    without_alt=true
    local ok,s=pcall(boot,true)
    without_alt=false
    assert(ok,s)
    for _,key in ipairs({"F1","F2","F3","F5","F9","F10","F11","F12"}) do
        assert(s.keys[key]==nil,key.." was bound as a plain key")
    end
    assert(s.keys.ESCAPE and s.keys.DEL,"the panel keys went with the Alt keys")
    local said=table.concat(s.console," | ")
    assert(said:find("no modifier key for it",1,true),"the missing hotkeys were not reported")
end)

test("chat help says rocks works on the host too",function()
    local s=boot(true)
    s.console={}; s.commands.help()
    local help=table.concat(s.console,"\n")
    assert(help:find("who mines what (host or server)",1,true),help)
end)

test("limit listing on a client asks the server and follows its Mining setting",function()
    local s=boot(false); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    -- As real net: storage requests only while the panel's interest is open,
    -- and an unverified view until the server's reply has arrived.
    local open,replied,requested=false,false,0
    s.net.epoch=s.net.epoch or 7
    s.net.set_storage_open=function(value) open=value==true end
    s.net.request_stock=function(guild)
        assert(guild=='guild-local')
        if not open then return false end
        requested=requested+1; return true
    end
    s.net.storage_view=function(guild)
        if not open or not replied then
            return {verified=false,guild=guild,epoch=s.net.epoch,choices={},label='Storage unavailable',totals={}}
        end
        return {guild=guild,choices={'camp-1'},totals={Stone=50},label='Base 1 of 1',
            epoch=s.net.epoch,verified=true,scope='camp',camp='camp-1',expires_at=s.now+30}
    end
    s.net.server_item_limits=false
    s.caps.remote={['guild-local']={Mining={Stone=100}}} -- the server's rules, as a client holds them
    local function listing()
        s.timers["storage transport"].fn()
        s.console={}; s.commands.limit('')
        return table.concat(s.console,'\n')
    end
    -- Panel closed: no count can come, and the listing says how to get one
    -- (round 3: it said "unavailable" and never why).
    s.panel.open=false
    local output=listing()
    assert(output:find("open the panel (Alt+F1) to see the server's counts",1,true),output)
    assert(not output:find('unavailable',1,true) and not output:find('50 /',1,true),output)
    -- Panel open, reply not back yet: asked, and says it is waiting.
    s.panel.open=true
    output=listing()
    assert(requested==1,'the client never asked the server for stock: '..output)
    assert(output:find("waiting for the server's count",1,true) and not output:find('unavailable',1,true),output)
    replied=true
    output=listing()
    assert(output:find('50 / 100',1,true) and not output:find('unavailable',1,true),output)
    assert(output:find('each limit can switch its entire work type',1,true),
        'the client used its own Mining setting instead of the server\'s: '..output)
end)

-- Round 3 (multiplayer P2-1, test-coverage P2-2): a real server and a real
-- client composition root, joined through their real transports. The client
-- runs its ClientRestart, role timers, 100 ms beats with net.poll and the
-- real stand grid; the server runs main.lua's own Hello handler and budget.
-- An ordinary join used to send three Hellos (the grid's ask before the role
-- was decided, poll, the 18 s announce) and the server refused the third with
-- "too many at once", so a reconnect within the minute was never served.
local function join_fixture()
    local server=boot(true); server.timers.role.fn()
    server.api.camps_available=true
    server.api.base_camps=function() return {{}} end
    server.api.camp_guild=function() return 'guild-A' end
    server.api.camp_pals=function() return {{key='PAL-A',param={}}} end
    server.api.suitability_rank=function() return 1 end
    local j={server=server, up={}, down={}, hellos={}, answered=0}
    -- The sender's guild, as the transmitter walk would prove it.
    server.net.guild_of_sender=function() return 'guild-A' end
    local on_command=server.net.on_command
    server.net.on_command=function(command,...)
        local before=server.net.revisions.R
        local result={on_command(command,...)}
        if command=='PWP_Hello' and server.net.revisions.R>before then j.answered=j.answered+1 end
        return table.unpack(result)
    end
    j.link={GetFullName=function() return 'BaseCampComponent of player 1' end,
        Notify_RequestClient_int32=function(_,_,msg) j.down[#j.down+1]={at=j.client.now+0.15,msg=msg} end}
    -- Booted second, so the shared clock and console are the client's.
    real_ui=true
    local ok,client=pcall(boot,false)
    real_ui=false
    assert(ok,client)
    j.client=client
    client.viewport=true
    function j.restart()
        client.hooks["/Script/Engine.PlayerController:ClientRestart"].before({get=function() return {} end})
    end
    function j.step()
        local c=client
        c.now=c.now+0.1
        server.now=c.now
        for _,m in ipairs(c.outgoing) do
            if m.name:sub(1,9)=='PWP_Hello' then j.hellos[#j.hellos+1]=c.now end
            j.up[#j.up+1]={at=c.now+0.15,name=m.name,value=m.value}
        end
        c.outgoing={}
        local keep={}
        for _,m in ipairs(j.up) do
            if m.at<=c.now then server.net.receive_command(j.link,m.name,m.value) else keep[#keep+1]=m end
        end
        j.up=keep
        local batch=j.down; j.down={}
        for _,m in ipairs(batch) do
            if m.at<=c.now then c.net.receive_state(m.msg) else j.down[#j.down+1]=m end
        end
        -- One-shots run when due; their delay counts from when they were set.
        for _,entry in ipairs(c.once) do
            entry.due=entry.due or c.now+entry.ms/1000
            if not entry.done and c.now>=entry.due-1e-9 then entry.done=true; entry.fn() end
        end
        c.timers["storage transport"].fn()
        if math.floor(c.now*10+0.5)%20==0 then c.timers.role.fn() end
        c:ui_beat()
    end
    function j.run(seconds) for _=1,math.floor(seconds*10+0.5) do j.step() end end
    function j.warned()
        return table.concat(client.console,"\n"):find("too many at once",1,true)~=nil
    end
    return j
end

test("a join sends one Hello and a reconnect within the minute is still served",function()
    local j=join_fixture()
    local c=j.client
    j.restart()
    j.run(1.5)
    assert(#j.hellos==0,'a Hello went up before the role was decided')
    j.run(4)
    assert(c.net.status=='ready','the join did not connect: '..tostring(c.net.status)..' '
        ..tostring(c.net.status_reason))
    assert(c.net.pals['PAL-A'],'the stand data did not arrive')
    j.run(50)
    assert(#j.hellos==1 and j.answered==1,'an ordinary join sent '..#j.hellos..' Hellos')
    assert(not j.warned(),'an ordinary join was refused as too many announcements')
    -- Reconnect (or a respawn that resets) 40 s after the join: a new nonce.
    j.restart()
    assert(c.net.status=='connecting')
    j.run(6)
    assert(c.net.status=='ready','a reconnect within the minute was not served: '
        ..tostring(c.net.status_reason))
    assert(j.answered==2 and not j.warned())
    j.run(30)
    assert(#j.hellos==2,'the reconnect sent '..(#j.hellos-1)..' Hellos')
end)

test("a join whose network component resolves late connects without a handshake timeout",function()
    local j=join_fixture()
    local c=j.client
    local resolved=c.api.owned_network_component
    local late=c.now+25
    c.api.owned_network_component=function() if c.now>=late then return resolved() end end
    j.restart()
    local timed_out=false
    for _=1,320 do
        j.step()
        if c.net.status_reason=='handshake_timeout' then timed_out=true end
    end
    assert(not timed_out,'a component still resolving was taken for a server without the mod')
    assert(c.net.status=='ready','the late join did not connect: '..tostring(c.net.status_reason))
    assert(#j.hellos==1 and j.answered==1 and not j.warned())
end)

test("hello budget: a new client nonce is served, a loop is refused with one warning",function()
    local s=boot(true); s.timers.role.fn()
    local may_announce=upvalue(s.net.on_command,'may_announce')
    local comp={GetFullName=function() return 'component-1' end}
    local function hello(nonce)
        s.net.clients['component-1']={client=nonce}
        return may_announce(comp)
    end
    assert(hello('a') and hello('a') and hello('a'),'one client nonce could not ask three times')
    assert(not hello('a'),'one client nonce asked a fourth time in a minute')
    assert(hello('b'),'a reconnect with a new nonce was refused')
    assert(not hello('c'),'new nonces were not capped')
    local said=table.concat(s.console,"\n")
    local _,warnings=said:gsub("too many at once","")
    assert(warnings==1,'the refusal was logged '..warnings..' times')
    s.now=s.now+61
    assert(hello('c'),'the window never reset')
    -- Players who stopped sending are forgotten, not kept for the session.
    local budget=upvalue(may_announce,'hello_budget')
    budget['gone']={at=s.now-61,n=1,nonces={}}
    assert(hello('c'))
    assert(budget['gone']==nil,'an expired budget was kept')
    local may_change=upvalue(s.net.on_command,'may_change')
    local rules=upvalue(may_change,'rule_budget')
    rules['gone']={at=s.now-11,n=3}
    may_change(comp)
    assert(rules['gone']==nil,'an expired rule budget was kept')
end)

test("ten limit changes in ten seconds; the eleventh is refused with a reason the panel shows",function()
    local s=boot(true); s.timers.role.fn()
    s.api.my_guild=function() return 'guild-local' end
    s.net.guild_of_sender=function() return 'guild-local' end
    local peer={server=s.net.local_nonce,client='client-1',guild='guild-local',
        acks={},order={},high=0,revisions={P=1,R=1},next_revision={P=1,R=1}}
    s.net.clients['component-1']=peer
    local comp={GetFullName=function() return 'component-1' end}
    local acks={}
    s.net.to_client=function(_,msg)
        local p=require('protocol').parts(msg)
        if p[2]=='A' then acks[#acks+1]={id=tonumber(p[6]),outcome=p[7],reason=p[8]} end
        return true
    end
    s.net.push_rules=function() return true end
    local wire=require('protocol')
    for i=1,11 do
        s.now=s.now+0.5
        local msg=wire.envelope('Q',peer.server,peer.client,peer.guild)..'|'..i..'|Set|Mining|Stone|'..(100+i)
        s.net.receive_command(comp,msg,0)
    end
    assert(#acks==11,'not every change was answered: '..#acks)
    for i=1,10 do assert(acks[i].outcome=='1','change '..i..' was refused') end
    assert(acks[11].outcome=='0' and acks[11].reason=='rate_limited',
        'the eleventh change was not refused as too many: '..tostring(acks[11].reason))
    assert(s.caps.all({},'guild-local').Mining.Stone==110,'the refused change was applied')
    -- What the client's panel says for it.
    local text=require('panel_status').plain_reason('rate_limited')
    assert(text:find('not applied',1,true) and not text:find('_',1,true),text)
    s.now=s.now+11
    local msg=wire.envelope('Q',peer.server,peer.client,peer.guild)..'|12|Set|Mining|Stone|120'
    s.net.receive_command(comp,msg,0)
    assert(acks[12].outcome=='1','the budget never refilled')
end)

test("the old-client notice names this build's version",function()
    local s=boot(true)
    local version=main_source:match('local%s+VERSION%s*=%s*"([^"]+)"')
    assert(version and s.net.OLD_CLIENT_NOTICE:find('('..version..')',1,true),s.net.OLD_CLIENT_NOTICE)
end)

io.open,io.popen=original_io.open,original_io.popen
os.rename,os.remove,os.execute,os.clock,os.time=original_os.rename,original_os.remove,original_os.execute,original_os.clock,original_os.time
for _,name in ipairs(native_names) do _G[name]=original_native[name] end
assert(#failures==0,table.concat(failures,"\n\n"))
