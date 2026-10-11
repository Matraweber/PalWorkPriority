local path=TEST_ROOT..'/experiments/settings_export_membership_observer.lua'
local Observer=dofile(path)
local A=string.rep('A',64)
local B=string.rep('B',64)
local W,G=string.rep('1',32),string.rep('a',32)
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function fixture(module,edit)
    local f={reads=0,factories=0,lookups=0,args={}}
    f.context={scope='PWP-SCOPE-1:'..W..':'..G..':priorities',storage=W,guild=G,stream='priorities',
        session='boot',incarnation='inc',epoch=1,camp='camp',authority=true}
    f.options={manifest_sha256=string.rep('a',64),keys={A,B},context=copy(f.context),
        read_context=function()
            f.reads=f.reads+1
            if f.on_read then f.on_read()end
            return copy(f.context)
        end,
        reader_factory=function(k,c)
            f.factories=f.factories+1;f.args[#f.args+1]=c
            if f.on_factory then return f.on_factory(k,c)end
            local r={}
            r.owns_key=function(key,ctx)
                assert(key==k and ctx~=c)
                f.lookups=f.lookups+1;f.args[#f.args+1]=ctx
                if f.on_lookup then return f.on_lookup(key,ctx,r)end
                return true
            end
            return r
        end}
    if edit then edit(f)end
    f.observer=assert((module or Observer).new(f.options))
    return f
end
local function no_grants(r)
    for _,k in ipairs({'ownership_verified','membership_verified','history_coverage_verified',
        'retained_history_complete','deletion_coverage_verified','deletion_allowed',
        'activation_allowed','replacement_allowed','storage_grant','authority_grant','coverage_grant'})do
        assert(r[k]==false,k)
    end
end
do
    local f=fixture();assert(f.reads==0 and f.factories==0)
    local r=f.observer.sample();no_grants(r)
    assert(r.complete and not r.fenced and r.manifest_sha256==f.options.manifest_sha256)
    assert(#r.keys==2 and r.keys[1].key==A and r.keys[2].key==B)
    assert(r.keys[1].status=='current_target_confirmed' and r.keys[2].status=='current_target_confirmed')
    assert(f.reads==8 and f.factories==2 and f.lookups==2)
    assert(f.observer.sample()==nil and f.reads==8)
end
do -- Constructor copies keys/context and captures provider functions.
    local f=fixture();f.options.keys[1]=B;f.options.context.epoch=3
    f.options.reader_factory=function()error('replacement')end
    assert(f.observer.sample().keys[1].status=='current_target_confirmed')
end
for _,bad in ipairs({'',string.rep('A',64),string.rep('a',63),string.rep('a',65),false,{}})do
    local f=fixture();f.options.manifest_sha256=bad;assert(not Observer.new(f.options))
end
for _,keys in ipairs({{B,A},{A,A},{[2]=A},{A,extra=B},{string.rep('a',64)},
    {string.rep('A',32)..string.rep('0',32)}})do
    local f=fixture();f.options.keys=keys;assert(not Observer.new(f.options))
end
do
    local f=fixture();f.options.keys={}
    for i=1,257 do f.options.keys[i]=string.format('%064X',i)end
    assert(not Observer.new(f.options))
    f.options.keys[257]=nil;f.observer=assert(Observer.new(f.options))
    local full=f.observer.sample()
    assert(full.complete and #full.keys==256 and f.factories==256 and f.lookups==256)
    for _,row in ipairs(full.keys)do assert(row.status=='current_target_confirmed')end
    no_grants(full)
    f.reads=0
    f.options.keys={};f.observer=assert(Observer.new(f.options))
    local r=f.observer.sample();assert(r.complete and #r.keys==0 and f.reads==2)
end
for _,edit in ipairs({function(c)c.authority=false end,function(c)c.epoch=1.0 end,
    function(c)c.extra=true end,function(c)c.guild=string.rep('0',32)end,
    function(c)c.scope='wrong'end,function(c)setmetatable(c,{})end})do
    local f=fixture();edit(f.options.context);assert(not Observer.new(f.options))
end
for _,mode in ipairs({'false','truthy','throw','factory_throw','invalid_reader'})do
    local f=fixture()
    if mode=='factory_throw' or mode=='invalid_reader' then
        f.on_factory=function(k)
            if k==A then if mode=='factory_throw'then error({})else return {}end end
            return {owns_key=function()return true end}
        end
    else
        f.on_lookup=function(k)
            if k==B then return true end
            if mode=='throw'then error({})end
            return mode=='truthy' and 1 or false
        end
    end
    local r=f.observer.sample();no_grants(r)
    assert(r.complete and r.keys[1].status=='unresolved' and r.keys[2].status=='current_target_confirmed',mode)
end
do -- A real terminally rejected Membership adapter cannot poison the next key.
    local Membership=dofile(TEST_ROOT..'/experiments/settings_priority_membership.lua')
    local f=fixture();local adapters={}
    f.on_factory=function(key,c)
        local adapter=assert(Membership.new{enabled=true,context=c,runtime_guild=G,
            authorize=function()return true end,
            read_member=function(k)
                if key==A then return nil end
                return {complete=true,key=k,group=G,world_resolved=true,in_guild=true}
            end})
        adapters[#adapters+1]=adapter
        return adapter
    end
    local r=f.observer.sample()
    assert(r.complete and not r.fenced and #adapters==2 and adapters[1]~=adapters[2])
    assert(adapters[1].status().state=='revoked' and adapters[2].status().state=='active')
    assert(r.keys[1].status=='unresolved' and r.keys[2].status=='current_target_confirmed')
    no_grants(r)
end
local function late_change(module)
    local f=fixture(module)
    f.on_lookup=function(k)if k==B then f.context.epoch=2 end;return true end
    local r=f.observer.sample()
    assert(r.fenced and not r.complete)
    assert(r.keys[1].status=='unresolved','earlier confirmation survived lifecycle change')
    assert(r.keys[2].status=='unresolved')
end
late_change()
for boundary=1,8 do
    local f=fixture();f.on_read=function()if f.reads==boundary then f.context.session='changed'end end
    local r=f.observer.sample();assert(r.fenced and not r.complete)
    for _,row in ipairs(r.keys)do assert(row.status~='current_target_confirmed')end
    if boundary<=2 then assert(f.factories==0 and r.keys[1].status=='not_examined')end
end
for _,mode in ipairs({'mutation','retained','metatable','reenter','reader_replace','read_throw'})do
    local f=fixture()
    f.on_lookup=function(k,c,r)
        if mode=='mutation'then c.guild=W
        elseif mode=='retained'then f.args[1].epoch=9
        elseif mode=='metatable'then setmetatable(c,{})
        elseif mode=='reenter'then assert(f.observer.sample()==nil)
        elseif mode=='reader_replace'then r.owns_key=function()return true end
        elseif mode=='read_throw'then f.on_read=function()error({})end end
        return true
    end
    local r=f.observer.sample();assert(r.fenced and f.factories==1,mode)
    assert(r.keys[1].status=='unresolved' and r.keys[2].status=='not_examined',mode)
end
do -- Factory callbacks are covered too, even when they throw afterwards.
    local f=fixture();f.on_factory=function(_,c)c.epoch=2;error({})end
    local r=f.observer.sample();assert(r.fenced and f.factories==1 and f.lookups==0)
end
do -- A factory cannot silently return the same terminal adapter for later keys.
    local f=fixture();local reader={owns_key=function()return true end}
    f.on_factory=function()return reader end
    local r=f.observer.sample();assert(r.fenced and r.reason=='reader_reused')
    assert(r.keys[1].status=='unresolved')
end
do -- Keep returned context references checked through the final boundary.
    local f=fixture();local first=copy(f.context)
    f.options.read_context=function()f.reads=f.reads+1;return f.reads==1 and first or copy(f.context)end
    f.observer=assert(Observer.new(f.options))
    f.on_lookup=function()first.camp='changed';return true end
    assert(f.observer.sample().fenced)
end
do -- Negative control: removing revocation must kill the actual late-change test.
    local file=assert(io.open(path,'rb'));local source=file:read('*a');file:close()
    local mutant,n=source:gsub("if row.status=='current_target_confirmed'then row.status='unresolved' end",'-- removed revocation')
    assert(n==1)
    local altered=assert(load(mutant,'@membership-revocation-mutant','t',_ENV))()
    local ok,why=pcall(late_change,altered)
    assert(not ok and tostring(why):find('earlier confirmation survived lifecycle change',1,true))
end
