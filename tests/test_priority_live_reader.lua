-- Actual live bridge + Membership; engine readers are explicit scalar fixtures.
-- Native marshalling is covered by the separately archived live world probe.
local original=dofile
local W,G=string.rep('1',32),string.rep('2',32)
local K=string.rep('0',32)..string.rep('A',32)
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function fixture()
    local f={contexts=0,guilds=0,parameters=0,auths=0}
    f.c={scope='PWP-SCOPE-1:'..W..':'..G..':priorities',storage=W,guild=G,stream='priorities',
        session='boot',incarnation='inc',epoch=1,camp='camp',authority=true}
    f.s={storage=W,guild=G,alias='alias',legacy_guild='alias',world='world',world_address=1,state_address=2,
        instance_address=3,manager_address=4,player_address=5,controller_address=6,player_state_address=7,guild_address=8}
    _G.dofile=function(path)
        if path:match('/settings_priority_guild_roster.lua$')then return {read=function(_,c,_,visit)
            f.guilds=f.guilds+1;assert(c.world_address==f.s.world_address)
            if f.guild_callback then f.guild_callback(c)end
            if not f.missing then visit(K, {})end
            return {complete=f.guild_complete~=false,keys=f.missing and {} or {K},array_address=9}
        end}end
        if path:match('/settings_priority_parameter_roster.lua$')then return {read=function(_,_,group,keys,resolver)
            f.parameters=f.parameters+1;assert(group==G and keys[K] and type(resolver)=='function')
            if f.parameter_callback then f.parameter_callback()end
            return {complete=f.parameter_complete~=false,requested=1,observed=1,matched=1,
                records={{key=K,group=f.foreign and W or G,matches=true,world_resolved=f.unresolved~=true,
                    address=f.unstable and f.parameters or 10}}}
        end}end
        return original(path)
    end
    local Bridge=original(TEST_ROOT..'/experiments/settings_priority_live_reader.lua')
    _G.dofile=original
    f.o={enabled=true,context=f.c,runtime_guild='alias',
        read_context=function()f.contexts=f.contexts+1;if f.context_callback then f.context_callback()end;return f.s end,
        get_engine=function()return {}end,enumerate=function()error('fixture reader owns enumeration')end,
        api={cdo=function()error('fixture reader owns native call')end,unwrap=function(v)return v end,instance_key=function()end},
        authorize=function(c,a)f.auths=f.auths+1;assert(a=='alias' and c.scope==f.c.scope);return not f.denied end}
    f.bridge=assert(Bridge.new(f.o))
    function f.check()return f.bridge.owns_key(K,copy(f.c))end
    function f.reject()
        assert(not f.check() and f.bridge.status().state=='revoked')
        local a,p,g=f.auths,f.parameters,f.guilds
        assert(not f.check() and f.auths==a and f.parameters==p and f.guilds==g)
    end
    return f
end
do local f=fixture();assert(f.check() and f.contexts==2 and f.guilds==2 and f.parameters==2 and f.auths==2)
    assert(f.check() and f.parameters==4) -- no cached success
    f.missing=true;f.reject();assert(f.parameters==4)end
for _,flag in ipairs({'denied','missing','foreign','unresolved','unstable'})do
    local f=fixture();f[flag]=true;f.reject()
end
for _,flag in ipairs({'guild_complete','parameter_complete'})do local f=fixture();f[flag]=false;f.reject()end
for _,field in ipairs({'storage','guild','world','world_address','state_address','instance_address','manager_address',
    'player_address','controller_address','player_state_address','guild_address','alias','legacy_guild'})do
    local f=fixture();f.context_callback=function()
        if f.contexts==2 then f.s[field]=type(f.s[field])=='number' and 999 or 'changed'end
    end
    f.reject()
end
do local f=fixture();f.guild_callback=function(c)c.world_address=99 end;f.reject()end
do local f=fixture();f.parameter_callback=function()f.bridge.revoke()end;f.reject()end
do local f=fixture();f.parameter_callback=function()assert(not f.check())end;f.reject()end
do local f=fixture();f.parameter_callback=function()error('read failed')end;f.reject()end
do local f=fixture();f.o.read_context=function()error('replaced callback')end;f.o.api.cdo=nil
    assert(f.check())end
do local f=fixture();f.s.world_address=0;f.reject();assert(f.guilds==0)end
print('live membership bridge: fresh paired readers, no cached grant, context changes/missing/foreign/reentry refusal')
