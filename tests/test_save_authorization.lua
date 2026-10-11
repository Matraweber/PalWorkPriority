local Auth=dofile(TEST_ROOT..'/experiments/save_authorization.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Session=dofile(TEST_ROOT..'/experiments/save_session.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local function fixture()
    local f={storage=string.rep('a',32),guild=string.rep('b',32),proofs=0}
    f.ctx={incarnation='boot:host:1',epoch=1,world='World current',guild=f.guild,role='authority',ready=true}
    f.id={world=f.ctx.world,loaded_status='read',loaded_world=true,selected_status='format_valid',
        selected=f.storage,autosave_status='empty',verified=false}
    f.options={enabled=true,stream='priorities',read_context=function() return f.ctx end,
        read_identity=function() return f.id end,
        verify_storage=function(request)
            f.proofs=f.proofs+1
            request.contract='PWP-ACTIVE-STORAGE-1';request.active=true
            return request
        end}
    f.owner=Scope.new(f.storage,f.guild,'priorities').key
    f.auth=Auth.new(f.options)
    function f:check() return self.auth(self.owner,'boot:host:1') end
    return f
end
assert(Auth.new{}('owner','token')==false)
do local f=fixture();assert(f:check() and f.proofs==1) end
for _,field in ipairs({'read_context','read_identity','verify_storage'}) do
    local f=fixture();f.options[field]=nil;assert(not f:check())
    f.options[field]=function() error('unreadable') end;assert(not f:check())
end
for _,change in ipairs({
    function(f) f.ctx.role='client' end,
    function(f) f.ctx.ready=false end,
    function(f) f.ctx.epoch=0 end,
    function(f) f.ctx.incarnation='boot:client:2' end,
    function(f) f.id.loaded_world=false end,
    function(f) f.id.loaded_status='read_failed' end,
    function(f) f.id.world='World previous' end,
    function(f) f.id.selected=string.rep('0',32) end,
    function(f) f.id.autosave_status='read_failed' end,
    function(f) f.id.autosave_status='format_valid';f.id.autosave=string.rep('c',32) end,
    function(f) f.owner=Scope.new(f.storage,f.guild,'limits').key end,
    function(f) setmetatable(f.ctx,{}) end,
}) do local f=fixture();change(f);assert(not f:check() and f.proofs==0) end
-- Directory existence, bare true, old proofs and partial proofs are not authority.
for _,change in ipairs({
    function(p) return true end,
    function(p) return {exists=true} end,
    function(p) p.active=false;return p end,
    function(p) p.epoch=2;return p end,
    function(p) p.incarnation='old';return p end,
    function(p) p.storage=string.rep('c',32);return p end,
    function(p) p.guild=string.rep('c',32);return p end,
    function(p) p.world='World old';return p end,
    function(p) p.contract=nil;return p end,
}) do
    local f=fixture();local base=f.options.verify_storage
    f.options.verify_storage=function(request) return change(base(request)) end
    assert(not f:check())
end
-- Transitions while reading cannot reuse a proof, even with the same map/ID.
for _,change in ipairs({
    function(f) f.ctx.epoch=2 end,
    function(f) f.ctx.role='client' end,
    function(f) f.ctx.ready=false end,
    function(f) f.ctx.guild=string.rep('c',32) end,
    function(f) f.ctx.world='World next' end,
    function(f) f.ctx.incarnation='boot:host:3' end,
}) do
    local f=fixture();local base=f.options.verify_storage
    f.options.verify_storage=function(request) local p=base(request);change(f);return p end
    assert(not f:check())
end
do
    local f=fixture();local base=f.options.verify_storage
    f.options.verify_storage=function(request) assert(not f:check());return base(request) end
    assert(f:check()) -- nested attempt denied, outer independent check can finish
end
-- Real controller + real queue: retained host ID on client cannot initiate IO.
do
    local f=fixture();local calls=0
    local c=Session.new{enabled=true,lease={},clock=function() return 0 end,authorize=f.auth,
        factory=function(owner,token)
            return Queue.new({start_read=function() calls=calls+1;return true end,
                start=function() error('no write authorized by this test') end,
                poll=function() end},owner,token)
        end}
    f.ctx.role='client';assert(not c:open(f.owner,'boot:host:1') and calls==0)
    f.ctx.role='authority';f.id.loaded_world=false
    assert(not c:open(f.owner,'boot:host:1') and calls==0)
    f.id.loaded_world=true;assert(c:open(f.owner,'boot:host:1') and calls==1)
    f.ctx.role='client';c:poll()
    assert(not c:submit('boot:host:1','stale') and c:status().state=='closing')
end
print('save authorization: fresh scoped proof, transition fences, stale client ID and zero-IO refusals passed')
