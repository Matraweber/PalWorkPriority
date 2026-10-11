local Queue=dofile(TEST_ROOT..'/experiments/save_draining_queue.lua')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Session=dofile(TEST_ROOT..'/experiments/settings_session.lua')
local W,G=string.rep('3',32),string.rep('4',32)
local scope='PWP-SCOPE-1:'..W..':'..G..':priorities'
local codec=Codec.new{storage=W,guild=G,stream='priorities'}
local Store=require('store')
local b1=assert(Store.serialize_snapshot({pal={[1]=1,[2]=false}},true))
local b2=assert(Store.serialize_snapshot({pal={[1]=2,[2]=false}},true))
local p1,p2=assert(codec.encode(b1)),assert(codec.encode(b2))
local function fixture(existing)
    local f={calls={},a=0,c=0,g=existing and 2 or 0,phase='dormant',ticket=0,owned={}}
    local backend={contract='PWP-DRAINING-DEV-1',max_payload_bytes=65536}
    local function view()return {scope=scope,session='session',ticket=f.ticket,generation=f.g,
        committed=f.c,known_accepted=f.a,state=f.phase=='awaiting_validation' and f.phase or 'saving',phase=f.phase}end
    local function mark(k)f.calls[#f.calls+1]=k;f.ticket=f.ticket+1 end
    function backend:start()mark('start');f.phase='awaiting_validation';return true end
    function backend:inspect()return view()end
    function backend:poll()return view()end
    function backend:recovery()return {scope=scope,session='session',kind=existing and 'existing' or 'missing',payload=existing and p1}end
    function backend:approve(_,mode)mark('approve');assert(mode==(existing and 'existing' or 'initialize_missing'));f.phase='ready';return true end
    function backend:submit(_,body)
        mark('submit');f.a=f.a+1;f.owned[f.a]=assert(codec.encode(body))
        if f.lost then error('lost reply')end
        return {scope=scope,session='session',revision=f.a},'pending'
    end
    function backend:close()mark('close');if f.close_lost then error('lost close')end;f.phase='closing';return true end
    function backend:drain()
        mark('drain');if f.drain_lost then error('lost drain')end
        f.c=f.a;f.g=math.max(f.g,f.a);f.phase='closed';return view()
    end
    function backend:cleanup()mark('cleanup');f.cleaned=true;return true end
    function f:complete()self.c=self.a;self.g=math.max(self.g,self.a)end
    f.backend=backend
    f.options={enabled=true,storage=W,guild=G,stream='priorities',session='session',incarnation='inc',epoch=1,backend=backend}
    f.q=Queue.new(f.options)
    return f
end
do
    local f=fixture(false);local q=f.q
    assert(#f.calls==0 and q:recover());q:poll();assert(q:can_initialize())
    assert(q:initialize(p1)==1 and f.owned[1]==p1 and q.saved==0)
    assert(q:poll()==nil);f:complete();local yes,p=q:poll();assert(yes and p==p1 and q.saved==1)
    assert(q:poll()==nil and not q:can_initialize())
    assert(q:submit(p2)==2 and f.owned[2]==p2 and q.saved==1)
    assert(q:close_admission() and not q:can_shutdown())
    assert(q:shutdown_drain() and q:can_shutdown() and f.cleaned and q.saved==2)
    local n=#f.calls;assert(q:shutdown_drain() and #f.calls==n)
end
do
    local f=fixture(true);local q=f.q
    assert(q:recover());local yes,p=q:poll();assert(yes and p==p1 and q.saved==0 and q.journal_generation==2)
    assert(q:submit(p2)==1);assert(f.owned[1]==p2 and q.saved==0)
    f:complete();q:poll();assert(q.saved==1)
end
for _,fault in ipairs({'lost','close_lost','drain_lost'})do
    local f=fixture(true);local q=f.q;q:recover();q:poll();f[fault]=true
    q:submit(p2);q:close_admission();q:shutdown_drain()
    local n=#f.calls;q:close_admission();q:shutdown_drain()
    assert(not q:can_shutdown() and not f.cleaned and #f.calls==n,'unsafe retry '..fault)
end
do
    local f=fixture(true);local q=f.q;q:recover();q:poll();q:submit(p2)
    q:timeout();assert(q.state=='uncertain');f:complete();q:poll()
    assert(q.saved==0 and q.state=='uncertain' and not q:retry())
end
-- Real settings_session + barrier composition, not only facade counters.
do
    local f=fixture(true)
    -- Authorizer/backend reentry must not turn the outer recovery into success.
    local prior=f.backend.recovery
    f.backend.recovery=function(self,c)f.q:poll();return prior(self,c)end
    -- Methods are captured on construction; construct the actual attacked queue.
    f.q=Queue.new(f.options);f.q:recover()
    assert(f.q:poll()==nil and f.q.state=='uncertain')
    assert(f.q:submit(p2)==nil and f.a==0)
end
do
    local f=fixture(true);local yes=true
    local opts=f.options;opts.backend_kind='PWP-DRAINING-DEV-1';opts.lease={};opts.clock=function()return 1 end
    opts.authorize=function()return yes end
    local s=Session.new(opts)
    local c={scope=scope,storage=W,guild=G,stream='priorities',session='session',incarnation='inc',epoch=1,authority=true,camp='camp'}
    assert(s:open(c));assert(s:poll(c)=='recovered');local r=s:take_recovered(c)
    assert(r.revision==0 and s:register_camp(c,true) and s:ready(c))
    local t=s:stage(c,{baseline=true});local receipt=s:submit(c,t,b2)
    assert(receipt.revision==1 and f.owned[1]==p2 and not s:ready(c))
    f:complete();s:poll(c);assert(s:ready(c) and s:status(c).barrier.durable==1)
    yes=false;assert(not s:ready(c));assert(s:drain(c));assert(f.cleaned)
    assert(s:take_recovered(c)==nil and not s:ready(c))
end
print('native queue: native-owned admission, typed initialization/recovery, no replay, explicit drain and real session/barrier passed')
