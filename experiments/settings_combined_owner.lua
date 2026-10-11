-- Default-off preparatory cleanup owner, no activation, IO or native calls.
-- new{enabled=true,fence=function(stream)}; register both original placeholders
-- BEFORE native creation. Placeholders own unknown/failed binds. Never replace.
-- :register(stream,owner,proofs): proofs is a dense list of 1..8 proof objects.
-- Owners use colon retire/drain/status; proofs use dot revoke/status. Providers
-- must be synchronous, non-yielding. Fence returns nil/true; false/throw fails.
-- Boolean false from revoke/retire is normal (existing lifecycle convention).
-- Shared proofs are revoked once. Every callback is captured at registration.
-- Retire fences BOTH streams, revokes ALL proofs, then retires ALL children.
-- Drain runs that prelude if needed, then attempts each original once, even on
-- failure. Lost replies are never retried. Any uncertainty retains all originals.
local M={}
local streams={'limits','priorities'}
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function methods(t,names)
    if not plain(t)then return end
    local r={};for _,k in ipairs(names)do
        local fn=rawget(t,k);if type(fn)~='function'then return end;r[k]=fn
    end;return r
end
function M.new(o)
    if not plain(o) or o.enabled~=true then return nil,'disabled' end
    if type(o.fence)~='function'then return nil,'invalid_fence' end
    local fence=o.fence
    local slots,proofs,by_proof={},{},{}
    local terminal,busy,uncertain,retired,drained,verified=false,false,false,false,false,false
    local fences={}
    local api={}
    local function reentrant()
        if busy then uncertain=true;terminal=true;return true end
        return false
    end
    function api:register(stream,owner,list)
        if reentrant()then return false end
        if terminal or (stream~='limits' and stream~='priorities') or slots[stream]then return false end
        local callbacks=methods(owner,{'retire','drain','status'})
        if not callbacks or not plain(list)then return false end
        for _,s in pairs(slots)do if s.owner==owner then return false end end
        local n=0
        for i in next,list do
            n=n+1;if n>8 or math.type(i)~='integer' or i<1 or i>8 then return false end
        end
        if n==0 then return false end
        local pending={}
        for i=1,n do
            local p=rawget(list,i);local cb=methods(p,{'revoke','status'})
            if not cb then return false end
            pending[i]={object=p,revoke=cb.revoke,status=cb.status}
        end
        local child={owner=owner,retire=callbacks.retire,drain=callbacks.drain,status=callbacks.status,
            proofs={},retire_attempted=false,drain_attempted=false,drain_confirmed=false}
        for _,p in ipairs(pending)do
            local captured=by_proof[p.object]
            if not captured then captured=p;by_proof[p.object]=p;proofs[#proofs+1]=p end
            child.proofs[#child.proofs+1]=captured
        end
        slots[stream]=child;return true
    end
    local function retire_all()
        if retired then return end
        retired=true;terminal=true
        for _,stream in ipairs(streams)do
            fences[stream]={attempted=true,confirmed=false}
            local ok,value=pcall(fence,stream)
            fences[stream].confirmed=ok and (value==nil or value==true)
            if not fences[stream].confirmed then uncertain=true end
        end
        for _,p in ipairs(proofs)do
            p.attempted=true
            local ok,value=pcall(p.revoke)
            p.revoke_ok=ok and type(value)=='boolean'
            local good,s=pcall(p.status)
            p.confirmed=p.revoke_ok and good and plain(s) and rawget(s,'state')=='revoked'
            if not p.confirmed then uncertain=true end
        end
        for _,stream in ipairs(streams)do
            local s=slots[stream]
            if s then
                s.retire_attempted=true
                local ok,value=pcall(s.retire,s.owner)
                s.retire_ok=ok and type(value)=='boolean'
                if not s.retire_ok then uncertain=true end
            end
        end
    end
    function api:retire()
        if reentrant()then return false end
        busy=true;retire_all();busy=false
        return verified -- retirement alone never claims verified drain
    end
    function api:drain()
        if reentrant()then return false end
        if drained then return verified end
        busy=true;retire_all();drained=true
        for _,stream in ipairs(streams)do
            local s=slots[stream]
            if s then
                s.drain_attempted=true
                local ok,value=pcall(s.drain,s.owner)
                s.drain_ok=ok and value==true
                local good,state=pcall(s.status,s.owner)
                s.closed=good and plain(state) and rawget(state,'state')=='closed'
                    and rawget(state,'owner_retained')==false
                s.drain_confirmed=s.drain_ok and s.closed
                if not s.drain_confirmed then uncertain=true end
            end
        end
        verified=not uncertain and slots.limits~=nil and slots.priorities~=nil
            and slots.limits.drain_confirmed and slots.priorities.drain_confirmed
        if verified then
            -- Release only after all external calls, including status, returned.
            for _,s in pairs(slots)do s.owner=nil;s.retire=nil;s.drain=nil;s.status=nil end
            for _,p in ipairs(proofs)do p.object=nil;p.revoke=nil;p.status=nil end
            by_proof={}
        end
        busy=false;return verified
    end
    function api:status()
        local children,retained={},false
        for _,stream in ipairs(streams)do
            local s=slots[stream]
            local c={registered=s~=nil,fence_attempted=fences[stream]~=nil,
                fence_confirmed=fences[stream]~=nil and fences[stream].confirmed}
            if s then
                c.owner_retained=s.owner~=nil;retained=retained or c.owner_retained
                c.retire_attempted=s.retire_attempted;c.retire_ok=s.retire_ok==true
                c.drain_attempted=s.drain_attempted;c.drain_ok=s.drain_ok==true
                c.drain_confirmed=s.drain_confirmed;c.closed=s.closed==true
                c.proofs={}
                for i,p in ipairs(s.proofs)do c.proofs[i]={revoke_attempted=p.attempted==true,
                    revoke_ok=p.revoke_ok==true,revoked=p.confirmed==true}end
            end
            children[stream]=c
        end
        return {state=verified and 'closed' or terminal and 'retained' or 'collecting',
            owner_retained=retained,terminal=terminal,uncertain=uncertain,
            cleanup_verified=verified,retire_attempted=retired,drain_attempted=drained,children=children}
    end
    return api
end
return M
