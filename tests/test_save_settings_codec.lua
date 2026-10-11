package.loaded.datafile={read=function() error('IO') end,write=function() error('IO') end}
package.loaded.log={warn=function() error('log') end,error=function() error('log') end}
local Store,Caps=require('store'),require('caps')
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local W,G,H=string.rep('a',32),string.rep('b',32),string.rep('c',32)
local options={storage=W,guild=G,stream='priorities'}
local c=Codec.new(options)
local body=assert(Store.serialize_snapshot({pal={[1]=false,[2]=3}},true))
local encoded=assert(c.encode(body));local decoded=assert(c.decode(encoded))
assert(decoded.baseline and decoded.data.pal[1]==false and decoded.data.pal[2]==3)
options.storage=H;options.guild=H;options.stream='limits';options.max_payload_bytes=262144
assert(c.supported(encoded),'mutable options changed captured codec')
local function reject(codec,bytes) assert(not codec.supported(bytes)) end
reject(c,encoded:gsub('PWP%-SETTINGS%-1','PWP-SETTINGS-2',1))
reject(c,encoded:gsub(W,H,1));reject(c,encoded:gsub(G,H,1))
reject(c,encoded:sub(1,-2));reject(c,encoded..'x');reject(c,body)
reject(c,encoded:gsub('\npriorities\n','\nlimits\n',1))
reject(c,encoded:gsub('\n(%d+)\n','#bad#',1))
reject(c,encoded:gsub('\n(%d+)\n','\n0%1\n',1))
reject(c,encoded:gsub('\n(%d+)\n','\n999999999999999999999999\n',1))
for _,bad in ipairs({'','# Future version: entire data is in comments\n',body..'# unknown metadata\n',
    body:gsub('pal|2|3','pal|2|03'),body:gsub('pal','slot1')}) do
    assert(not c.encode(bad),'noncanonical payload admitted')
end
local cap=Codec.new{storage=W,guild=G,stream='limits'}
local capbody=assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=123}}}))
local capencoded=assert(cap.encode(capbody))
assert(cap.decode(capencoded).data[G].Mining.Stone==false)
reject(c,capencoded);reject(cap,encoded)
assert(not cap.encode(Caps.serialize_snapshot({['*']={Mining={Stone=false}}})))
assert(not cap.encode(Caps.serialize_snapshot({[H]={Mining={Stone=1}}})))
assert(not cap.encode(Caps.serialize_snapshot({[G:upper()]={Mining={Stone=1}}})))
assert(c.decode(c.encode(Store.serialize_snapshot({},false))).count==0)
assert(cap.decode(cap.encode(Caps.serialize_snapshot({}))).count==0)
for _,bad in ipairs({false,true,'65536',0,65535,262145,math.huge,65536.5}) do
    assert(not pcall(Codec.new,{storage=W,guild=G,stream='priorities',max_payload_bytes=bad}))
end
-- Envelope overhead counts against the negotiated limit, not just the body.
local rows={}
local n=math.floor((65536-#Store.serialize_snapshot({},false)-20)/11)
for i=1,n do rows[string.format('p%05d',i)]={[1]=1} end
local near=assert(Store.serialize_snapshot(rows,false))
assert(#near<=65536 and not c.encode(near))
local larger=Codec.new{storage=W,guild=G,stream='priorities',max_payload_bytes=262144}
local large=assert(larger.encode(near));assert(larger.decode(large).count==n)
reject(c,large)
-- The actual queue must reject a valid-checksum unknown envelope, not just a
-- corrupt record. Never fall back to older settings or start a write.
local owner=Scope.new(W,G,'priorities').key
local function record(generation,payload)
    local text=string.format('PWP-SCRATCH-1:%d:%s:%d:%s',#owner,owner,generation,payload)
    local h=2166136261
    for i=1,#text do h=((h~text:byte(i))*16777619)&0xffffffff end
    return {session=owner,generation=generation,payload=payload,checksum=string.format('%08x',h)}
end
local unknown=encoded:gsub('PWP%-SETTINGS%-1','PWP-SETTINGS-2',1)
local foreign=record(2,encoded);foreign.session='foreign-owner'
for _,records in ipairs({{record(1,encoded),record(2,unknown)},{record(2,unknown),record(1,encoded)},
    {record(1,encoded),foreign},{foreign,record(1,encoded)}}) do
  for _,label in ipairs({'ok','invalid','missing'}) do
    local reads,writes=0,0
    local q=Queue.new({start_read=function() reads=reads+1;return true end,
        start=function() writes=writes+1;return true end,
        poll=function(ticket) local r=records[reads]
            return {ticket=ticket,success=true,read={status=r.generation==2 and label or 'ok',record=r}} end},
        owner,'boot',{validate_payload=c.supported})
    assert(q:recover());q:poll();if q.state=='recovering' then q:poll() end
    assert(q.state=='error' and not q.recovered_payload and writes==0)
    assert(not pcall(q.submit,q,encoded))
  end
end
print('typed settings codec: schema/scope/length/canonical-body gates, X/OFF and real queue no-fallback regression passed')
