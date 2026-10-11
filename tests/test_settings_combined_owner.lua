local Combined=dofile(TEST_ROOT..'/experiments/settings_combined_owner.lua')
local function fixture(partial)
    local f={events={},owners={},proofs={},counts={}}
    local function event(s)f.events[#f.events+1]=s;f.counts[s]=(f.counts[s]or 0)+1 end
    f.combined=assert(Combined.new{enabled=true,fence=function(stream)
        event('fence:'..stream);if f.fence then return f.fence(stream)end;return true
    end})
    for _,stream in ipairs({'limits','priorities'})do
        local owner,proof={},{}
        f.owners[stream],f.proofs[stream]=owner,proof
        proof.revoke=function(...)
            assert(select('#',...)==0);event('revoke:'..stream)
            assert(f.counts['fence:limits']==1 and f.counts['fence:priorities']==1)
            if f.revoke then return f.revoke(stream)end;return false
        end
        proof.status=function(...)
            assert(select('#',...)==0);event('proofstatus:'..stream)
            if f.proofstatus then return f.proofstatus(stream)end;return {state='revoked'}
        end
        owner.retire=function(self)
            assert(self==owner);event('retire:'..stream)
            assert(f.counts['revoke:limits']==1)
            if not partial then assert(f.counts['revoke:priorities']==1)end
            if f.retire then return f.retire(stream)end;return false
        end
        owner.drain=function(self)
            assert(self==owner);event('drain:'..stream)
            assert(f.counts['retire:limits']==1)
            if not partial then assert(f.counts['retire:priorities']==1)end
            if f.drain then return f.drain(stream)end;return true
        end
        owner.status=function(self)
            assert(self==owner);event('status:'..stream)
            if f.status then return f.status(stream)end;return {state='closed',owner_retained=false}
        end
        if stream=='limits' or not partial then assert(f.combined:register(stream,owner,{proof}))end
    end
    function f.once(success)
        assert(f.combined:drain()==success)
        local n=#f.events;f.combined:retire();assert(f.combined:drain()==success and #f.events==n)
        for _,stream in ipairs(partial and {'limits'}or{'limits','priorities'})do
            assert(f.counts['drain:'..stream]==1 and f.counts['retire:'..stream]==1)
            assert(f.combined:status().children[stream].owner_retained==not success)
        end
    end
    return f
end
assert(not Combined.new() and not Combined.new{} and not Combined.new{enabled='true'})
assert(not Combined.new{enabled=true} and not Combined.new{enabled=true,fence=false})
do
    local f=fixture();assert(#f.events==0 and f.combined:status().state=='collecting')
    assert(not f.combined:retire());assert(#f.events==8)
    f.once(true);local s=f.combined:status()
    assert(s.state=='closed' and not s.owner_retained and s.cleanup_verified and not s.uncertain)
    s.children.limits.drain_confirmed=false;assert(f.combined:status().children.limits.drain_confirmed)
end
do local f=fixture();f.once(true)end
do
    local f=fixture();f.fence=function(stream)
        local s=f.combined:status()
        assert(s.children[stream].fence_attempted and not s.children[stream].fence_confirmed)
        if stream=='limits'then assert(not s.children.priorities.fence_attempted)end
    end
    f.once(true)
end
do local f=fixture(true);f.once(false);local s=f.combined:status()
    assert(not s.children.priorities.registered and s.owner_retained and not s.cleanup_verified)
    assert(not f.combined:register('priorities',f.owners.priorities,{f.proofs.priorities}))
end
do local c=assert(Combined.new{enabled=true,fence=function()end})
    assert(not c:drain() and not c:status().cleanup_verified)end
for _,boundary in ipairs({'fence','revoke','proofstatus','retire','drain','status'})do
    for _,mode in ipairs({'throw','bad','reenter_retire','reenter_drain','reenter_register'})do
        local f=fixture()
        f[boundary]=function(stream)
            if stream=='limits'then
                if mode=='throw'then error({untrusted=true})end
                if mode=='bad'then return {}end
                if mode=='reenter_retire'then assert(not f.combined:retire())end
                if mode=='reenter_drain'then assert(not f.combined:drain())end
                if mode=='reenter_register'then assert(not f.combined:register('limits',{},{}))end
            end
            if boundary=='status'then return {state='closed',owner_retained=false}end
            if boundary=='proofstatus'then return {state='revoked'}end
            return true
        end
        f.once(false)
        assert(f.combined:status().uncertain and f.counts['drain:priorities']==1)
    end
end
for _,value in ipairs({false,1,'true'})do
    local f=fixture();f.drain=function(stream)return stream=='priorities' or value end
    f.once(false);assert(not f.combined:status().children.limits.drain_confirmed)
end
do local f=fixture();f.drain=function(stream)if stream=='priorities'then return true end end;f.once(false)end
do local f=fixture();f.proofstatus=function()return {state='bound'}end;f.once(false)end
do local f=fixture();f.status=function()return {state='closed',owner_retained=true}end;f.once(false)end
do local f=fixture();f.fence=function()return false end;f.once(false)end
do -- Captured originals survive rejected replacement and method/list mutation.
    local f=fixture();local replacement={retire=function()error('replacement')end}
    assert(not f.combined:register('limits',replacement,{}))
    f.owners.limits.drain=function()error('method replaced')end
    f.proofs.limits.revoke=function()error('method replaced')end
    f.once(true)
end
do -- Shared proofs and multiple per-stream proofs are all revoked before owners.
    local f=fixture(true);local extra=0
    local p={revoke=function()extra=extra+1;return false end,status=function()return {state='revoked'}end}
    assert(f.combined:register('priorities',f.owners.priorities,{f.proofs.limits,p}))
    assert(f.combined:drain() and extra==1 and f.counts['revoke:limits']==1)
end
do -- Bounded dense proof lists; a rejected registration leaves the slot free.
    local f=fixture(true)
    for _,list in ipairs({{}, {[2]=f.proofs.priorities}, {f.proofs.priorities,extra=true},
        {{revoke=function()end}}, setmetatable({f.proofs.priorities},{})})do
        assert(not f.combined:register('priorities',f.owners.priorities,list))
    end
    local many={};for i=1,9 do many[i]=f.proofs.priorities end
    assert(not f.combined:register('priorities',f.owners.priorities,many))
    assert(not f.combined:register('priorities',f.owners.limits,{f.proofs.priorities}))
    local list={f.proofs.priorities};assert(f.combined:register('priorities',f.owners.priorities,list))
    list[1]={};assert(f.combined:drain())
end
do -- Actual references, not just flags: failed owners/proofs survive collection.
    for _,success in ipairs({false,true})do
        local weak=setmetatable({}, {__mode='v'})
        local c=assert(Combined.new{enabled=true,fence=function()return true end})
        local function register(stream,i)
            local owner={retire=function()return false end,drain=function()return success end,
                status=function()return {state='closed',owner_retained=false}end}
            local proof={revoke=function()return false end,status=function()return {state='revoked'}end}
            weak[i]=owner;weak[i+2]=proof;assert(c:register(stream,owner,{proof}))
        end
        register('limits',1);register('priorities',2)
        assert(c:drain()==success);collectgarbage('collect');collectgarbage('collect')
        if success then assert(next(weak)==nil)else for i=1,4 do assert(weak[i]~=nil)end end
        assert(c:drain()==success)
    end
end
print('combined owner: both fences, all proofs first, independent once-only cleanup, retained originals')
