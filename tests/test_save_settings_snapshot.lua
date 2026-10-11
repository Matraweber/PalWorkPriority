-- Real production serializers; no filesystem or native backend is involved.
local io_calls=0
package.loaded.log={warn=function() end,error=function() end}
package.loaded.datafile={read=function() io_calls=io_calls+1;error('unexpected IO') end,
    write=function() io_calls=io_calls+1;error('unexpected IO') end}
local Store=require('store')
local Caps=require('caps')
Store.data={palB={[1]=false,[2]=5},palA={[1]=1}}
Store.baseline=true;Store.state='saving';Store.generation=9
local notices=0
Store.on_change=function() notices=notices+1 end
local snapshot=assert(Store.serialize())
assert(snapshot:find('# baseline=vanilla',1,true))
assert(snapshot:find('palB|1|X',1,true))
assert(snapshot:find('palA|1|1',1,true)<snapshot:find('palB|1|X',1,true))
Store.data.palB[1]=3
assert(snapshot:find('palB|1|X',1,true) and Store.serialize():find('palB|1|3',1,true))
Store.data.palB[2]=7
assert(Store.serialize()==nil)
assert(Store.state=='saving' and Store.generation==9)
Caps.data={guildA={Mining={Stone=false,Ore=250}}}
Caps.remote={guildA={Mining={Stone=999}}}
Caps.state='saving';Caps.generation=7;Caps.on_change=Store.on_change
local limits=assert(Caps.serialize())
assert(limits:find('guildA|Mining|Stone|OFF',1,true))
assert(limits:find('guildA|Mining|Ore|250',1,true))
assert(not limits:find('999',1,true))
Caps.data.guildA.Mining.Ore=100
assert(limits:find('Ore|250',1,true) and Caps.serialize():find('Ore|100',1,true))
Caps.data.guildA.Mining.Ore=-1
assert(Caps.serialize()==nil)
assert(Caps.state=='saving' and Caps.generation==7 and io_calls==0 and notices==0)
-- A plausible large roster exceeds the prototype limit. Do not mistake the
-- successful 64KiB native trial for coverage of all production snapshots.
Store.data={}
for pal=1,300 do
    local key=string.format('%08d-1234567890-1234567890-1234567890',pal)
    Store.data[key]={}
    for work=1,14 do
        if work%6==0 then Store.data[key][work]=false else Store.data[key][work]=work%5+1 end
    end
end
local large=assert(Store.serialize())
assert(#large>65536,'fixture must exceed the actual prototype limit')
local _,disabled=large:gsub('|X\n','')
assert(disabled==600,'large fixture must retain both disabled types per Pal')
assert(Store.state=='saving' and io_calls==0 and notices==0)
print('large roster snapshot bytes='..#large..'; exceeds default transport contract')
print('settings snapshots: immutable X/OFF, stable order, remote exclusion, no IO or premature saved state')
