local Probe = dofile(TEST_ROOT..'/experiments/settings_priority_roster.lua')
local function fixture()
    local defs = {ORDER={'Fire','Water','Anyone'}, ANYONE='Anyone',
        value=function(name) return ({Fire=1,Water=2,Anyone=3})[name] end}
    local camps = {{id={}, guild='guild', pals={{key='pal', param={}}}},
        {id={}, guild='foreign', pals={{key='foreign-pal', param={}}}}}
    local ids = {[camps[1].id]='camp1', [camps[2].id]='camp2'}
    local calls = {base=0, pals=0, rank=0}
    local api = {
        camp_id=function(c) return c.id end,
        guid_key=function(id) return ids[id] end,
        camp_guild=function(c) return c.guild end,
        camp_pals=function(c)
            assert(c.guild=='guild', 'foreign roster must not be read')
            calls.pals=calls.pals+1; return c.pals, c.err
        end,
        suitability_rank=function(_, value)
            assert(value~=3, 'Anyone is inert')
            calls.rank=calls.rank+1; return value==1 and 2 or 0
        end,
    }
    api.base_camps=function() calls.base=calls.base+1; api.camps_available=true; return camps end
    return api, defs, camps, calls, ids
end

local function scalar_tree(value, forbidden)
    if type(value) ~= 'table' then
        assert(type(value)=='string' or type(value)=='number' or type(value)=='boolean')
        return
    end
    assert(not forbidden[value] and getmetatable(value)==nil, 'wrapper escaped')
    for k,v in pairs(value) do
        assert(type(k)=='number' or type(k)=='string'); scalar_tree(v, forbidden)
    end
end

do
    local api, defs, camps, calls = fixture()
    api.camps_available=false -- stale status must not veto a fresh sweep
    local r=Probe.read(api, defs, 'guild')
    assert(r.complete and r.scope=='expected_guild' and r.expected_alias=='guild')
    assert(#r.camps==1 and r.observed_camps==2 and r.target_camps==1 and r.foreign_camps==1)
    assert(r.observed_pals==1 and calls.base==1 and calls.pals==1 and calls.rank==2)
    assert(r.camps[1].key=='camp1' and r.camps[1].guild=='guild')
    assert(r.camps[1].pals[1].key=='pal' and r.camps[1].pals[1].capable[1]==true)
    assert(r.camps[1].pals[1].capable[2]==nil)
    scalar_tree(r, {[camps]=true,[camps[1]]=true,[camps[1].pals]=true,
        [camps[1].pals[1]]=true,[camps[1].pals[1].param]=true,[camps[1].id]=true})
    camps[1].pals[1].key='changed'
    assert(r.camps[1].pals[1].key=='pal')
    assert(Probe.read(api,defs,'guild').camps[1].pals[1].key=='changed')
end

local failures = {
    function(a) a.base_camps=function() a.camps_available=false; return {} end end,
    function(a) a.base_camps=function() a.camps_available=nil; return {} end end,
    function(a) a.base_camps=function() error({wrapper=true}) end end,
    function(a) a.base_camps=function() a.camps_available=true; return nil end end,
    function(_,_,c) c[1].id=nil end,
    function(a) a.guid_key=function() return {} end end,
    function(_,_,c) c[2].guild=nil end, -- unknown foreign scope cannot be skipped
    function(_,_,c) c[2].id=nil end,
    function(_,_,c) c[2]=c[1] end,
    function(_,_,c) c[1].err='partial slot enumeration' end,
    function(_,_,c) c[1].pals=nil end,
    function(_,_,c) c[1].pals[2]=c[1].pals[1] end,
    function(_,_,c) c[2].guild='guild'; c[2].pals[1].key='pal' end,
    function(_,_,c) c[1].pals[1].key='slot1' end,
    function(_,_,c) c[1].pals[1].key={} end,
    function(_,_,c) c[1].pals[1].param=nil end,
    function(_,_,c) c[3]=c[2]; c[2]=nil end,
    function(_,_,c) c.extra=true end,
    function(_,_,c) c[1].pals[3]=c[1].pals[1]; c[1].pals[1]=nil end,
    function(_,_,c) c[1].pals.extra=true end,
    function(_,_,c) setmetatable(c,{__len=function() return 0 end}) end,
    function(_,_,c) for i=3,33 do c[i]=c[2] end end,
    function(_,_,c) for i=2,2049 do c[1].pals[i]={key='p'..i,param={}} end end,
    function(_,d) d.ORDER={} end,
    function(_,d) d.ORDER[2]=nil end,
    function(_,d) d.value=function() return 1 end end,
    function(_,d) d.value=function() return {} end end,
    function(a) a.camp_guild=function() error('unavailable') end end,
    function(a) a.camp_pals=function() error('unavailable') end end,
    function(a) a.suitability_rank=function() error('unavailable') end end,
}
for i,edit in ipairs(failures) do
    local a,d,c=fixture(); edit(a,d,c)
    local r=Probe.read(a,d,'guild'); assert(not r.complete,'failure fixture '..i)
    scalar_tree(r,{})
end
for _,rank in ipairs({false,'1',{},-1,0/0,math.huge,-math.huge,0.5}) do
    local a,d=fixture(); a.suitability_rank=function() return rank end
    assert(not Probe.read(a,d,'guild').complete)
end
do local a,d=fixture(); a.suitability_rank=function() return nil end
    assert(not Probe.read(a,d,'guild').complete) end
for _,alias in ipairs({'','slot1',{},false,'0-0-0-0'}) do
    local a,d,_,calls=fixture(); assert(not Probe.read(a,d,alias).complete and calls.base==0)
end
do local a,d=fixture(); assert(not Probe.read(a,d,nil).complete) end
do local a,d,c=fixture(); c[1].pals={}; local r=Probe.read(a,d,'guild')
    assert(r.complete and #r.camps[1].pals==0) end
do local a,d,c=fixture(); c[1]=nil;c[2]=nil
    assert(Probe.read(a,d,'guild').complete) end
do local a,d,c=fixture(); c[1].guild='foreign'
    local r=Probe.read(a,d,'guild'); assert(r.complete and #r.camps==0 and r.foreign_camps==2) end
do -- The global Pal budget applies across target camps, before reading ranks.
    local a,d,c=fixture(); c[2].guild='guild'; c[3]={id={},guild='guild',pals={{key='overflow',param={}}}}
    local old=a.guid_key; a.guid_key=function(id) return old(id) or 'camp3' end
    for i=1,2 do for j=1,2048 do c[i].pals[j]={key='p'..i..'-'..j,param={}} end end
    local r=Probe.read(a,d,'guild'); assert(not r.complete and r.observed_pals==4096)
end
do -- Weak references prove the module/report retain no input objects on success or failure.
    for _,fail in ipairs({false,true}) do
        local weak=setmetatable({}, {__mode='v'})
        local function run()
            local a,d,c=fixture()
            weak[1]=a; weak[2]=d; weak[3]=c; weak[4]=c[1]; weak[5]=c[1].id
            weak[6]=c[1].pals[1]; weak[7]=c[1].pals[1].param
            if fail then a.suitability_rank=function() error(c[1]) end end
            return Probe.read(a,d,'guild')
        end
        local report=run(); collectgarbage('collect'); collectgarbage('collect')
        assert(next(weak)==nil, 'input retained'); assert(report.complete==not fail)
    end
end
print('priority roster: scoped, bounded, fail-closed scalar reads; no wrapper retention')
