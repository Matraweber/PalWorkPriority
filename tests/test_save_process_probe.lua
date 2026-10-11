local Probe=dofile(TEST_ROOT..'/experiments/save_process_probe.lua')
local id=string.rep('a',32)
local function fixture(options)
    local o=options or {}
    local f={forbidden=0,visits=0,gets=0,lengths=0,breaks=0,wrappers={}}
    local function object(fields,throws)
        local proxy=setmetatable({}, {
            __index=function(_,k)
                if k=='SaveObject' then f.forbidden=f.forbidden+1;error('forbidden SaveObject') end
                if throws and throws[k] then error('unreadable property') end
                if fields[k]~=nil then return fields[k] end
                return nil
            end,
            __newindex=function() f.forbidden=f.forbidden+1;error('native write') end,
            __pairs=function() f.forbidden=f.forbidden+1;error('native enumeration') end})
        f.wrappers[proxy]=true;return proxy
    end
    f.object=object
    function f.param(value,throws)
        return object{get=function() f.gets=f.gets+1;if throws then error('PRIVATE_READ') end;return value end}
    end
    f.rows=o.rows or {{key=id,state=3,pre=false}}
    f.map=setmetatable({}, {__len=function()
        f.lengths=f.lengths+1
        if o.length_throw or (o.after_throw and f.lengths>1) then error('length failure') end
        if f.lengths>1 and o.after~=nil then return o.after end
        if o.count~=nil then return o.count end
        return #f.rows
    end,__index=function(_,k)
        if k=='type' then return function() return o.map_type or 'TMap' end end
        if k~='ForEach' then f.forbidden=f.forbidden+1;error('unexpected map method') end
        return function(_,callback)
            if o.foreach_throw then error('iteration failed') end
            for _,r in ipairs(f.rows) do
                f.visits=f.visits+1
                local process=object({State=r.state,bPreDelegateSuccess=r.pre},r.throws)
                local value=f.param(r.no_process and nil or process,r.value_throw)
                local key=f.param(r.key,r.key_throw)
                local done=callback(key,value)
                if done==true then f.breaks=f.breaks+1;if not o.ignore_break then break end end
            end
        end
    end})
    f.wrappers[f.map]=true
    local valid=function() return true end
    f.process={ProcessMap=f.map}
    f.manager={IsValid=valid,WorldSaveProcess=object(f.process)}
    f.instance={IsValid=valid,SaveGameManager=object(f.manager)}
    f.world={IsValid=valid,OwningGameInstance=object(f.instance)}
    f.viewport={IsValid=valid,World=object(f.world)}
    f.engine_fields={IsValid=valid,GameViewport=object(f.viewport)}
    f.engine=object(f.engine_fields)
    function f.read()
        local out=Probe.read(f.engine)
        assert(out.verified==false and out.ready==nil and out.storage==nil and out.key==nil)
        local function plain(v)
            assert(not f.wrappers[v],'retained native wrapper')
            if type(v)=='table' then
                assert(getmetatable(v)==nil)
                for k,x in pairs(v) do assert(k~='SaveObject');plain(x) end
            else
                assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean')
                if type(v)=='string' then assert(not v:find('PRIVATE',1,true) and #v<=64) end
                if type(v)=='number' then assert(v==v and math.abs(v)<math.huge) end
            end
        end
        plain(out);assert(f.forbidden==0);assert(#out.entries<=16)
        return out
    end
    return f
end
local f=fixture();local out=f.read()
assert(out.status=='observed' and out.count==1 and f.breaks==1)
assert(out.entries[1].candidate==id and out.entries[1].state==3 and out.entries[1].pre_success==false)
-- No retained wrappers: replace the process map and invalidate the old engine.
f.process.ProcessMap=nil;assert(f.read().status=='unavailable')
assert(out.entries[1].state==3 and out.entries[1].candidate==id)
for _,case in ipairs({
    {id:upper(),'guid',id},{'PRIVATE_ACCOUNT/'..id..'/Level','guid_level_path',id},
    {'PRIVATE_ACCOUNT\\'..id..'\\Level.sav','guid_level_path',id},
    {'Level','level_leaf'},{'Level.sav','level_leaf'},{'','empty'},
    {'PRIVATE_NAME','other'},{'../'..id..'/Level','other'},
    {'C:/'..id..'/Level','other'},{'/'..id..'/Level','other'},
    {id..'//Level','other'},{id..'/Level/','other'},{id..'/Level\n','other'},
    {string.rep('0',32),'other'},{string.rep('x',1025),'unavailable'},
    {'g'..id..'/Level','other'}
}) do
    f=fixture({rows={{key=case[1],state=0,pre=true}}});local e=f.read().entries[1]
    assert(e.key_status==case[2],case[2]);assert(e.candidate==case[3])
end
f=fixture({rows={{key={ToString=function() return id end},state=4,pre=true}}})
assert(f.read().entries[1].candidate==id)
for _,r in ipairs({
    {key=id,key_throw=true,state=2,pre=true},
    {key={ToString=function() error('PRIVATE_CONVERSION') end},state=2,pre=true},
    {key=id,value_throw=true}, {key=id,throws={State=true,bPreDelegateSuccess=true}},
    {key=id,state='Saving',pre='true'}, {key=id,state=5,pre=0},
    {key=id,state=-1}, {key=id,state=1.5}, {key=id,state=0/0}, {key=id,state=math.huge}
}) do
    f=fixture({rows={r}});local e=f.read().entries[1]
    if r.key_throw or type(r.key)=='table' then assert(e.key_status=='read_failed') end
    if r.value_throw or r.throws then assert(e.state_status=='read_failed' and e.pre_status=='read_failed')
    elseif type(r.state)~='number' or r.state<0 or r.state>4 or r.state%1~=0 then
        assert(e.state_status=='unknown' and e.state==nil)
    end
end
for state=0,4 do
    f=fixture({rows={{key=id,state=state,pre=false}}});assert(f.read().entries[1].state==state)
end
for _,count in ipairs({-1,1.5,'bad',false,0/0,math.huge}) do
    f=fixture({count=count});assert(f.read().status=='invalid_count' and f.visits==0)
end
f=fixture({map_type='TArray'});assert(f.read().status=='unavailable' and f.visits==0 and f.lengths==0)
f=fixture({count=17});assert(f.read().status=='oversize' and f.visits==0)
f=fixture({count=0});assert(f.read().status=='empty' and f.visits==0)
for _,fault in ipairs({'length_throw','after_throw','foreach_throw'}) do
    f=fixture({[fault]=true});assert(f.read().status=='read_failed')
end
f=fixture({count=2});assert(f.read().status=='incomplete')
f=fixture({after=2});assert(f.read().status=='changed_during_read')
local rows={};for i=1,20 do rows[i]={key=id,state=2,pre=true} end
f=fixture({count=16,after=20,rows=rows});assert(f.read().status=='changed_during_read')
assert(f.visits==16 and f.gets==32 and f.breaks==1)
f=fixture({count=1,rows=rows});assert(f.read().status=='observed' and f.visits==1)
-- Defensive cap also avoids reading a seventeenth pair if a broken mock ignores break.
f=fixture({count=16,after=20,rows=rows,ignore_break=true})
assert(f.read().status=='changed_during_read' and f.gets==32)
for _,part in ipairs({'engine_fields','viewport','world','instance','manager'}) do
    f=fixture();f[part].IsValid=function() return false end
    assert(f.read().status=='unavailable' and f.visits==0)
    f[part].IsValid=function() error('invalid wrapper') end
    assert(f.read().status=='unavailable')
end
for _,edge in ipairs({{'engine_fields','GameViewport'},{'viewport','World'},
    {'world','OwningGameInstance'},{'instance','SaveGameManager'},
    {'manager','WorldSaveProcess'},{'process','ProcessMap'}}) do
    f=fixture();f[edge[1]][edge[2]]=nil
    local status=f.read().status
    assert(status=='unavailable' or status=='read_failed')
    f=fixture();f[edge[1]][edge[2]]=setmetatable({}, {__index=function() error('unavailable') end,__len=function() error('unavailable') end})
    status=f.read().status;assert(status=='unavailable' or status=='read_failed')
end
assert(Probe.read(nil).status=='unavailable')
print('save process probe: API wrappers, bounded counts, early break, privacy, property failures and no SaveObject/proof passed')
