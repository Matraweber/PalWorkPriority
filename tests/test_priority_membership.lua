package.loaded.log={warn=function()end,error=function()end}
local Adapter=dofile(TEST_ROOT..'/experiments/settings_priority_membership.lua')
local Store=require('store')
local W,G=string.rep('1',32),string.rep('a',32)
local KEY=string.rep('0',32)..string.rep('A',32)
local OTHER=string.rep('B',64)
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function fixture(edit)
    local f={auths=0,reads=0,contexts={}}
    f.context={scope='PWP-SCOPE-1:'..W..':'..G..':priorities',storage=W,guild=G,stream='priorities',
        session='boot',incarnation='inc',epoch=1,camp='camp',authority=true}
    f.result={complete=true,key=KEY,group=G,world_resolved=true,in_guild=true}
    f.options={enabled=true,context=copy(f.context),runtime_guild=G,
        authorize=function(c,alias)
            assert(alias==G)
            f.auths=f.auths+1;f.contexts[#f.contexts+1]=c
            assert(c~=f.context and c~=f.options.context)
            return true
        end,
        read_member=function(k,c)
            f.reads=f.reads+1;f.contexts[#f.contexts+1]=c
            assert(k==KEY and c~=f.context);return f.result
        end}
    if edit then edit(f) end
    f.adapter=assert(Adapter.new(f.options))
    function f.check()return f.adapter.owns_key(KEY,f.context)end
    function f.denied()
        assert(not f.check() and f.adapter.status().state=='revoked')
        local a,r=f.auths,f.reads;assert(not f.check() and f.auths==a and f.reads==r)
    end
    return f
end
assert(Adapter.new()==nil and Adapter.new{}==nil and Adapter.new{enabled='true'}==nil)
do
    local f=fixture();assert(f.auths==0 and f.reads==0)
    assert(f.check() and f.check() and f.auths==4 and f.reads==2)
    for i,c in ipairs(f.contexts)do for j=1,i-1 do assert(c~=f.contexts[j])end end
    f.result.in_guild=false;f.denied();assert(f.reads==3 and f.auths==6)
end
do -- Captured scalars/providers cannot be replaced through the constructor input.
    local f=fixture();f.options.context.epoch=2
    f.options.authorize=function()error('replacement')end
    f.options.read_member=function()error('replacement')end
    assert(f.check());local s=f.adapter.status();s.state='revoked';assert(f.check())
end
do -- Reusing a previously retained disposable context never changes the capture.
    local f=fixture();assert(f.check());f.contexts[1].epoch=9;assert(f.check())
end
for _,field in ipairs({'scope','storage','guild','stream','session','incarnation','epoch','camp','authority'})do
    local f=fixture();assert(f.check())
    f.context[field]=field=='epoch' and 2 or 'wrong';f.denied()
    assert(f.auths==2 and f.reads==1)
    f=fixture();f.context[field]=nil;f.denied();assert(f.auths==0)
end
for _,bad in ipairs({'', 'pal','slot1', string.rep('a',64),string.rep('0',64),
    string.rep('A',32)..string.rep('0',32),string.rep('A',63),{},false})do
    local f=fixture();assert(not f.adapter.owns_key(bad,f.context));assert(f.auths==0 and f.reads==0)
end
do local f=fixture();assert(not f.adapter.owns_key(nil,f.context))end
do -- Use Store's real key validator, not a locally substituted durable-key policy.
    assert(Store.durable_key(KEY) and Store.durable_key('pal'))
    local f=fixture();assert(not f.adapter.owns_key('pal',f.context))
end
for _,edit in ipairs({
    function(f)f.result=nil end,
    function(f)f.result=false end,
    function(f)f.result={} end,
    function(f)f.result.key=OTHER end,
    function(f)f.result.group=string.rep('b',32)end,
    function(f)f.result.group=G:upper()end,
    function(f)f.result.extra=true end,
    function(f)setmetatable(f.result,{__index=function()error('unexpected metamethod')end})end,
})do local f=fixture();edit(f);f.denied();assert(f.auths==2 and f.reads==1)end
for _,field in ipairs({'complete','key','group','world_resolved','in_guild'})do
    for _,value in ipairs({false,'true',1,{}})do
        local f=fixture();f.result[field]=value;f.denied()
    end
    local f=fixture();f.result[field]=nil;f.denied()
end
for _,boundary in ipairs({'before','read','after'})do
    for _,mode in ipairs({'throw','reenter','revoke','mutate','metatable','extra','caller','retained','false','truthy'})do
        local f=fixture(function(x)
            local function action(c)
                x.injections=(x.injections or 0)+1
                if mode=='throw'then error({wrapper=true})end
                if mode=='reenter'then assert(not x.check())end
                if mode=='revoke'then x.adapter.revoke()end
                if mode=='mutate'then c.epoch=2 end
                if mode=='metatable'then setmetatable(c,{})end
                if mode=='extra'then c.extra={}end
                if mode=='caller'then x.context.epoch=2 end
                if mode=='retained'then x.contexts[1].camp='changed'end
                if mode=='false'then return false end
                if mode=='truthy'then return 1 end
                return true
            end
            local old_auth,old_read=x.options.authorize,x.options.read_member
            x.options.authorize=function(c,alias)
            assert(alias==G)
                old_auth(c,alias)
                if (boundary=='before' and x.auths==1) or (boundary=='after' and x.auths==2)then return action(c)end
                return true
            end
            x.options.read_member=function(k,c)
                local r=old_read(k,c)
                if boundary=='read'then local yes=action(c);if yes~=true then return yes end end
                return r
            end
        end)
        f.denied()
        assert(f.injections==1,boundary..':'..mode..' injection not exercised')
    end
end
do -- Final authorization cannot alter a previously valid observation into a grant.
    local f=fixture(function(x)
        local old=x.options.authorize
        x.options.authorize=function(c,alias)old(c,alias);if x.auths==2 then x.result.group=string.rep('b',32)end;return true end
    end)
    f.denied()
end
do -- Nor can it repair a negative observation after the fact.
    local f=fixture(function(x)
        x.result.in_guild=false
        local old=x.options.authorize
        x.options.authorize=function(c,alias)old(c,alias);if x.auths==2 then x.result.in_guild=true end;return true end
    end)
    f.denied()
end
do local f=fixture();f.adapter.revoke();f.denied();assert(f.auths==0 and f.reads==0)end
do -- Even an observation exception is bracketed by the final authorization.
    local f=fixture(function(x)x.options.read_member=function()
        x.reads=x.reads+1;error('unavailable')
    end end)
    f.denied();assert(f.auths==2 and f.reads==1)
end
do local f=fixture();setmetatable(f.context,{});f.denied();assert(f.auths==0)end
do local f=fixture();f.context.extra=true;f.denied();assert(f.auths==0)end
do local f=fixture();f.context.epoch=1.0;f.denied();assert(f.auths==0)end
for _,edit in ipairs({
    function(o)o.context.stream='limits'end,
    function(o)o.context.scope='wrong'end,
    function(o)o.context.guild=string.rep('0',32)end,
    function(o)o.context.storage=string.rep('A',32)end,
    function(o)o.context.epoch=0 end,
    function(o)o.context.epoch=2147483647 end,
    function(o)o.context.authority=1 end,
    function(o)o.context.session=''end,
    function(o)o.context.camp={}end,
    function(o)o.context.extra=true end,
    function(o)setmetatable(o.context,{})end,
    function(o)o.authorize=nil end,
    function(o)o.read_member=false end,
})do local f=fixture();edit(f.options);assert(Adapter.new(f.options)==nil)end
do -- Reports and per-call input/result objects do not escape into adapter state.
    local f=fixture();local weak=setmetatable({}, {__mode='v'})
    local function run()
        local c=copy(f.context);weak[1]=c;weak[2]=f.result
        assert(f.adapter.owns_key(KEY,c));f.result=nil;f.contexts={}
    end
    run();collectgarbage('collect');collectgarbage('collect');assert(next(weak)==nil)
end
print('priority membership: fresh bracketed ownership, exact context, strict observations, terminal fences')

do local f=fixture();f.options.runtime_guild='changed';assert(f.check())end
do local f=fixture();f.options.runtime_guild=nil;assert(not Adapter.new(f.options))end
