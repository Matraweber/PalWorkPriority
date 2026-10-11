local function fixture(pristine)
    package.loaded.settings_gate=nil
    local Gate=require('settings_gate')
    local Group=dofile(TEST_ROOT..'/experiments/settings_startup_gate_group.lua')
    local g=assert(Group.new{enabled=true})
    if pristine then return Gate,g end
    local l,p=assert(g:child('limits')),assert(g:child('priorities'))
    local a,b=assert(l.acquire()),assert(p.acquire())
    return Gate,g,l,p,a,b
end
do local G,g=fixture(true)
    assert(g:opt_out(),'pristine client group must permit terminal opt-out')
    assert(not G.blocked() and g:status().terminal and not g:status().committed)
    assert(not g:opt_out() and not g:child('limits') and not g:commit(function()return true end))
    assert(g:fence() and G.status()=='restart_required')
    assert(not g:opt_out() and G.blocked())
end
for _,mode in ipairs({'facade','acquired','released','committed','terminal','foreign'})do
    local G,g=fixture(true)
    local foreign
    if mode=='foreign'then
        -- Capture only this fixture's token, then replace it with another owner.
        package.loaded.settings_gate=nil;G=require('settings_gate')
        local acquire=G.acquire;local token
        G.acquire=function()token=acquire();return token end
        g=assert(dofile(TEST_ROOT..'/experiments/settings_startup_gate_group.lua').new{enabled=true})
        G.acquire=acquire
        assert(G.release(token));foreign=assert(G.acquire())
    elseif mode=='terminal'then g:fence()
    else
        local l=assert(g:child('limits'))
        if mode~='facade'then
            local a=assert(l.acquire())
            if mode~='acquired'then assert(l.release(a))end
        end
        if mode=='committed'then
            local p=assert(g:child('priorities'));assert(p.release(assert(p.acquire())))
            assert(g:commit(function()return true end))
        end
    end
    assert(not g:opt_out(),'opt-out accepted '..mode)
    assert(G.blocked()==(mode~='committed'))
    if foreign then assert(G.held(foreign))end
end
do local G,g,l,p,a,b=fixture()
    assert(G.blocked() and l.held(a) and p.held(b))
    assert(not l.release(b) and not p.release(a) and not g:child('limits'))
    assert(l.release(a) and G.blocked() and not l.held(a) and p.held(b))
    assert(p.release(b) and G.blocked())
    local calls=0
    assert(g:commit(function()calls=calls+1;assert(G.blocked());return true end))
    assert(calls==4 and not G.blocked() and not g:commit(function()return true end))
    assert(g:fence() and G.blocked() and g:status().terminal)
    assert(G.status()=='restart_required')
end
for _,mode in ipairs({'partial','not_ready','throw','reentry','fence'})do
    local G,g,l,p,a,b=fixture();assert(l.release(a))
    if mode~='partial'then assert(p.release(b))end
    assert(not g:commit(function(name)
        if mode=='throw'then error('lost reply')end
        if mode=='reentry'then assert(not g:commit(function()return true end))end
        if mode=='fence'then g:fence()end
        return mode~='not_ready' or name~='priorities'
    end))
    assert(G.blocked() and g:status().terminal)
    assert(not g:commit(function()return true end))
end
do local G,g,l,p,a,b=fixture();g:fence();assert(not l.held(a) and not p.held(b));assert(l.release(a) and p.release(b) and G.blocked())end
do -- Consulting the second stream must not hide loss of the first's readiness.
    local G,g,l,p,a,b=fixture();assert(l.release(a) and p.release(b))
    local limits_ready=true
    assert(not g:commit(function(name)
        if name=='priorities'then limits_ready=false;return true end
        return limits_ready
    end))
    assert(G.blocked() and g:status().terminal)
end
print('two-stream gate: no partial admission, opaque child tokens, fresh readiness and terminal failure fence')
