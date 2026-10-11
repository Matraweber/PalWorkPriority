local Sidecar=dofile(TEST_ROOT..'/experiments/settings_startup_lifecycle.lua')
local names={'RegisterLoadMapPreHook','RegisterLoadMapPostHook',
    'RegisterInitGameStatePreHook','RegisterInitGameStatePostHook','RegisterEndPlayPreHook'}
local cases=0
local function fixture(edit)
    local f={hooks={},registrations=0,order={},reports=0,api={},revokes=0,retires=0,drains=0}
    local o={enabled=true,report=function(s)
        f.reports=f.reports+1
        assert(not f.side:epoch().available)
        for _,v in pairs(s) do assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean') end
        if s.event=='cleanup_complete' then
            assert(f.stopped and s.cleanup_attempted and f.reports==2)
            f.order[#f.order+1]='cleanup_complete';f.completion=s
            local current=f.side:status()
            for _,k in ipairs({'cleanup_verified','owner_retained','uncertain','state'}) do assert(s[k]==current[k]) end
            if f.on_complete then return f.on_complete(s) end
            return
        end
        assert(s.event=='closing' and f.revokes==0 and f.retires==0 and f.drains==0)
        f.stopped=true;f.order[#f.order+1]='closing'
        if f.on_report then return f.on_report(s) end
    end}
    for _,name in ipairs(names) do
        f.api[name]=function(cb)f.registrations=f.registrations+1;f.hooks[name]=cb end
    end
    f.authority={revoke=function(...)
        assert(select('#',...)==0 and f.stopped);assert(not f.side:epoch().available)
        f.revokes=f.revokes+1;f.order[#f.order+1]='revoke';f.revoked=true
        if f.on_revoke then return f.on_revoke() end
        return false,'revoked' -- actual authority adapter's convention
    end,status=function(...)
        assert(select('#',...)==0)
        if f.on_authority_status then return f.on_authority_status() end
        return {state=f.revoked and 'revoked' or 'bound'}
    end}
    f.startup={retire=function(self)
        assert(self==f.startup and f.revokes==1 and not f.side:epoch().available)
        f.retires=f.retires+1;f.order[#f.order+1]='retire'
        if f.on_retire then return f.on_retire() end
        return false,'retired'
    end,drain=function(self)
        assert(self==f.startup and f.retires==1 and not f.side:epoch().available)
        f.drains=f.drains+1;f.order[#f.order+1]='drain'
        if f.on_drain then return f.on_drain() end
        f.closed=true;return true
    end,status=function()
        if f.on_startup_status then return f.on_startup_status() end
        return {state=f.closed and 'closed' or 'retiring',owner_retained=not f.closed}
    end}
    if edit then edit(f,o) end
    f.side=assert(Sidecar.new(o))
    function f:event(i,...)
        local out=table.pack(assert(self.hooks[names[i]])(...))
        assert(out.n==1 and out[1]==nil,'observer hooks must explicitly return nil')
    end
    function f:quit(n)self:event(5,{}, {get=function()return n end})end
    function f:init()self:event(3);self:event(4)end
    function f:ready()
        assert(self.side:install(self.api));self:init()
        assert(not self.side:epoch().available)
        assert(self.side:admit(function(e)
            assert(e==self.side:status().epoch and not self.side:epoch().available);return true
        end))
        local e=self.side:epoch();assert(e.available and e.supported and type(e.token)=='function' and e.token()==e.epoch)
        assert(self.side:attach(self.startup,self.authority));return e
    end
    function f:once(retained)
        local s=self.side:status()
        assert(table.concat(self.order,',')=='closing,revoke,retire,drain,cleanup_complete')
        assert(self.revokes==1 and self.retires==1 and self.drains==1 and self.reports==2)
        assert(s.terminal and s.owner_retained==retained and s.cleanup_verified==not retained)
        assert(not self.side:epoch().available and not self.side:epoch().supported)
        self.side:close('duplicate');self:quit(4)
        assert(self.revokes==1 and self.retires==1 and self.drains==1 and self.reports==2)
        cases=cases+1
    end
    return f
end
assert(not Sidecar.new() and not Sidecar.new{} and not Sidecar.new{enabled='true'})
assert(not Sidecar.new{enabled=true,report={}})
do
    local f=fixture();assert(f.registrations==0 and f.side:status().state=='uninstalled')
    local e=f.side:epoch();assert(not e.available and not e.supported and e.epoch==0 and e.token==nil)
    f:ready();assert(not f.side:install(f.api) and f.registrations==5)
    assert(f.side:admit(function()error('already admitted must not reverify')end))
    local before=f.side:epoch();local copy=f.side:status();copy.epoch=900;copy.terminal=true
    assert(f.side:epoch().token==before.token)
    local exposed=f.side:epoch();exposed.token=function()end;exposed.epoch=99;exposed.available=false
    assert(f.side:epoch().token==before.token and f.side:epoch().epoch==before.epoch)
    for reason=0,3 do f:quit(reason);assert(f.side:epoch().available and f.revokes==0) end
    f:quit(4);f:once(false)
    assert(f.completion.reason=='quit' and f.completion.state=='closed'
        and f.completion.cleanup_verified and not f.completion.owner_retained and not f.completion.uncertain
        and f.completion.drain_attempted)
    -- Duplicate Quit must not inspect another callback-local wrapper.
    f:event(5,{}, {get=function()error('duplicate read')end})
    assert(not f.side:admit(function()error('rearm')end))
end
for _,event in ipairs({1,3,2,4}) do
    local f=fixture();local old=f:ready();f:event(event)
    assert(f.side:epoch().epoch>old.epoch);f:once(false)
    f:init();assert(not f.side:epoch().available)
end
-- Initial transitions are evidence for admission, not premature shutdown.
do
    local f=fixture();assert(f.side:install(f.api));f:event(1);f:init();f:event(2)
    assert(f.side:admit(function()return true end));assert(f.side:attach(f.startup,f.authority))
    assert(f.side:close('ClientRestart'));f:once(false)
end
-- Only one owner; never call cleanup on a proposed replacement.
do
    local f=fixture();f:ready()
    local replacement={retire=function()error('replacement touched')end}
    assert(not f.side:attach(replacement,{}));f:once(false)
end
-- Close before attachment permanently rejects it; no late owner is captured.
for _,stage in ipairs({'new','installed','admitted'}) do
    local f=fixture()
    if stage~='new' then assert(f.side:install(f.api)) end
    if stage=='admitted' then f:init();assert(f.side:admit(function()return true end)) end
    assert(f.side:close('ClientRestart'));assert(not f.side:attach(f.startup,f.authority))
    assert(not f.side:install(f.api) and f.revokes==0 and f.drains==0 and f.reports==2);cases=cases+1
end
for _,name in ipairs(names) do
    local f=fixture();f.api[name]=nil
    assert(not f.side:install(f.api) and f.registrations==0 and f.side:status().terminal)
    assert(not f.side:install({}) and not f.side:epoch().available);cases=cases+1
end
-- Registration may retain a hook and then throw/return false/invoke it early.
for _,name in ipairs(names) do
    for _,mode in ipairs({'throw','false','early'}) do
        local f=fixture(function(x)
            x.api[name]=function(cb)
                x.registrations=x.registrations+1;x.hooks[name]=cb
                if mode=='throw' then error('lost registration reply') end
                if mode=='false' then return false end
                assert(cb()==nil)
            end
        end)
        assert(not f.side:install(f.api));assert(f.side:status().terminal)
        for _,cb in pairs(f.hooks) do assert(cb()==nil) end
        assert(not f.side:admit(function()error('unregistered')end));cases=cases+1
    end
end
for _,mode in ipairs({'uninstalled','late','missing','false','nil','truthy','throw','transition','reentrant','close','quit'}) do
    local f=fixture()
    if mode~='uninstalled' then assert(f.side:install(f.api)) end
    if mode~='uninstalled' and mode~='late' then f:init() end
    local verify=mode~='missing' and function()
        if mode=='throw' then error('proof lost') end
        if mode=='false' then return false end
        if mode=='nil' then return nil end
        if mode=='truthy' then return 1 end
        if mode=='transition' then f:init() end
        if mode=='reentrant' then assert(not f.side:admit(function()return true end)) end
        if mode=='close' then
            f.side:close('ClientRestart')
            assert(f.stopped and f.reports==1,'closing must signal before verifier resumes')
        end
        if mode=='quit' then f:quit(4) end
        return true
    end or nil
    assert(not f.side:admit(verify));assert(not f.side:epoch().available and f.side:status().terminal)
    assert(not f.side:attach(f.startup,f.authority));cases=cases+1
end
for _,value in ipairs({-1,5,1.5,4.0,'4',false,{},0/0,math.huge}) do
    local f=fixture();f:ready();f:quit(value);f:once(false)
    assert(f.side:status().reason=='invalid_endplay_reason')
end
do local f=fixture();f:ready();f:event(5,{}, {get=function()error('reason lost')end});f:once(false) end
do local f=fixture();f:ready();f:event(5,{},nil);f:once(false) end
-- Reentry while extracting the callback-local enum cannot resume authorization.
for _,method in ipairs({'install','admit','attach','close'}) do
    local f=fixture();f:ready()
    f:event(5,{}, {get=function()
        if method=='install' then assert(not f.side:install(f.api))
        elseif method=='admit' then assert(not f.side:admit(function()return true end))
        elseif method=='attach' then assert(not f.side:attach(f.startup,f.authority))
        else assert(not f.side:close('ClientRestart')) end
        return 0
    end})
    f:once(true)
end
do
    local f=fixture();assert(f.side:install(f.api));f:init()
    assert(not f.side:admit(function()
        assert(not f.side:attach(f.startup,f.authority));return true
    end))
    assert(f.revokes==0 and f.drains==0 and not f.side:status().owner_retained);cases=cases+1
end
-- Any uncertain cleanup step retains original references; drain is not retried.
for _,step in ipairs({'on_revoke','on_retire','on_drain','on_authority_status','on_startup_status','on_report'}) do
    for _,mode in ipairs({'throw','nil','wrong','reentrant'}) do
        local f=fixture();f:ready()
        f[step]=function()
            if mode=='throw' then error('lost result') end
            if mode=='nil' then return nil end
            if mode=='reentrant' then f.side:close('nested');return true end
            if step=='on_report' then return false end
            return 'wrong'
        end
        -- report may normally return nil, like the pinned logging adapters.
        f:quit(4);f:once(not (step=='on_report' and mode=='nil'))
    end
end
do local f=fixture();f:ready();f.on_drain=function()return false end;f:quit(4);f:once(true) end
-- Completion records cover failed drains; no positive cleanup claim is emitted.
do
    local f=fixture();f:ready();f.on_drain=function()error('lost drain')end
    f:quit(4);f:once(true)
    assert(f.completion.state=='retained' and not f.completion.cleanup_verified
        and f.completion.owner_retained and f.completion.uncertain)
end
-- A sink may record success and then lose its reply. Roll back reference release
-- without replaying any cleanup callback or either report, even on later hooks.
for _,mode in ipairs({'throw','false','reentrant','mutation'}) do
    local f=fixture();f:ready()
    f.on_complete=function(s)
        assert(f.drains==1 and s.state=='closed' and s.cleanup_verified and not s.owner_retained)
        if mode=='throw' then error('completion recorded; reply lost') end
        if mode=='false' then return false end
        if mode=='reentrant' then assert(not f.side:close('nested'));return true end
        s.state='retained';s.cleanup_verified=false;s.owner_retained=true;s.uncertain=true
    end
    f:quit(4);f:once(mode~='mutation')
    f:event(1);f:event(3);f:quit(4)
    assert(f.reports==2 and f.drains==1)
    assert(f.side:status().uncertain==(mode~='mutation'))
end
do
    local f=fixture();f:ready();f.on_drain=function()return true end -- no verified closed state
    f:quit(4);f:once(true)
end
-- Captured functions cannot be redirected by later writes to the API tables.
do
    local f=fixture();f:ready()
    f.startup.drain=function()error('replaced')end;f.authority.revoke=function()error('replaced')end
    f:quit(4);f:once(false)
end
-- Actor/reason wrappers are neither inspected beyond reason:get nor retained.
do
    local f=fixture();f:ready();local weak=setmetatable({}, {__mode='v'})
    do
        local actor=setmetatable({}, {__index=function()error('actor inspection')end})
        local param={get=function()return 4 end};weak[1]=actor;weak[2]=param
        f:event(5,actor,param)
    end
    collectgarbage('collect');assert(weak[1]==nil and weak[2]==nil);f:once(false)
end
-- Retain the exact owner on uncertain cleanup, release only verified cleanup.
for _,mode in ipairs({'success','drain_failed','report_lost'}) do
    local success=mode=='success'
    local reports=0
    local side=assert(Sidecar.new{enabled=true,report=function(s)
        reports=reports+1
        if mode=='report_lost' and s.event=='cleanup_complete' then error('lost completion') end
    end});local hooks,api={},{}
    for _,name in ipairs(names) do api[name]=function(cb)hooks[name]=cb end end
    assert(side:install(api));hooks[names[3]]();hooks[names[4]]()
    assert(side:admit(function()return true end))
    local weak=setmetatable({}, {__mode='v'})
    do
        local owner={retire=function()return false end,drain=function()return mode~='drain_failed' end,
            status=function()return {state='closed',owner_retained=false}end}
        local auth={revoke=function()return false end,status=function()return {state='revoked'}end}
        weak[1],weak[2]=owner,auth;assert(side:attach(owner,auth))
    end
    side:close('ClientRestart');collectgarbage('collect');collectgarbage('collect')
    assert(side:status().owner_retained==not success)
    assert((weak[1]==nil)==success and (weak[2]==nil)==success);cases=cases+1
    side:close('duplicate');assert(reports==2)
end
print('settings startup lifecycle: '..cases..' cases; actual epoch controller, ordered single-owner cleanup, fail-closed hooks and no drain replay')
