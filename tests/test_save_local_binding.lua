local Binding=dofile(TEST_ROOT..'/experiments/save_local_binding.lua')
local Epoch=dofile(TEST_ROOT..'/experiments/save_lifecycle_epoch.lua')
local function fixture(extra)
    local f={calls=0,drops=0,epoch=1,token=function() end}
    f.p={status='context_agrees',agrees=true,world='MainWorld',directory=string.rep('a',32),
        role=3,dedicated=false,world_address=11,state_address=12,instance_address=13,manager_address=14,
        identity_loaded_status='read',identity_loaded_world=true,identity_selected_status='format_valid',
        identity_selected=string.rep('a',32),identity_autosave_status='empty'}
    f.a={authority_status='read',authority=true,guild_status='format_valid',guild=string.rep('b',32),
        world_address=11,state_address=12,instance_address=13}
    f.o={enabled=true,namespace='profile-1',boot='boot-unique',stream='priorities',rootcap=42,
        get_epoch=function() return {available=true,supported=true,epoch=f.epoch,token=f.token} end,
        read_evidence=function() return f.p end,read_authority=function() return f.a end,
        bind=function(cap,r) f.calls=f.calls+1;assert(cap==42);f.request=r;return 71 end,
        discard=function(id) assert(id==71);f.drops=f.drops+1;return true end}
    if extra then extra(f) end
    f.b=Binding.new(f.o)
    function f:grant() return self.b.bind(self.b.sample()) end
    return f
end
assert(Binding.new{}.sample().status=='unconfigured')
do local f=fixture();local c=f.b.sample();assert(c.status=='candidate' and c.binding==nil and f.calls==0)
    c.storage='malicious';f.o.rootcap=99;f.o.namespace='other'
    local g=f.b.bind(c);assert(g.authorized and g.binding==71 and f.request.worldguid==f.p.directory)
    assert(f.request.namespace=='profile-1' and f.request.epoch==1 and f.request.incarnation=='boot-unique:1')
    assert(f.b.check(71).authorized and not f.b.bind(c).authorized and f.calls==1)
    assert(not f.b.check(72).authorized);f.b.revoke();assert(f.drops==1 and not f.b.check(71).authorized)
    assert(not f.b.sample().authorized and f.b.sample().status~='candidate')
    f.epoch=2;f.token=function() end;assert(f.b.sample().status=='candidate')
end
for _,edit in ipairs({
    function(f) f.p.role=nil end,function(f) f.p.role=2 end,function(f) f.p.dedicated=true end,
    function(f) f.p.dedicated=nil end,function(f) f.p.agrees=false end,
    function(f) f.p.identity_loaded_world=false end,function(f) f.p.identity_loaded_status='unavailable' end,
    function(f) f.p.identity_selected=nil end,function(f) f.p.directory=string.rep('0',32) end,
    function(f) f.p.identity_selected=string.rep('c',32) end,
    function(f) f.p.identity_autosave_status='read_failed' end,
    function(f) f.p.identity_autosave_status='format_valid';f.p.identity_autosave=string.rep('c',32) end,
    function(f) f.p.manager_address=nil end,function(f) f.p.world_address=0 end,
    function(f) f.a.authority=false end,function(f) f.a.authority_status='unknown' end,
    function(f) f.a.guild=nil end,function(f) f.a.guild_status='unknown' end,
    function(f) f.a.state_address=99 end,function(f) setmetatable(f.p,{}) end,
    function(f) f.o.get_epoch=function() return nil end end,
    function(f) f.o.get_epoch=function() return {available=true,supported=false,epoch=1,token=f.token} end end,
}) do local f=fixture(edit);assert(not f:grant().authorized and f.calls==0) end
for _,edit in ipairs({
    function(f) f.epoch=2 end,function(f) f.epoch=0 end,function(f) f.token=function() end end,
    function(f) f.p.manager_address=99 end,function(f) f.a.guild=string.rep('c',32) end,
    function(f) f.p.world='Other' end,
}) do local f=fixture();local c=f.b.sample();edit(f);assert(not f.b.bind(c).authorized and f.calls==0) end
-- Every reader throwing closes before native bind; no options/provider-table retention.
for _,key in ipairs({'get_epoch','read_evidence','read_authority'}) do
    local f=fixture(function(x) x.o[key]=function() error('read') end end)
    assert(not f:grant().authorized and f.calls==0)
end
for _,key in ipairs({'get_epoch','read_evidence','read_authority','bind'}) do
    local f=fixture(function(x)
        local old=x.o[key]
        x.o[key]=function(...) if x.b then assert(not x.b.sample().authorized) end;return old(...) end
    end)
    assert(not f:grant().authorized);assert(f.b.sample().status=='terminal')
end
-- Post-bind changes/throws discard the capability and return no ID.
for _,effect in ipairs({
    function(f) f.epoch=2 end,
    function(f) f.p.identity_loaded_world=false end,
    function(f) f.a.guild=string.rep('c',32) end,
    function(f) f.p=setmetatable({}, {__index=function() error('bad') end}) end,
}) do
    local f=fixture(function(x) local old=x.o.bind;x.o.bind=function(...) local id=old(...);effect(x);return id end end)
    local g=f:grant();assert(not g.authorized and g.binding==nil and f.calls==1 and f.drops==1)
end
for _,value in ipairs({false,true,0,-1,1.5,'71',{id=71}}) do
    local f=fixture(function(x) x.o.bind=function() x.calls=x.calls+1;return value end end)
    assert(not f:grant().authorized and f.b.sample().status=='terminal' and f.calls==1)
end
do local f=fixture(function(x) x.o.bind=function() error('uncertain') end end)
    assert(not f:grant().authorized and f.b.sample().status=='terminal') end
do local f=fixture(function(x) x.o.discard=function() error('uncertain') end end)
    assert(f:grant().authorized);f.b.revoke();assert(f.b.sample().status=='terminal') end
do local f=fixture(function(x) x.o.discard=function() x.b.sample();return true end end)
    assert(f:grant().authorized);f.b.revoke();assert(f.b.sample().status=='terminal') end
do local f=fixture(function(x) x.o.read_authority=function() x.epoch=x.epoch+1;return x.a end end)
    assert(not f:grant().authorized and f.calls==0) end
do local f=fixture();local c=f.b.sample();local forged={}
    for k,v in pairs(c) do forged[k]=v end
    assert(not f.b.bind(forged).authorized and f.calls==0)
    assert(f.b.bind(c).authorized);f.p.role=nil
    assert(f.b.sample().status=='evidence_changed' and f.drops==1)
end
do local f=fixture(function(x) x.o.limit=1 end);assert(f.b.sample().status=='candidate')
    assert(f.b.sample().status=='capacity' and f.b.sample().status=='terminal') end
do local f=fixture();assert(f:grant().authorized);f.epoch=2
    assert(not f.b.check(71).authorized and f.drops==1);f.epoch=1
    assert(f.b.sample().status~='candidate');f.epoch=3;assert(f.b.sample().status=='candidate') end
-- Actual lifecycle controller, including pre-transition invalidation and nil hooks.
do
    local hooks={};local api={}
    for _,name in ipairs({'RegisterLoadMapPreHook','RegisterLoadMapPostHook','RegisterInitGameStatePreHook','RegisterInitGameStatePostHook'}) do
        api[name]=function(cb) hooks[name]=cb end
    end
    local lifecycle=Epoch.new{enabled=true};assert(lifecycle:install(api))
    local f=fixture(function(x) x.o.get_epoch=function()
        local s=lifecycle:status();local token=lifecycle:candidate()
        return {available=token~=nil,supported=true,epoch=s.epoch,token=token}
    end end)
    assert(f.b.sample().status~='candidate')
    assert(hooks.RegisterInitGameStatePreHook()==nil);assert(hooks.RegisterInitGameStatePostHook()==nil)
    assert(f:grant().authorized)
    assert(hooks.RegisterLoadMapPreHook()==nil)
    assert(not f.b.check(71).authorized and f.drops==1)
    hooks.RegisterInitGameStatePreHook();hooks.RegisterInitGameStatePostHook();hooks.RegisterLoadMapPostHook()
    assert(f:grant().authorized)
end
-- Compose the real Pair and all three collectors with fresh, disposable mocks.
do
    local Pair=dofile(TEST_ROOT..'/experiments/save_context_pair_probe.lua')
    local weak=setmetatable({}, {__mode='k'})
    local reads=0
    local f=fixture(function(x)
        x.o.read_evidence=function()
            reads=reads+1
            local function object(n,fields)
                fields=fields or {};fields.IsValid=function() return true end
                fields.GetAddress=function() return n end;weak[fields]=true;return fields
            end
            local instance=object(13,{SelectedWorldSaveDirectoryName=string.rep('a',32)})
            local manager=object(14,{AutoSaveWorldDefaultName='',bIsLoadedWorldSaveData=true,
                GetOuter=function() return instance end})
            instance.SaveGameManager=manager
            local state=object(12,{WorldSaveDirectoryName=string.rep('a',32),Role=3,bIsDedicatedServer=false})
            local world=object(11,{GameState=state,OwningGameInstance=instance,GetFullName=function() return 'MainWorld' end})
            local level=object(15,{OwningWorld=world});state.GetLevel=function() return level end
            local engine=object(16,{GameInstance=instance,GameViewport=object(17,{World=world})})
            local p=Pair.read(engine,function(ctx) assert(ctx==instance);return state end,
                function(ctx) assert(ctx==state);return instance end)
            p.untrusted_extra_wrapper=engine -- binder must whitelist, not retain this
            return p
        end
    end)
    assert(f:grant().authorized and reads==3)
    collectgarbage('collect');collectgarbage('collect');assert(next(weak)==nil,'wrapper retained')
    assert(f.b.check(71).authorized and reads==4)
    collectgarbage('collect');collectgarbage('collect');assert(next(weak)==nil)
end
-- Actual binder + lifetime; native claim semantics are modeled here, not native
-- execution evidence. Claims exclude the scope but perform no journal operation.
local Lifetime=dofile(TEST_ROOT..'/experiments/save_binding_lifetime.lua')
local function owner_fixture(effect)
    return fixture(function(f)
        f.owners,f.claims,f.events={}, {}, {}
        f.next_id,f.journal_ops=0,0
        f.life=Lifetime.new{enabled=true,
            retire=function(id,c)
                local owner=assert(f.owners[id]);assert(owner.context.incarnation==c.incarnation)
                assert(not owner.pending and not owner.tail and not owner.retired,'early native retire')
                owner.retired=true;f.events[#f.events+1]='retire:'..id
                if f.lose_retire then error('lost retire return') end
                return true
            end,
            release=function(id,c)
                local owner=assert(f.owners[id]);assert(owner.retired and not owner.released)
                assert(f.claims[c.scope]==id and owner.context.epoch==c.epoch)
                if f.fail_release then return false end
                owner.released=true;f.claims[c.scope]=nil;f.events[#f.events+1]='release:'..id
                return true
            end}
        f.o.binding_kind='revocable-owner'
        f.o.bind=function(cap,r)
            assert(cap==42 and r.namespace=='profile-1')
            f.calls=f.calls+1;f.next_id=f.next_id+1 -- bridge burns attempted IDs
            local id=f.next_id
            local scope='PWP-SCOPE-1:'..r.worldguid..':'..r.guild..':'..r.stream
            if f.claims[scope] then return nil end -- never steal/retire old owner
            local c={scope=scope,storage=r.worldguid,guild=r.guild,stream=r.stream,
                epoch=r.epoch,incarnation=r.incarnation,session=r.incarnation,camp='A',authority=true}
            f.claims[scope]=id;f.owners[id]={context=c}
            assert(f.life.track(id,c)) -- before binder can run the postcheck
            f.events[#f.events+1]='claim:'..id
            if effect then effect(f,id) end
            return id
        end
        -- discard must not reenter the binder; its permission was already cleared.
        f.o.discard=function(id) f.drops=f.drops+1;return f.life.discard(id) end
    end)
end
for _,kind in ipairs({'unknown',false,1,{}}) do
    local f=fixture(function(x) x.o.binding_kind=kind end)
    assert(f:grant().status=='unconfigured' and f.calls==0)
end
do
    local f=owner_fixture();f.p.identity_loaded_world=false
    assert(not f:grant().authorized and f.calls==0 and next(f.claims)==nil)
end
-- Changes, thrown readers, and reentry after claim all revoke immediately, then
-- defer native cleanup to the lifetime. No postcheck failure starts recovery.
for _,effect in ipairs({
    function(f) f.epoch=2 end,
    function(f) f.a.authority=false end,
    function(f) f.p=setmetatable({}, {__index=function() error('unreadable') end}) end,
    function(f) assert(f.b.check(1).status=='reentrant') end,
}) do
    local f=owner_fixture(effect)
    local g=f:grant();assert(not g.authorized and g.binding==nil and f.drops==1)
    assert(f.life.status(1).state=='draining' and not f.life.current(1,f.owners[1].context))
    assert(f.claims[f.owners[1].context.scope]==1 and #f.events==1 and f.journal_ops==0)
    assert(f.life.poll(1) and f.life.poll(1) and #f.events==3 and next(f.claims)==nil)
    assert(not f.b.check(1).authorized)
end
-- Successful grant doesn't imply journal admission; default callbacks and fresh
-- checks still govern every operation. Revoke keeps the accepted tail's owner.
do
    local f=owner_fixture();f.o.binding_kind='unknown' -- construction captured mode
    local grant=f:grant();assert(grant.authorized and f.journal_ops==0)
    local old=f.owners[1];local c=old.context
    assert(f.b.check(1).authorized and f.life.current(1,c))
    local closed=false
    assert(f.life.attach(1,{
        close=function(context) assert(context.incarnation==c.incarnation);closed=true;return false end,
        poll=function(context)
            assert(closed and context.epoch==c.epoch)
            if old.done then
                old.pending=false;old.done=false
                if old.tail then
                    assert(not old.retired);old.tail=false;old.pending=true
                    f.journal_ops=f.journal_ops+1 -- accepted coalesced tail reservation
                end
            end
        end,
        drained=function() return not old.pending and not old.tail end}))
    old.pending,old.tail=true,true;f.journal_ops=1
    assert(f.b.revoke().status=='revoked' and not f.b.check(1).authorized)
    assert(not f.life.current(1,c) and f.claims[c.scope]==1)
    assert(not f.life.poll(1) and not old.retired)
    -- Same scope, new epoch: native exclusion must reject a replacement while
    -- old accepted data still owns the destination. No implicit ownership theft.
    f.epoch=2;f.token=function() end
    local replacement=Binding.new(f.o) -- restore valid explicit mode first
    assert(replacement.sample().status=='unconfigured')
    f.o.binding_kind='revocable-owner';replacement=Binding.new(f.o)
    local denied=replacement.bind(replacement.sample())
    assert(not denied.authorized and denied.status=='bind_uncertain')
    assert(f.claims[c.scope]==1 and not old.retired and f.drops==1)
    old.done=true;assert(not f.life.poll(1) and f.journal_ops==2 and not old.retired)
    old.done=true;assert(f.life.poll(1) and old.released and next(f.claims)==nil)
    -- Fresh binder, different incarnation, after definite release can bind.
    f.o.boot='new-boot';replacement=Binding.new(f.o)
    local new=replacement.bind(replacement.sample());assert(new.authorized and new.binding==3)
    assert(not f.life.current(1,f.owners[3].context) and not f.life.current(3,c))
    assert(replacement.check(3).authorized and f.claims[c.scope]==3)
end
-- Lost bind return is never retried or guessed/discarded by the binder. The
-- native claim remains held and no authorization or journal operation escapes.
do
    local f=owner_fixture(function() error('lost bind return after claim') end)
    assert(f:grant().status=='bind_uncertain' and f.drops==0 and f.calls==1)
    assert(f.b.sample().status=='terminal' and not f.b.check(1).authorized)
    assert(next(f.claims)~=nil and f.journal_ops==0 and #f.events==1)
end
for _,failure in ipairs({'lose_retire','fail_release'}) do
    local f=owner_fixture(function(x) x.a.authority=false end);f[failure]=true
    assert(not f:grant().authorized and f.drops==1)
    assert(not f.life.poll(1) and f.life.status(1).state=='uncertain')
    local count=#f.events
    assert(f.life.discard(1) and not f.life.poll(1) and #f.events==count)
    assert(next(f.claims)~=nil and not f.b.check(1).authorized and f.journal_ops==0)
end
print('local binding: fresh checks, explicit owner claim, tracked discard/drain, exclusion and uncertainty passed')
