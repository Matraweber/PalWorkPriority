-- Real parsers/formatters, with all persistence and notification effects forbidden.
local calls=0
local function forbidden() calls=calls+1;error('unexpected persistence effect') end
package.loaded.datafile={read=forbidden,write=forbidden}
package.loaded.log={error=forbidden,warn=forbidden}
local Store,Caps=require('store'),require('caps')
Store.data={untouched={[1]=false}};Store.generation=71;Store.state='saving'
Store.baseline=false;Store.on_change=forbidden;Store.path='do-not-use'
Caps.data={['*']={Mining={Ore=false}}};Caps.remote={server='untouched'}
Caps.generation=19;Caps.state='error';Caps.on_change=forbidden;Caps.path='do-not-use'
local data,limits,remote=Store.data,Caps.data,Caps.remote
local p=assert(Store.serialize_snapshot({pal={[1]=1,[2]=2,[3]=3,[4]=4,[5]=5,[6]=false}},true))
local a=assert(Store.decode_snapshot(p))
assert(a.count==6 and a.baseline==true and a.transient==0)
for i=1,5 do assert(a.data.pal[i]==i) end
assert(a.data.pal[6]==false)
assert(Store.serialize_snapshot(a.data,a.baseline)==p)
local b=assert(Store.decode_snapshot(p));a.data.pal[1]=5
assert(b.data.pal[1]==1,'parser retained mutable shared records')
local c=assert(Caps.serialize_snapshot({['*']={Mining={Stone=false,Ore=250}},guild={Mining={Stone=1}}}))
local parsed=assert(Caps.decode_snapshot(c));assert(parsed.count==3)
assert(parsed.data['*'].Mining.Stone==false and parsed.data.guild.Mining.Stone==1)
assert(Caps.serialize_snapshot(parsed.data)==c)
local again=assert(Caps.decode_snapshot(c));parsed.data['*'].Mining.Ore=1
assert(again.data['*'].Mining.Ore==250)
for _,text in ipairs({'pal|1|X\npal|1|2\n','pal|1|2\npal|1|X\n',
    'pal|1|0\n','pal|1|6\n','pal|1|false\n','pal|65|1\n',
    'slot1|1|X\n','SLOT123|1|2\npal|1|1\n','pal|1|1\nmalformed',
    'pal|1|X\0\n'}) do
    local decoded,why=Store.decode_snapshot(text)
    assert(decoded==nil and type(why)=='string','accepted invalid/scoped-loss priority snapshot')
end
for _,text in ipairs({'guild|Mining|Stone|OFF\nguild|Mining|Stone|1\n',
    'guild|Mining|Stone|1\nguild|Mining|Stone|OFF\n',
    'guild|Mining|Stone|0\n','guild|Unknown|Stone|1\n','guild|Mining|../Stone|1\n',
    'guild|Mining|Stone|OFF\nmalformed','guild|Mining|Stone|OFF\0\n'}) do
    local decoded,why=Caps.decode_snapshot(text)
    assert(decoded==nil and type(why)=='string','accepted invalid limit snapshot')
end
for _,module in ipairs({Store,Caps}) do
    for _,bad in ipairs({false,1,{},string.rep('x',8*1024*1024+1)}) do
        local ok,result,why=pcall(module.decode_snapshot,bad)
        assert(ok and result==nil and type(why)=='string')
    end
end
assert(Store.decode_snapshot('pal|1|X\r\n').data.pal[1]==false)
assert(Caps.decode_snapshot('Mining|Stone|OFF\r\n').data['*'].Mining.Stone==false)
assert(Store.decode_snapshot('').count==0 and Caps.decode_snapshot('').count==0)
-- Empty valid bytes are only a parsing result, NEVER missing-file proof.
assert(Store.data==data and Store.data.untouched[1]==false and Store.generation==71)
assert(Store.state=='saving' and not Store.baseline)
assert(Caps.data==limits and Caps.remote==remote and Caps.generation==19 and Caps.state=='error')
assert(calls==0)
print('snapshot decode: real round-trips, X/OFF, malformed/duplicate/temp-ID/oversize rejection; no IO or state changes')
