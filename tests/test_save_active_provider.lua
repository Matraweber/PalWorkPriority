local Provider=dofile(TEST_ROOT..'/experiments/save_active_provider.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local W,G,OTHER=string.rep('a',32),string.rep('b',32),string.rep('c',32)
local function fixture(proof)
    local f={reads=0,proofs=0}
    f.e={epoch=1,authority_status='read',authority=true,guild_status='format_valid',guild=G,
        state={status='observed',current_world_status='context_agrees',verified=false,
            world='World same-map',world_address=101,instance_address=102,state_address=103,
            directory_status='format_valid',directory=W,role_status='read',role=3,
            dedicated_status='read',dedicated=false},
        identity={world='World same-map',world_address=101,instance_address=102,
            loaded_status='read',loaded_world=true,selected_status='format_valid',selected=W,
            autosave_status='empty',verified=false}}
    local options={enabled=true,boot='unique-process-provider',stream='priorities',
        read_evidence=function()
            f.reads=f.reads+1
            if f.on_read then f.on_read() end
            return f.e
        end}
    if proof then options.verify_storage=function(r)
        f.proofs=f.proofs+1
        if f.on_proof then return f.on_proof(r) end
        r.contract='PWP-ACTIVE-STORAGE-1';r.active=true;return r -- SIMULATED proof only
    end end
    f.p=Provider.new(options)
    function f.check(s) return f.p.authorize(s.scope.key,s.incarnation) end
    return f
end
assert(Provider.new{}.sample().status=='disabled')
assert(Provider.new{enabled=true}.sample().status=='unconfigured')
local f=fixture();local first=f.p.sample()
assert(first.status=='candidate' and first.verified==false and first.active==false)
assert(first.scope.key==Scope.new(W,G,'priorities').key and not f.check(first))
assert(f.proofs==0,'observation synthesized a native proof')
-- Real controller refuses even recovery IO until separate active proof exists.
local calls=0
local c=Session.new{enabled=true,clock=function() return 0 end,lease={},authorize=f.p.authorize,
    factory=function(owner,token)
        return Queue.new({start_read=function() calls=calls+1;return true end,
            start=function() calls=calls+1;return true end,poll=function() end},owner,token)
    end}
assert(not c:open(first.scope.key,first.incarnation) and calls==0)
f=fixture(true);first=f.p.sample();assert(f.check(first) and f.proofs==1)
assert(f.p.sample().incarnation==first.incarnation)
-- No caller mutation of a returned copy changes private identity state.
first.scope.storage=OTHER;first.scope.guild=OTHER
assert(f.p.sample().scope.storage==W and f.p.sample().scope.guild==G)
-- Host -> client (same map, retained selected ID) -> host, even reused addresses.
f=fixture(true);first=f.p.sample()
f.e.epoch=2;f.e.authority=false;f.e.state.role=1;f.e.state.dedicated=true
f.e.state.directory=OTHER;f.e.identity.loaded_world=false
assert(f.p.sample().status=='not_authority' and not f.check(first))
f.e.epoch=3;f.e.authority=true;f.e.state.role=3;f.e.state.dedicated=false
f.e.state.directory=W;f.e.identity.loaded_world=true
local back=f.p.sample();assert(back.scope.key==first.scope.key and back.incarnation~=first.incarnation)
assert(not f.check(first) and f.check(back))
-- Unobserved travel requires the external lifecycle epoch; pointers/map may repeat.
f=fixture(true);first=f.p.sample();f.e.epoch=3
back=f.p.sample();assert(back.incarnation~=first.incarnation and not f.check(first))
f.e.epoch=1;assert(f.p.sample().status=='stale_epoch')
-- Explicit nil/false/ambiguous evidence is never silently promoted.
local mutations={
    function(e) e.authority=nil end,function(e) e.authority_status=nil end,
    function(e) e.guild=nil end,function(e) e.guild=string.rep('0',32) end,
    function(e) e.state.directory=nil end,function(e) e.state.directory_status='read_failed' end,
    function(e) e.state.role=nil end,function(e) e.state.role=1 end,
    function(e) e.state.dedicated=nil end,function(e) e.state.dedicated=true end,
    function(e) e.identity.loaded_world=nil end,function(e) e.identity.loaded_world=false end,
    function(e) e.identity.loaded_status='unavailable' end,
    function(e) e.identity.world_address=nil end,function(e) e.identity.instance_address=999 end,
    function(e) e.identity.selected=OTHER end,function(e) e.identity.selected=nil end,
    function(e) e.identity.autosave_status='read_failed' end,
    function(e) e.identity.autosave={} end,
    function(e) e.identity.autosave_status='format_valid';e.identity.autosave=OTHER end,
    function(e) e.state.current_world_status='unestablished' end,
    function(e) e.state.world_address=0 end,function(e) e.epoch=nil end,
    function(e) setmetatable(e.state,{}) end,
}
for _,mutate in ipairs(mutations) do
    f=fixture(true);first=f.p.sample();mutate(f.e)
    assert(f.p.sample().status~='candidate' and not f.check(first) and f.proofs==0)
end
-- Root/scratch observations, booleans and foreign proofs do not satisfy Auth.
for _,proof in ipairs({true,{exists=true},{root_and_native_readback_correlated=true,active_storage_verified=false},
    {contract='PWP-ACTIVE-STORAGE-1',active=true,storage=OTHER}}) do
    f=fixture(true);first=f.p.sample();f.on_proof=function() return proof end
    assert(not f.check(first))
end
-- Re-read fences discard proofs if the source changes during verification.
for _,mutate in ipairs({function(e) e.epoch=2 end,function(e) e.state.state_address=999 end,
    function(e) e.guild=OTHER end,function(e) e.authority=false end,
    function(e) e.state.directory=OTHER;e.identity.selected=OTHER end}) do
    f=fixture(true);first=f.p.sample()
    f.on_proof=function(r) r.contract='PWP-ACTIVE-STORAGE-1';r.active=true;mutate(f.e);return r end
    assert(not f.check(first))
end
-- Fresh reads are copied before the next call can mutate its reused source table.
f=fixture(true);first=f.p.sample();local start=f.reads
f.on_read=function() if f.reads==start+2 then f.e.state.state_address=999 end end
assert(not f.check(first))
f=fixture(true);first=f.p.sample();f.on_read=function() error('PRIVATE read error') end
assert(f.p.sample().status=='read_failed' and not f.check(first))
f.on_read=nil;back=f.p.sample();assert(back.incarnation~=first.incarnation)
f=fixture(true);f.on_read=function() assert(f.p.sample().status=='reentrant_read') end
assert(f.p.sample().status=='reentrant_read')
-- Bounded incarnation allocation, no token reuse when capacity is exhausted.
f=fixture()
for n=1,256 do f.e.epoch=n;assert(f.p.sample().status=='candidate') end
f.e.epoch=257;assert(f.p.sample().status=='incarnation_capacity')
assert(f.p.sample().status=='incarnation_capacity')
print('active provider: copied fresh evidence, same-map role/epoch fences, missing/ambiguous refusal, external-proof gate and zero-IO denial passed')
