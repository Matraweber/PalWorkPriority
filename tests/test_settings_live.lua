-- Bootstrap orchestration in the same Lua state, with actual gate/lifecycle.
-- Native IO/proof/parser factories are replaced here; their actual compositions
-- are covered by test_settings_startup, startup_authority and native entry tests.
local real_dofile,real_loadlib=dofile,package.loadlib
local W,G=string.rep('3',32),string.rep('4',32)
local function fixture(fault)
    package.loaded.settings_gate=nil
    local gate=require('settings_gate')
    local f={events={},scheduled={},hooks={},calls={},fault=fault}
    local function count(k)f.calls[k]=(f.calls[k] or 0)+1 end
    package.loaded.caps={decided=true,is_client=false,session=1,state='saved',serialize=function()return 'limits' end}
    package.loaded.store={decided=true,is_client=false,serialize=function()return 'priorities'end}
    package.loaded.session={epoch=1}
    package.loaded.log={say=function(s)f.events[#f.events+1]=s end}
    package.loaded.UEHelpers={GetEngine=function()return {}end,GetGameplayStatics=function()
        return {IsValid=function()return true end}end}
    for _,name in ipairs({'RegisterLoadMapPreHook','RegisterLoadMapPostHook','RegisterInitGameStatePreHook',
        'RegisterInitGameStatePostHook','RegisterEndPlayPreHook'})do
        _G[name]=function(callback)f.hooks[name]=callback end
    end
    ExecuteInGameThreadWithDelay=function(delay,callback)
        f.scheduled[#f.scheduled+1]=callback
        if fault=='schedule' then return false end
    end
    local replacements={
        ['save_context_pair_probe.lua']={read=function()return {status='context_agrees',directory=fault=='wrong_world' and G or W}end},
        ['save_local_authority.lua']={read=function()return {authority_status='read',authority=true,guild=G,legacy_guild=G}end},
        ['settings_startup_files.lua']={new=function()return {read_source=function()end,read_backup=function()end,verify_receipt=function()end}end},
        ['settings_migration_guard.lua']={new=function(o)
            assert(gate.blocked());f.migration=o
            return {body=function()return 'body'end,verify=function()return true end}
        end},
        ['settings_startup_authority.lua']={new=function(o)
            local revoked=false
            return {authorize=function()
                count('authorize');assert(o.get_epoch().available)
                return not revoked
            end,revoke=function()count('revoke');revoked=true;return false end,
            status=function()return {state=revoked and 'revoked' or 'bound'}end}
        end},
        ['save_draining_backend.lua']={new=function(o)
            if fault=='backend_constructor' then error('constructor failed')end
            f.backend=o
            return {inspect=function()return {generation=1,committed=1}end}
        end},
        ['settings_dormant_cleanup.lua']={new=function()return {drain=function()count('dormant_drain');return true end}end},
        ['save_native_backend.lua']={call=function(_,command)
            count('native_'..command)
            assert(gate.blocked())
            if fault=='bind' and command==1 then error('lost binding reply')end
            return {1,'1',123,0,1,1000}
        end,unpack=function(s)return {s}end},
        ['settings_startup.lua']={new=function(o)
            assert(gate.blocked());f.options=o
            local token,state,queue_owned
            return {start=function()
                count('start');assert(not gate.blocked())
                if fault=='start' then state='retiring';return false end
                queue_owned=true;token=assert(gate.acquire());state='recovering';return true
            end,poll=function()
                count('poll')
                if fault=='poll' then error('poll failure')end
                if state=='recovering' then assert(gate.release(token));state='active'end
                return true
            end,status=function()return {state=state,queue_owned=queue_owned,initialization_attempted=true,owner_retained=state~='closed'}end,
            retire=function()count('retire');state='retiring';return false end,
            drain=function()count('drain');assert(gate.blocked());state='closed';return fault~='drain' end,
            fenced=function()return gate.held(token)end}
        end},
    }
    dofile=function(path)
        local name=path:match('([^/]+)$')
        return replacements[name] or real_dofile(path)
    end
    package.loadlib=function()return function()end end
    local live=real_dofile(TEST_ROOT..'/experiments/settings_live.lua')
    local ok,r=pcall(live.install,{enabled=true,receipt={},nonce='checked',storage=W,guild=G,runtime_guild=G,dll='checked'})
    f.runtime=ok and r or nil
    f.gate=gate
    if not ok then assert(fault=='schedule') end
    function f:step()
        local callback=table.remove(self.scheduled,1);assert(callback);callback()
    end
    function f:init()
        self.hooks.RegisterInitGameStatePreHook()
        self.hooks.RegisterInitGameStatePostHook()
    end
    return f
end
do
    local f=fixture();assert(f.gate.blocked());f.runtime.transition();assert(f.gate.blocked())
    f:init();f:step()
    assert(f.runtime.status().active and not f.gate.blocked() and f.calls.start==1)
    assert(f.calls.native_0==1 and f.calls.native_1==1)
    f:step();assert(f.calls.start==1)
    f.hooks.RegisterEndPlayPreHook(nil,{get=function()return 4 end})
    assert(f.gate.blocked() and f.runtime.status().stopped and f.calls.drain==1 and f.calls.revoke==1)
    f.hooks.RegisterEndPlayPreHook(nil,{get=function()error('must not reread')end})
    f:step();assert(f.calls.drain==1 and f.calls.poll==2)
end
for _,fault in ipairs({'wrong_world','bind','poll','drain','start','backend_constructor'})do
    local f=fixture(fault);f:init();f:step()
    if fault=='drain' then f.runtime.transition() end
    assert(f.runtime.status().stopped and f.gate.blocked())
    local n=f.calls.native_1
    f.runtime.transition();assert(f.calls.native_1==n and (f.calls.drain or 0)<=1)
    if fault=='start' or fault=='backend_constructor' then assert(f.calls.dormant_drain==1)end
    if fault=='bind' then
        assert(not f.calls.dormant_drain)
        assert(table.concat(f.events,'\n'):find('ownership_unknown=true',1,true))
    end
end
do
    local f=fixture();f:init();f:step()
    f.hooks.RegisterLoadMapPreHook()
    assert(f.gate.blocked() and f.calls.drain==1 and f.runtime.status().stopped)
end
do
    local f=fixture('schedule');assert(f.gate.blocked() and not f.runtime)
end
dofile,package.loadlib=real_dofile,real_loadlib
print('live bootstrap: same-VM fence, original-owner exit/transition, no native replay and failure fencing passed')
