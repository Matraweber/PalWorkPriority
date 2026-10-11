local Adapter=dofile(TEST_ROOT..'/experiments/settings_startup_authority.lua')
local Pair=dofile(TEST_ROOT..'/experiments/save_context_pair_probe.lua')
local Authority=dofile(TEST_ROOT..'/experiments/save_local_authority.lua')
local W,G=string.rep('a',32),'ffffffff000000020000000300000004'
local cases=0
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
local function fixture(edit)
    local f={epoch=1,token=function()end,calls=0}
    f.context={scope='PWP-SCOPE-1:'..W..':'..G..':limits',storage=W,guild=G,stream='limits',
        session='boot',incarnation='inc',epoch=1,camp='camp',authority=true}
    f.alias='-1-2-3-4'
    f.p={status='context_agrees',agrees=true,world='World test',directory=W,role=3,dedicated=false,
        world_address=1,state_address=3,instance_address=2,manager_address=4,
        identity_loaded_status='read',identity_loaded_world=true,identity_selected_status='format_valid',
        identity_selected=W,identity_autosave_status='empty'}
    f.a={authority_status='read',authority=true,guild_status='format_valid',guild=G,
        legacy_guild=f.alias,world_address=1,state_address=3,instance_address=2}
    f.o={enabled=true,context=copy(f.context),runtime_guild=f.alias,
        get_epoch=function() f.calls=f.calls+1;return {available=true,supported=true,epoch=f.epoch,token=f.token} end,
        read_evidence=function() f.calls=f.calls+1;return f.p end,
        read_authority=function() f.calls=f.calls+1;return f.a end}
    if edit then edit(f) end
    f.adapter=assert(Adapter.new(f.o))
    function f:check() return self.adapter.authorize(copy(self.context),self.alias) end
    function f:denied()
        assert(not self:check());assert(self.adapter.status().state=='revoked')
        local n=self.calls;assert(not self:check() and self.calls==n);cases=cases+1
    end
    return f
end
assert(Adapter.new()==nil and Adapter.new{}==nil and Adapter.new{enabled='true'}==nil)
do
    local f=fixture();assert(f.calls==0 and f.adapter.status().state=='idle')
    assert(f:check() and f:check() and f.calls==16)
    f.o.context.storage='mutated';f.o.runtime_guild='mutated'
    f.o.read_authority=function()error('replaced provider')end
    assert(f:check());local s=f.adapter.status();s.state='revoked';assert(f:check())
    f.adapter.revoke();f:denied()
end
do local f=fixture(function(x)x.alias=G;x.o.runtime_guild=G end);assert(f:check());cases=cases+1 end
for _,alias in ipairs({'1-2-3-4','-01-2-3-4','-2147483649-2-3-4','4294967296-2-3-4','guild'}) do
    local f=fixture(function(x)x.alias=alias;x.a.legacy_guild=alias;x.o.runtime_guild=alias end)
    f:denied()
end
for _,key in ipairs({'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'}) do
    local f=fixture();f.context[key]=nil;f:denied()
    local g=fixture();g.o.context[key]=nil;assert(not Adapter.new(g.o));cases=cases+1
end
for _,key in ipairs({'get_epoch','read_evidence','read_authority'}) do
    local f=fixture();f.o[key]=nil;assert(not Adapter.new(f.o));cases=cases+1
end
for _,edit in ipairs({
    function(f)f.p.status='observed'end,function(f)f.p.agrees=false end,
    function(f)f.p.role=nil end,function(f)f.p.role=2 end,function(f)f.p.dedicated=true end,
    function(f)f.p.identity_loaded_status='unavailable'end,function(f)f.p.identity_loaded_world=false end,
    function(f)f.p.identity_selected_status='empty'end,function(f)f.p.identity_selected=string.rep('b',32)end,
    function(f)f.p.directory=string.rep('b',32)end,
    function(f)f.p.identity_autosave_status='unknown'end,
    function(f)f.p.identity_autosave=W end,
    function(f)f.p.identity_autosave_status='format_valid';f.p.identity_autosave=string.rep('b',32)end,
    function(f)f.p.world=''end,function(f)f.p.world='bad\nname'end,
    function(f)f.a.authority=false end,function(f)f.a.authority_status='unknown'end,
    function(f)f.a.guild_status='unknown'end,function(f)f.a.guild=string.rep('b',32)end,
    function(f)f.a.legacy_guild=nil end,function(f)f.a.legacy_guild='4294967295-2-3-4'end,
    function(f)f.alias='alias'end,function(f)f.a.state_address=99 end,
    function(f)setmetatable(f.p,{})end,function(f)setmetatable(f.a,{})end,
    function(f)f.epoch=2 end,function(f)f.token={}end,
}) do
    local f=fixture();edit(f);f:denied()
end
for _,key in ipairs({'world_address','state_address','instance_address','manager_address'}) do
    for _,bad in ipairs({0,-1,1.5,'1',{},false}) do
        local f=fixture();f.p[key]=bad;f:denied()
    end
    local f=fixture();assert(f:check());f.p[key]=99;f.a[key]=99;f:denied()
end
for _,edit in ipairs({
    function(f)f.epoch=2 end,function(f)f.token=function()end end,
    function(f)f.p.world='same storage, different world'end,
    function(f)f.a.authority=false end,function(f)f.p.identity_loaded_world=false end,
    function(f)f.p.identity_selected=string.rep('c',32)end,
    function(f)f.p.identity_autosave_status='format_valid';f.p.identity_autosave=W end,
}) do
    local f=fixture();assert(f:check());edit(f);f:denied()
end
-- Lost authority and epoch transitions never revive, even after evidence restores.
do local f=fixture();assert(f:check());f.a.authority=false;f:denied();f.a.authority=true;f:denied() end
do local f=fixture();assert(f:check());f.epoch=2;f:denied();f.epoch=1;f:denied() end
-- Every provider boundary: throw, nested authorize, explicit lifecycle invalidation.
for _,key in ipairs({'get_epoch','read_evidence','read_authority'}) do
    for _,mode in ipairs({'throw','reenter','revoke'}) do
        local f=fixture(function(x)
            local old=x.o[key]
            x.o[key]=function(...)
                if mode=='throw' then error('provider failed') end
                if mode=='reenter' then assert(not x:check()) else x.adapter.revoke() end
                return old(...)
            end
        end)
        f:denied()
    end
end
-- Returned tables, disposable authority arguments and caller context cannot
-- mutate the private copy into authorizing a different storage or incarnation.
for _,edit in ipairs({
    function(f,c)c.world_address=99 end,
    function(f)f.p.manager_address=99 end,
    function(f)f.p.identity_selected=string.rep('b',32)end,
    function(f)f.epoch=2 end,function(f)f.token=function()end end,
}) do
    local f=fixture(function(x)
        x.o.read_authority=function(c)edit(x,c);return x.a end
    end);f:denied()
end
do
    local context
    local f=fixture(function(x)x.o.read_authority=function()context.camp='other';return x.a end end)
    context=copy(f.context);assert(not f.adapter.authorize(context,f.alias));f:denied()
end
-- A shared epoch result is copied before subsequent callbacks can mutate it.
for boundary=1,4 do
    for _,mode in ipairs({'epoch','token','supported','available'}) do
        local f=fixture(function(x)
            local n=0
            x.o.get_epoch=function()
                n=n+1
                local e={available=true,supported=true,epoch=x.epoch,token=x.token}
                if n==boundary then
                    if mode=='epoch' then e.epoch=2
                    elseif mode=='token' then e.token=function()end
                    else e[mode]=false end
                end
                return e
            end
        end);f:denied()
    end
end
do
    local f=fixture(function(x)
        local e={available=true,supported=true,epoch=1,token=x.token}
        x.o.get_epoch=function()return e end
        x.o.read_authority=function()e.token=function()end;return x.a end
    end);f:denied()
end
-- No late callback may turn earlier authority into an unchecked stale grant.
do
    local f=fixture(function(x)
        local n=0
        x.o.get_epoch=function()
            n=n+1;if n==2 then x.a.authority=false end
            return {available=true,supported=true,epoch=1,token=x.token}
        end
    end);f:denied()
end
-- Real Pair.read + LocalAuthority.read, using disposable engine wrappers each
-- callback. Weak references prove the adapter retains no returned wrapper extras.
do
    local weak=setmetatable({}, {__mode='k'})
    local function engine()
        local function object(t,n)
            t.IsValid=function()return true end;t.GetAddress=function()return n end
            weak[t]=true;return t
        end
        local instance=object({SelectedWorldSaveDirectoryName=W},2)
        local state=object({WorldSaveDirectoryName=W,Role=3,bIsDedicatedServer=false},3)
        local world=object({GameState=state,OwningGameInstance=instance,GetFullName=function()return 'World test'end},1)
        local level=object({OwningWorld=world},5);state.GetLevel=function()return level end
        instance.SaveGameManager=object({AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=true,
            GetOuter=function()return instance end},4)
        local guild=object({Id={A=-1,B=2,C=3,D=4}},8)
        local ps=object({GuildBelongTo=guild,GetLevel=function()return level end},7)
        local pc=object({Role=3,PlayerState=ps,GetLevel=function()return level end},6)
        instance.LocalPlayers={object({PlayerController=pc},9)}
        return object({GameInstance=instance,GameViewport=object({World=world},10)},11)
    end
    local f=fixture(function(x)
        x.o.read_evidence=function()
            local e=engine()
            local p=Pair.read(e,function()return e.GameViewport.World.GameState end,function()return e.GameInstance end)
            p.extra=e;return p
        end
        x.o.read_authority=function(c)
            local e=engine();local a=Authority.read(e,c);a.extra=e;return a
        end
    end)
    local extra={};weak[extra]=true;f.o.context.extra=extra;extra=nil
    assert(f:check() and f:check());f.o=nil
    collectgarbage('collect');collectgarbage('collect');assert(next(weak)==nil)
    assert(f:check());cases=cases+1
end
-- Priority startup needs the same fresh local scope proof, without allowing a
-- grant for one stream to be reused by another stream or a typo destination.
do
    local f=fixture(function(x)
        x.context.stream='priorities'
        x.context.scope='PWP-SCOPE-1:'..W..':'..G..':priorities'
        x.o.context=copy(x.context)
    end)
    assert(f:check());f.context.stream='limits';f:denied()
    local g=fixture();g.o.context.stream='priorities'
    assert(not Adapter.new(g.o)) -- scope suffix still limits
    g.o.context.stream='unknown';assert(not Adapter.new(g.o))
    cases=cases+1
end
-- Default provider arity is unchanged; explicit contexts are per authorization,
-- cleared even when a provider retains the table to inspect its tombstone.
for _,enabled in ipairs({false,true})do
    local contexts={}
    local f=fixture(function(x)
        x.o.operation_context=enabled
        x.o.read_evidence=function(...)
            assert(select('#',...)==(enabled and 1 or 0))
            local op=...
            if enabled then
                assert(not op.closed)
                contexts[#contexts+1]=op
                op.cdo=op.cdo or {};op.extra=op.cdo
            end
            return copy(x.p)
        end
    end)
    assert(f:check() and f:check())
    if enabled then
        assert(contexts[1]==contexts[2] and contexts[3]==contexts[4] and contexts[1]~=contexts[3])
        for _,op in ipairs(contexts)do assert(op.closed==true and next(op,'closed')==nil)end
    end
    cases=cases+1
end
for _,mode in ipairs({'throw','reenter','revoke','epoch','guild','world','state','instance','manager','loaded'})do
    local held,reads
    reads=0
    local f=fixture(function(x)
        x.o.operation_context=true
        x.o.read_evidence=function(op)
            reads=reads+1;held=op;op.cdo={};op.extra=op.cdo
            if reads==2 then
                if mode=='throw'then error('provider fixture failure')
                elseif mode=='reenter'then
                    assert(not x:check());assert(op.closed and not op.cdo and not op.extra)
                    op.extra={} -- outer unwind must clear even a misbehaving retained provider
                elseif mode=='revoke'then
                    x.adapter.revoke();assert(op.closed and not op.cdo and not op.extra)
                elseif mode=='epoch'then x.epoch=2
                elseif mode=='guild'then x.a.guild=string.rep('b',32)
                elseif mode=='world'then x.p.world='different world'
                elseif mode=='loaded'then x.p.identity_loaded_world=false
                else x.p[mode..'_address']=999 end
            end
            return copy(x.p)
        end
    end)
    f:denied();assert(reads==2 and held.closed and not held.cdo and not held.extra)
end
print('settings startup authority: '..cases..' cases; real readers, scoped evidence cleanup, mutation/reentry/transition/stale-storage rejection')
