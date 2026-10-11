-- Real production formatters, pure partitioner, forbidden filesystem boundary.
local io_calls,notices=0,0
local function no_io() io_calls=io_calls+1;error('unexpected IO') end
package.loaded.datafile={read=no_io,write=no_io}
package.loaded.log={warn=function() end,error=function() end}
local Store,Caps=require('store'),require('caps')
local Partition=dofile(TEST_ROOT..'/experiments/save_partition.lua')
local W,A,B=string.rep('a',32),string.rep('b',32),string.rep('c',32)
Store.data={palA={[1]=false,[8]=2},palB={[1]=5},orphanPal={[1]=false,[8]=4},emptyPal={}}
Store.baseline=true;Store.state='saving';Store.generation=9;Store.path='DO_NOT_WRITE'
Store.decided=true;Store.is_client=false
Caps.data={[A]={Mining={Stone=false,Ore=250}},[B:upper()]={Mining={Stone=400}},
    ['*']={Mining={Stone=100,Ore=false}},['legacy-unknown']={Mining={Stone=false}},
    [string.rep('0',32)]={Mining={Ore=123}}}
Caps.remote={[A]={Mining={Stone=999}}}
Caps.configure({work_caps={Mining={ConfigOnly=555}}})
Caps.state='error';Caps.error='prior failure';Caps.generation=7;Caps.path='DO_NOT_WRITE'
Caps.decided=true;Caps.is_client=false;Caps.session=12
Store.on_change=function() notices=notices+1 end;Caps.on_change=Store.on_change
local snapshot={priorities={data=Store.data,baseline=Store.baseline},limits={data=Caps.data}}
local scope={storage=W:upper()}
local owners={{pal='palA',guild=A:upper(),storage=W},{pal='palB',guild=B,storage=W}}
local full_p,full_c=assert(Store.serialize()),assert(Caps.serialize())
local p=assert(Partition.build(snapshot,scope,owners))
assert(p.verified==false and p.legacy.verified==false and p.legacy.scope==nil)
assert(p.guilds[A].scope.storage==W and p.guilds[A].scope.guild==A and p.guilds[B].verified==false)
local count=0;for _ in pairs(p.guilds) do count=count+1 end;assert(count==2)
local pa,pb,legacy=p.guilds[A],p.guilds[B],p.legacy
assert(pa.records.priorities.data.palA[1]==false and pa.records.priorities.data.palB==nil)
assert(pb.records.priorities.data.palA==nil and pb.records.priorities.data.palB[1]==5)
assert(pa.records.priorities.data.orphanPal==nil and pb.records.priorities.data.orphanPal==nil)
assert(legacy.records.priorities.data.orphanPal[1]==false and legacy.records.priorities.data.emptyPal)
assert(pa.records.limits.data[A].Mining.Stone==false and pa.records.limits.data['*']==nil)
assert(next(pb.records.limits.data)==nil)
assert(legacy.records.limits.data[B:upper()].Mining.Stone==400)
assert(not pb.payloads.limits:find(B:upper(),1,true),'noncanonical group advertised as runtime-ready')
assert(legacy.records.limits.data['*'].Mining.Ore==false)
assert(legacy.records.limits.data['legacy-unknown'].Mining.Stone==false)
assert(legacy.records.limits.data[string.rep('0',32)].Mining.Ore==123)
assert(pa.payloads.priorities:find('palA|1|X\n',1,true))
assert(legacy.payloads.priorities:find('orphanPal|1|X\n',1,true))
assert(pa.payloads.limits:find(A..'|Mining|Stone|OFF\n',1,true))
assert(legacy.payloads.limits:find('*|Mining|Ore|OFF\n',1,true))
assert(not pa.payloads.limits:find('999',1,true) and not pa.payloads.limits:find('ConfigOnly',1,true))
-- Union equals full real serializer output: each legacy row occurs exactly once.
local function rows(text)
    local out={}
    for line in text:gmatch('[^\n]+') do if line:sub(1,1)~='#' then out[#out+1]=line end end
    table.sort(out);return table.concat(out,'\n')
end
for stream,full in pairs({priorities=full_p,limits=full_c}) do
    assert(rows(pa.payloads[stream]..pb.payloads[stream]..legacy.payloads[stream])==rows(full))
end
for _,part in ipairs({pa,pb,legacy}) do
    assert(part.records.priorities.baseline==true)
    assert(part.payloads.priorities==Store.serialize_snapshot(part.records.priorities.data,true))
    assert(part.payloads.limits==Caps.serialize_snapshot(part.records.limits.data))
end
assert(Store.serialize()==full_p and Caps.serialize()==full_c,'full serialization changed')
-- Missing ownership is preserved, not guessed from the guilds/caps that exist.
local none=assert(Partition.build(snapshot,scope,{}))
assert(none.legacy.records.priorities.data.palA and none.legacy.records.priorities.data.palB)
assert(next(none.guilds[A].records.priorities.data)==nil)
-- Claims for currently absent Pals neither delete records nor create empty guild writes.
local absent=assert(Partition.build(snapshot,scope,{{pal='not-loaded',guild=string.rep('d',32),storage=W}}))
assert(absent.guilds[string.rep('d',32)]==nil and absent.legacy.records.priorities.data.orphanPal)
local function reject(s,c,o)
    local ok,value,why=pcall(Partition.build,s,c,o)
    assert(ok and value==nil and type(why)=='string','malformed input was not rejected')
    assert(Store.serialize()==full_p and Caps.serialize()==full_c,'rejection changed source')
end
for _,bad in ipairs({'',string.rep('0',32),W..'x','../world','server-name',false,{}}) do
    reject(snapshot,{storage=bad},owners)
end
reject(snapshot,{storage=W,guild=A},owners)
reject(snapshot,scope,{palA=A})
reject(snapshot,scope,{[2]=owners[1]})
reject(snapshot,scope,{owners[1],owners[1]})
reject(snapshot,scope,{owners[1],{pal='palA',guild=B,storage=W}})
for _,bad in ipairs({'*','legacy-guild',string.rep('0',32),'../guild',false,{A,B}}) do
    reject(snapshot,scope,{{pal='palA',guild=bad,storage=W}})
end
reject(snapshot,scope,{{pal='palA',guild=A,storage=B}})
reject(snapshot,scope,{{pal='slot1',guild=A,storage=W}})
reject(snapshot,scope,{{pal='palA',guild=A,storage=W,verified=true}})
local aliases={priorities={data={},baseline=false},limits={data={
    [A]={Mining={Stone=100}},[A:upper()]={Mining={Ore=200}}}}}
reject(aliases,scope,{})
-- Invalid source data fails as a whole, never returns a partial partition.
for _,bad in ipairs({0,6,1.5,'1',{},function() end}) do
    reject({priorities={data={palA={[1]=bad}},baseline=true},limits={data={}}},scope,owners)
end
for _,bad in ipairs({0,10000000,'100',{},function() end}) do
    reject({priorities={data={},baseline=false},limits={data={[A]={Mining={Stone=bad}}}}},scope,{})
end
reject({priorities={data={},baseline=false},limits={data={['bad/path']={}}}},scope,{})
reject({priorities={data={},baseline=false},limits={data={[A]={Unknown={Stone=10}}}}},scope,{})
reject({priorities={data={},baseline=false},limits={data={[A]={Unknown={}}}}},scope,{})
reject({priorities={data={},baseline=false},limits={data={[A]={['']={}}}}},scope,{})
-- Empty valid groups are harmless preserved records; noncanonical GUID spelling
-- alone cannot create a canonical guild payload, and aliases still fail above.
local case_only=assert(Partition.build({priorities={data={},baseline=false},
    limits={data={[B:upper()]={Mining={Stone=false}}}}},{storage=W},{}))
assert(next(case_only.guilds)==nil and case_only.legacy.records.limits.data[B:upper()].Mining.Stone==false)
assert(case_only.legacy.payloads.limits:find(B:upper()..'|Mining|Stone|OFF\n',1,true))
local empty=assert(Partition.build({priorities={data={},baseline=false},
    limits={data={[A]={Mining={}}}}},{storage=W},{}))
assert(empty.guilds[A].records.limits.data[A].Mining and rows(empty.guilds[A].payloads.limits)=='')
local meta_calls=0
local proxy=setmetatable({}, {__pairs=function() meta_calls=meta_calls+1;error('native') end,
    __index=function() meta_calls=meta_calls+1;error('native') end})
reject(snapshot,proxy,owners);reject(snapshot,scope,proxy)
reject({priorities={data={palA=proxy},baseline=true},limits={data={}}},scope,{})
assert(meta_calls==0)
-- Snapshot strings never change; detached mutable records cannot change inputs
-- or another partition. Subsequent captures reflect subsequent input edits.
local saved_p,saved_c=pa.payloads.priorities,pa.payloads.limits
Store.data.palA[1]=3;Caps.data[A].Mining.Stone=888
owners[1].guild=B;scope.storage=B;snapshot.priorities.baseline=false
assert(pa.records.priorities.data.palA[1]==false and pa.records.limits.data[A].Mining.Stone==false)
assert(pa.scope.storage==W and pa.scope.guild==A and pa.records.priorities.baseline)
assert(pa.payloads.priorities==saved_p and pa.payloads.limits==saved_c)
pa.records.priorities.data.palA[8]=5;pa.records.limits.data[A].Mining.Ore=999
assert(Store.data.palA[8]==2 and Caps.data[A].Mining.Ore==250)
assert(pa.payloads.priorities==saved_p and pa.payloads.limits==saved_c)
assert(legacy.records.limits.data[B:upper()].Mining.Stone==400)
local fresh=assert(Partition.build(snapshot,{storage=W},{{pal='palA',guild=A,storage=W}}))
assert(fresh.guilds[A].payloads.priorities:find('palA|1|3\n',1,true))
assert(not fresh.guilds[A].payloads.priorities:find('# baseline=vanilla',1,true))
assert(Store.state=='saving' and Store.generation==9 and Store.baseline==true and Store.path=='DO_NOT_WRITE')
assert(Store.decided and not Store.is_client and Store.on_change~=nil)
assert(Caps.state=='error' and Caps.error=='prior failure' and Caps.generation==7 and Caps.session==12)
assert(Caps.path=='DO_NOT_WRITE' and Caps.decided and not Caps.is_client and Caps.on_change==Store.on_change)
assert(Caps.remote[A].Mining.Stone==999 and io_calls==0 and notices==0)
print('partition: two guilds, orphan/X, wildcard/OFF provenance, row conservation, rejected ambiguity, immutable payloads and no IO/state changes passed')
