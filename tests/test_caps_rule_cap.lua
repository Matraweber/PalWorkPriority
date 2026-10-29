-- A guild's view holds at most 500 limits (MAX_RULES, the R snapshot bound),
-- and the caps.txt header (2026-10-28) round-trips while old headers load.
-- Audit 2026-10-28 A6: rule 501 left every member "connecting" for good.
package.loaded.log={warn=function() end,say=function() end,error=function() end,debug=function() end}
package.loaded.caps=nil;package.loaded.datafile=nil
local fs=require('memory_fs')()
require('datafile').fs=fs
local caps=require('caps')
local status=require('panel_status')

-- Header: fixed comment lines, each starting with '#' and ending with '\n'.
local header=caps.HEADER
assert(header=='# Production limits. Mining limits stop only the rocks of their item; every other limit switches its whole work type.\n'
    ..'# guild|work|item|limit (OFF hides an inherited limit for this guild)\n')
for line in header:gmatch('([^\n]*)\n') do assert(line:sub(1,1)=='#','header line is not a comment') end
assert(header:sub(-1)=='\n' and not header:find('legacy',1,true) and not header:find('Legacy',1,true))
local body=assert(caps.serialize_snapshot({['guild-A']={Mining={Stone=100,Ore=false}},['*']={Deforest={Wood=5}}}))
assert(body:sub(1,#header)==header,'serialized file does not start with the header')
local decoded=assert(caps.decode_snapshot(body))
assert(decoded.count==3 and decoded.data['guild-A'].Mining.Stone==100 and decoded.data['guild-A'].Mining.Ore==false)
assert(caps.serialize_snapshot(decoded.data)==body,'header round trip is not stable')
-- A file written before the header change still loads, and is rewritten with the new one.
local old='# Legacy work-type groups: may stop unrelated products of the same suitability.\n'
    ..'# guild|work|item|ceiling (OFF masks an inherited group rule for this guild)\n'
    ..'guild-A|Mining|Stone|100\n'
local old_decoded=assert(caps.decode_snapshot(old))
assert(old_decoded.count==1 and old_decoded.data['guild-A'].Mining.Stone==100)
assert(caps.serialize_snapshot(old_decoded.data)==header..'guild-A|Mining|Stone|100\n')
fs.files['old-caps']=old
assert(caps.load('old-caps')==1 and caps.data['guild-A'].Mining.Stone==100,'old header did not load')

-- 500 limits: changing one is fine, a new one is refused with a plain reason.
local rows={}
for i=1,499 do rows[#rows+1]='guild-A|Mining|Item'..i..'|'..i end
rows[#rows+1]='*|Deforest|Wood|50' -- shared limits count: the client receives them too
rows[#rows+1]='guild-B|Mining|Stone|10'
fs.files.caps=table.concat(rows,'\n')..'\n'
caps.configure{work_caps={}}
assert(caps.load('caps')==501)
caps.set_role('authority',1)
local function count(guild)
    local n=0
    for _,items in pairs(caps.all({work_caps={}},guild)) do for _ in pairs(items) do n=n+1 end end
    return n
end
assert(count('guild-A')==500)
local ok,why=caps.apply_set('Mining','Item500',1,'guild-A')
assert(not ok and why=='too_many_limits','501st limit accepted: '..tostring(why))
assert(caps.data['guild-A'].Mining.Item500==nil and count('guild-A')==500)
assert(status.plain_reason(caps.error)=='This guild already has 500 limits. Remove one first.')
assert(caps.apply_set('Mining','Item1',777,'guild-A'),'changing an existing limit was refused')
assert(caps.apply_set('Deforest','Wood',60,'guild-A'),'overriding a shared limit is not a new one')
assert(caps.apply_set('Mining','Item500',1,'guild-B'),'another guild was blocked by guild-A')
-- A config default counts as well, since the client receives it too.
caps.configure{work_caps={Watering={Water=5}}}
assert(select(2,caps.apply_set('Mining','Item500',1,'guild-A'))=='too_many_limits')
caps.configure{work_caps={}}
-- Removing one makes room again.
assert(caps.apply_clear('Mining','Item2','guild-A'))
assert(caps.apply_set('Mining','Item500',1,'guild-A'),'no room after removing a limit')
assert(select(2,caps.apply_set('Mining','Item501',1,'guild-A'))=='too_many_limits')
-- An OFF mask hides a shared limit; setting it again counts as new.
assert(caps.apply_clear('Deforest','Wood','guild-A'))
assert(count('guild-A')==499 and caps.data['guild-A'].Deforest.Wood==false)
assert(caps.apply_set('Mining','Item501',1,'guild-A'))
assert(select(2,caps.apply_set('Deforest','Wood',70,'guild-A'))=='too_many_limits')

-- 2026-10-29 round 2: a file whose guild view holds more than 500 limits
-- still loads (DECISIONS), but the log says that guild's players cannot sync.
local warnings={}
package.loaded.log.warn=function(m) warnings[#warnings+1]=m end
local before=caps.load('caps')
assert(before>500 and count('guild-A')==500 and #warnings==0,'a view of exactly 500 limits warned')
local big={}
for i=1,501 do big[#big+1]='guild-C|Mining|Item'..i..'|'..i end
big[#big+1]='guild-D|Mining|Stone|10'
big[#big+1]='guild-E|Mining|Item1|OFF'
fs.files['big-caps']=table.concat(big,'\n')..'\n'
assert(caps.load('big-caps')==503,'an oversized file was refused')
assert(caps.data['guild-C'].Mining.Item501==501,'the oversized guild lost its limits')
assert(#warnings==1 and warnings[1]:find('guild guild-C holds 501 limits, more than 500',1,true)
    and warnings[1]:find('Connecting to server...',1,true),'no warning for the oversized guild: '..tostring(warnings[1]))
-- Shared limits over the bound reach every guild: said once, not per guild.
local shared={}
for i=1,501 do shared[#shared+1]='*|Mining|Item'..i..'|'..i end
shared[#shared+1]='guild-D|Mining|Stone|10'
fs.files['shared-caps']=table.concat(shared,'\n')..'\n'
warnings={}
assert(caps.load('shared-caps')==502 and #warnings==1 and warnings[1]:find('every guild',1,true))
-- Review round 3: at startup caps.txt loads before config.lua, and config
-- work_caps reach the client too. 499 file limits plus 2 from config.lua are
-- 501, said once config.lua is read; nothing is said before.
package.loaded.caps=nil
local fresh_caps=require('caps')
local near={}
for i=1,499 do near[#near+1]='guild-F|Mining|Item'..i..'|'..i end
fs.files['near-caps']=table.concat(near,'\n')..'\n'
warnings={}
assert(fresh_caps.load('near-caps')==499 and #warnings==0,'warned before config.lua was read')
fresh_caps.configure{work_caps={Watering={Water=5},Deforest={Wood=9}}}
assert(#warnings==1 and warnings[1]:find('guild guild-F holds 501 limits',1,true),
    'config.lua limits were not counted: '..tostring(warnings[1]))
package.loaded.caps=caps
package.loaded.log.warn=function() end
assert(caps.load('caps')==before and count('guild-A')==500)
caps.set_role('authority',1)

-- Over the network: the 501st Set is rejected with that reason and the
-- client stays ready with its 500 limits.
local file=assert(io.open(TEST_ROOT..'/tests/test_net_commit_errors.lua','rb'))
local source=file:read('*a');file:close()
local boundary=assert(source:find('\nlocal f=fixture(false)',1,true))
local fixture=assert(load(source:sub(1,boundary-1)..'\nreturn fixture','transport fixture'))()
local f=fixture(false)
local normal=f.server.on_command
f.server.on_command=function(command,_,comp)
    local p=f.server.split(command)
    if p[1]=='PWP_Set' then
        local saved,reason=caps.apply_set(p[2],p[3],p[4],comp.guild)
        if saved then assert(f.server.push_rules(caps,{},comp)) end
        return saved,reason
    end
    return normal(command,0,comp)
end
assert(f.server.push_rules(caps,{},f.component));f.to_client()
assert(#f.view==500 and f.client.status=='ready')
assert(f.client.request('set','Mining','Item999',5))
f.to_server();f.to_client()
assert(f.events[#f.events].status=='rejected' and f.events[#f.events].reason=='too_many_limits',
    'reason lost on the wire: '..tostring(f.events[#f.events].reason))
assert(f.client.status=='ready' and #f.view==500,'client left ready after a refused limit')
assert(status.plain_reason(f.events[#f.events].reason)=='This guild already has 500 limits. Remove one first.')
assert(f.client.request('set','Mining','Item1',778));f.to_server();f.to_client()
assert(f.events[#f.events].status=='accepted' and f.client.status=='ready','edit after refusal failed')
print('caps: 501st limit refused with too_many_limits, edits and other guilds unaffected, client stays ready; header round trip and old headers load')
