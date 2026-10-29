-- Offline RPC fixtures: no native engine, game, filesystem or network access.
local wire = require('protocol')
local time, hook, blocked, up, down, reads, builds, interests, applied
local server, client, comp, tx, owner, value
os.clock = function() return time end
local function at(point)
    if hook then local f=hook; f(point) end
end
local function setup()
    time,hook,blocked,up,down,reads,builds,interests,applied=0,nil,false,{},{},0,0,0,0
    package.loaded.log={warn=function()end,debug=function()end,say=function()end}
    package.loaded.settings_gate={blocked=function()return blocked end,
        status=function()return 'restart_required' end}
    owner={guild='guild-A'}
    tx={GetFullName=function()at('txname');return 'tx-A'end,
        GetOwner=function()at('owner');return owner end,
        GetComponentByClass=function()at('component');return comp end}
    comp={GetFullName=function()at('name');return 'component-A'end,
        GetOuter=function()at('outer');return tx end,
        Notify_RequestClient_int32=function(_,_,msg)down[#down+1]=msg;at('send')end}
    local outgoing={Request_Server_int32=function(_,_,msg)up[#up+1]=msg end}
    FindAllOf=function(class)
        at('discovery')
        return class=='PalNetworkTransmitter' and {tx} or {comp}
    end
    FName=function(s)at('fname');return s end
    local function instance(authority)
        package.loaded.palapi={has_authority=function()return authority end,
            valid=function(o)at('valid');return type(o)=='table'end,
            guild_of=function(o)reads=reads+1;at('guild');return o.guild end,
            cdo=function()at('class');return {}end,
            owned_network_component=function()at('owned');return outgoing end}
        package.loaded.net=nil
        return require('net')
    end
    server,client=instance(true),instance(false)
    server.begin_session(1);client.begin_session(2)
    client.on_snapshot=function()applied=applied+1;return true end
    server.on_command=function(command,_,c)
        assert(command=='PWP_Hello')
        assert(server.push_rules({all=function()return {}end},{},c))
        assert(server.push_pals(function()return {}end,c))
    end
    assert(client.hello())
    assert(server.receive_command(comp,table.remove(up,1),0))
    assert(client.receive_state(table.remove(down,1)))
    assert(server.receive_command(comp,table.remove(up,1),0))
    for _,msg in ipairs(down)do assert(client.receive_state(msg))end
    down={}
    assert(client.status=='ready' and applied==1)
    value={scope='camp',camp='camp-A',choices={'camp-A','camp-B'},verified=true,
        totals={Stone=123,Wood=0},age_ms=1000,remaining_ms=29000}
    server.on_storage_interest=function(guild)
        assert(guild=='guild-A');interests=interests+1;at('interest');return true
    end
    server.on_storage_request=function(guild,selected,now)
        assert(guild=='guild-A' and now==time);builds=builds+1;at('build');return value
    end
    client.set_storage_open(true)
end
local function request(selected)
    assert(client.request_stock('guild-A',selected))
    time=time+0.2;client.storage_tick()
    assert(#up==1,'no request or refresh storm')
    local msg=table.remove(up,1)
    assert(server.receive_command(comp,msg,0))
    assert(#down==0 and builds==0,'request synchronously sent/scanned')
    return msg
end
local function beat(deliver)
    time=time+0.1
    local before=#down
    server.storage_tick()
    assert(#down-before<=4,'more than four packets in one beat')
    if deliver~=false then
        local batch=down;down={}
        for _,msg in ipairs(batch)do client.receive_state(msg)end
    end
end
local function finish(selected)
    for _=1,40 do
        beat()
        if client.storage_view('guild-A',selected).verified then return end
    end
    error('no complete stock view')
end

setup()
for i=1,200 do value.totals['FixtureItem'..i]=i end
local original=request(nil)
for _=1,100 do assert(client.request_stock('guild-A',nil))end
assert(#up==0 and interests==1)
beat();assert(not client.storage_view('guild-A',nil).verified,'partial snapshot exposed')
finish(nil)
local view=client.storage_view('guild-A',nil)
assert(view.epoch==2 and view.guild=='guild-A' and view.camp=='camp-A' and view.index==1)
assert(view.totals.Stone==123 and view.totals.Wood==0 and #view.choices==2)
assert(view.expires_at < time+29,'request time not deducted')
assert(reads>=5 and builds==1 and applied==1 and client.status=='ready')
assert(server.storage_stats.component_fallbacks==0)
assert(server.storage_stats.packets==10 and server.storage_stats.transmitter_walks==3)
print(string.format('storage fixture cost: %d items, %d packets, %d transmitter walks, %d component fallback walks, %d build',
    202,server.storage_stats.packets,server.storage_stats.transmitter_walks,
    server.storage_stats.component_fallbacks,server.storage_stats.builds))
time=time+9;client.storage_tick();assert(#up==0,'refresh before ten-second minimum')
for _=1,100 do
    assert(rawequal(view.totals,client.storage_view('guild-A',nil).totals),
        'refresh replaced totals identity and would rebuild the picker cache')
end
view.choices[1]='foreign'
assert(client.storage_view('guild-A',nil).choices[1]=='camp-A')
assert(client.request_stock('guild-A','camp-A')) -- adopting default must keep result
assert(client.storage_view('guild-A','camp-A').verified)
assert(not client.storage_view('foreign','camp-A').verified)
assert(not client.storage_view('guild-A','camp-B').verified)
assert(not server.receive_command(comp,original,0),'replayed request accepted')
assert(not server.receive_command(comp,original:gsub('guild%-A','guild-B'),0))
time=view.expires_at
assert(not client.storage_view('guild-A','camp-A').verified,'expired totals exposed')
assert(client.status=='ready' and applied==1)

-- Count expiry must not remove the confirmed selector/header action. Metadata
-- survives before AND after the heartbeat drops expired wire/count state.
setup();request('camp-A');finish('camp-A')
local function selector_only()
    local expired=client.storage_view('guild-A','camp-A')
    assert(not expired.verified and next(expired.totals)==nil,'stale count leaked')
    assert(expired.scope=='camp' and expired.camp=='camp-A' and expired.index==1)
    assert(#expired.choices==2 and expired.choices[2]=='camp-B','selector lost on expiry')
    return expired
end
time=client.storage_view('guild-A','camp-A').expires_at
selector_only();client.storage_tick();selector_only()
for _=1,100 do
    client.request_stock('guild-A','camp-A');selector_only()
end
assert(#client.storage_view('foreign','camp-A').choices==0,'foreign guild borrowed metadata')
assert(#client.storage_view('guild-A','camp-B').choices==0,'different selection borrowed metadata')
assert(client.request_stock('guild-A','camp-B'))
assert(#client.storage_view('guild-A','camp-B').choices==0,'selection kept old selector')

-- Assembly and whole-request timeouts also retire counts, retain metadata,
-- and cannot change P/R readiness or the UI's explicit selection.
for _,timeout in ipairs({'assembly','request','send_failure'})do
    setup();request('camp-A');finish('camp-A')
    time=time+11
    if timeout=='send_failure' then
        package.loaded.palapi.owned_network_component=function()return nil end
        client.storage_tick()
    else
        client.storage_tick()
        assert(#up==1 and up[1]:match('|camp%-A$'))
        if timeout=='assembly' then
            assert(server.receive_command(comp,table.remove(up,1),0))
            beat() -- four packets of five: incomplete snapshot
            time=time+11
        else time=time+21 end
        client.storage_tick()
    end
    selector_only();assert(client.status=='ready' and applied==1)
end

-- Cached metadata has the same lifecycle fences as counts.
for _,fence in ipairs({'close','session','lock','server_nonce','client_nonce'})do
    setup();request('camp-A');finish('camp-A')
    time=client.storage_view('guild-A','camp-A').expires_at
    client.storage_tick();selector_only()
    if fence=='close' then client.set_storage_open(false);client.set_storage_open(true)
    elseif fence=='session' then client.begin_session(99)
    elseif fence=='lock' then
        assert(client.receive_state(wire.envelope('L',server.local_nonce,client.local_nonce,'guild-A')
            ..'|settings_restart_required'))
    elseif fence=='server_nonce' then client.server_nonce='replaced-server'
    else client.local_nonce='replaced-client' end
    local cleared=client.storage_view('guild-A','camp-A')
    assert(not cleared.verified and #cleared.choices==0 and cleared.camp==nil,
        fence..' did not fence selector metadata')
end

-- Replays are refused and early probes only kept (round 3: the newest one is
-- served once the second has passed), both before any expensive ownership walk.
setup();original=request(nil)
local discovery_count=0
hook=function(p)if p=='discovery'then discovery_count=discovery_count+1 end end
for _=1,100 do
    assert(not server.receive_command(comp,original,0))
    assert(server.receive_command(comp,(original:gsub('|1|%-$','|2|-')),0))
end
hook=nil;assert(discovery_count==0,'rate/replay gate performed an object census')

-- Failed ownership checks are charged too, and cannot spam full censuses.
time=time+2;owner.guild='foreign'
local forged=(original:gsub('|1|%-$','|3|-'))
assert(not server.receive_command(comp,forged,0))
discovery_count=0
hook=function(p)if p=='discovery'then discovery_count=discovery_count+1 end end
for i=1,100 do server.receive_command(comp,(original:gsub('|1|%-$','|'..(i+3)..'|-')),0)end
hook=nil;assert(discovery_count==0)
-- The one request kept from that burst is served a second later, at most one
-- census for it, and the guild is proven again before anything is sent.
down={}
hook=function(p)if p=='discovery'then discovery_count=discovery_count+1 end end
for _=1,30 do beat(false)end
hook=nil
assert(discovery_count<=2 and #down==0,'a kept request skipped the ownership proof')

-- Global queue has an explicit eight-peer cap, independent of negotiated peers.
setup();server.guild_of_sender=function()return 'guild-A'end
for i=1,9 do
    local name='queued-'..i
    local c={GetFullName=function()return name end}
    local peer={server=server.local_nonce,client='client-'..i,guild='guild-A'}
    server.clients[name]=peer
    local msg=wire.envelope('T',peer.server,peer.client,peer.guild)..'|1|-'
    assert(server.receive_command(c,msg,0)==(i<=8))
end
assert(server.storage_stats.queue_peak==8 and interests==8)

-- Other peers can fill the queue during the outer request's native guild read.
setup()
local nested={}
for i=1,8 do
    local name='nested-'..i
    local peer={server=server.local_nonce,client='nested-client-'..i,guild='guild-A'}
    server.clients[name]=peer
    nested[i]={comp={GetFullName=function()return name end,GetOuter=function()return tx end},
        msg=wire.envelope('T',peer.server,peer.client,peer.guild)..'|1|-'}
end
hook=function(p)
    if p=='guild' then
        hook=nil
        for _,entry in ipairs(nested)do assert(server.receive_command(entry.comp,entry.msg,0))end
    end
end
local outer=wire.envelope('T',server.local_nonce,client.local_nonce,'guild-A')..'|1|-'
assert(not server.receive_command(comp,outer,0),'reentrant insertion exceeded eight jobs')
assert(server.storage_stats.queue_peak==8 and interests==8)

-- Complete callback and expensive phases are available to the existing profiler.
setup()
local phases={}
package.loaded.log.perf=true
package.loaded.log.around=function(label,fn,...)
    phases[label]=(phases[label] or 0)+1
    return fn(...)
end
package.loaded.measurement=nil
require('measurement').bind(server,'storage_tick','network storage: complete')
request(nil);finish(nil)
for _,label in ipairs({'complete','request guild','transmitters','sender guild','build','encode','send'})do
    assert(phases['network storage: '..label], 'missing profile phase '..label)
end

-- Fully verified empty inventory is not unavailable.
setup();value.totals={};request('camp-A');finish('camp-A')
assert(next(client.storage_view('guild-A','camp-A').totals)==nil)

-- Complete overflow is unavailable, never a truncated or previous inventory.
setup();request('camp-A');finish('camp-A')
value.totals={};for i=1,wire.MAX_STORAGE_ITEMS+1 do value.totals['Item'..i]=i end
time=time+11;client.storage_tick();assert(#up==1)
assert(server.receive_command(comp,table.remove(up,1),0))
for _=1,40 do beat()end
view=client.storage_view('guild-A','camp-A')
assert(not view.verified and next(view.totals)==nil and #view.choices==2)
assert(client.status=='ready' and applied==1)

-- Default/invalid selected camp with no evidence remains explicit unavailable.
setup();value={scope='camp',choices={},totals={},verified=false,age_ms=0,remaining_ms=0}
request('missing');for _=1,8 do beat()end
assert(not client.storage_view('guild-A','missing').verified and client.status=='ready')

-- A missing selected camp can still publish authoritative selector choices.
setup();value={scope='camp',choices={'camp-A'},totals={},verified=false,age_ms=0,remaining_ms=0}
request('missing');for _=1,8 do beat()end
view=client.storage_view('guild-A','missing')
assert(not view.verified and view.camp==nil and view.choices[1]=='camp-A')

-- If typed component resolution misses, one guarded fallback uses the SAME
-- transmitter census for guild proof (never a second transmitter walk).
setup();tx.GetComponentByClass=function()return nil end
request(nil);finish(nil)
assert(server.storage_stats.packets==5 and server.storage_stats.component_fallbacks==2)
assert(server.storage_stats.transmitter_walks==2)

-- S timeout never invalidates P/R or invokes caps application.
setup();request(nil);beat();time=time+11;client.storage_tick()
assert(client.status=='ready' and applied==1 and not client.storage_view('guild-A',nil).verified)

-- Unsupported S packet kinds must never enter the P/R error/status handler.
for _,kind in ipairs({'U','unknown'})do
    setup();request(nil)
    local bad=wire.envelope(kind,server.local_nonce,client.local_nonce,'guild-A')
        ..'|S|1|camp-A|Ore|1|0'
    assert(not client.receive_state(bad))
    assert(client.status=='ready' and applied==1,'malformed S poisoned P/R readiness')
end

-- Whole request age consumes TTL even when source was fresh at build time.
setup();value.age_ms=0;value.remaining_ms=300;request(nil)
for _=1,10 do beat()end
assert(not client.storage_view('guild-A',nil).verified and client.status=='ready')

-- Close and ABA selections reject delayed old data; reset clears demand too.
setup();request('camp-A');for _=1,8 do beat(false)end
local late=down;down={}
client.set_storage_open(false)
for _,msg in ipairs(late)do assert(not client.receive_state(msg))end
assert(not client.request_stock('guild-A','camp-A'))
client.set_storage_open(true);client.request_stock('guild-A','camp-B')
client.request_stock('guild-A','camp-A')
for _,msg in ipairs(late)do assert(not client.receive_state(msg))end
assert(not client.storage_view('guild-A','camp-A').verified)
client.begin_session(3);time=time+30;client.storage_tick();assert(#up==0)

-- Closing during native client discovery/FName conversion cannot send a stale request.
for _,point in ipairs({'owned','fname'})do
    setup();assert(client.request_stock('guild-A',nil));time=time+0.2
    hook=function(p)if p==point then hook=nil;client.set_storage_open(false)end end
    client.storage_tick();hook=nil
    assert(#up==0,'closed panel sent during '..point)
end

-- Every callback resolves fresh ownership, not just the first callback.
setup();request(nil);beat();owner.guild='guild-B'
for _=1,8 do beat(false)end
assert(#down==0 and not client.storage_view('guild-A',nil).verified)

-- Reentrant lifecycle changes abort lookup/build/send without completing a batch.
for _,point in ipairs({'discovery','valid','class','component','name','outer','owner','guild','build','fname','send'})do
    setup();request(nil)
    local fired=false
    hook=function(p)
        if p==point and not fired then fired=true;server.begin_session(9)end
    end
    beat(false);hook=nil
    assert(fired,'boundary not exercised: '..point)
    assert(#down<2)
    down={};for _=1,4 do beat(false)end
    assert(#down==0,'stale queue survived: '..point)
end

-- Same-session peer replacement also revokes all remaining packets.
setup();request(nil);beat()
local peer=server.clients['component-A']
server.clients['component-A']={server=peer.server,client=peer.client,guild=peer.guild}
for _=1,5 do beat(false)end
assert(#down==0)

-- Settings lock during build emits at most one L and no S.
setup();request(nil)
hook=function(p)if p=='build' then blocked=true end end
beat();hook=nil
assert(client.status=='unavailable' and not client.storage_view('guild-A',nil).verified)
assert(applied==1)

-- Nested pump cannot burst or duplicate a packet.
setup();request(nil)
hook=function(p)if p=='send' then server.storage_tick()end end
finish(nil);hook=nil

-- A newer same-peer request during build wins, even without a session change.
setup();local first=request('camp-A');time=time+2
local second=first:gsub('|1|camp%-A$','|2|camp-B')
hook=function(p)
    if p=='build' then hook=nil;assert(server.receive_command(comp,second,0))end
end
beat(false);assert(#down==0,'superseded build sent a packet')
value.camp='camp-B'
for _=1,8 do beat(false)end
assert(#down>0,'replacement job lost from queue')

-- A burst must stop at ANY packet boundary when a nested callback revokes it.
-- The five-packet fixture guarantees an unsent tail even at boundary four.
for _,change in ipairs({'session','peer','lock','owner','deadline'})do
    for boundary=1,4 do
        setup();request(nil)
        local sent=0
        hook=function(point)
            if point=='send' then
                sent=sent+1
                if sent==boundary then
                    hook=nil
                    if change=='session' then server.begin_session(99)
                    elseif change=='peer' then
                        local p=server.clients['component-A']
                        server.clients['component-A']={server=p.server,client=p.client,guild=p.guild}
                    elseif change=='lock' then blocked=true
                    elseif change=='owner' then owner.guild='foreign'
                    else time=time+10 end
                end
            end
        end
        beat(false);hook=nil
        assert(#down==boundary,change..' did not fence packet '..boundary)
        down={};beat(false)
        assert(#down==0,change..' retained revoked burst tail')
    end
end

-- FName conversion can reenter before the native send at each burst position.
-- A native read may also consume the remaining deadline AFTER loop admission.
for _,point in ipairs({'guild','fname'})do
    setup();request(nil)
    local jumped=false
    hook=function(where)
        if where==point and #down==1 and not jumped then
            jumped=true;time=time+10
        end
    end
    beat(false);hook=nil
    assert(jumped and #down==1,'expired packet escaped '..point..' boundary')
    down={};beat(false);assert(#down==0,'expired burst tail survived')
end

-- FName conversion can reenter before the native send at each burst position.
for boundary=1,4 do
    setup();request(nil)
    local converted=0
    hook=function(point)
        if point=='fname' then
            converted=converted+1
            if converted==boundary then hook=nil;server.begin_session(99)end
        end
    end
    beat(false);hook=nil
    assert(#down==boundary-1,'FName reentry sent stale packet '..boundary)
end

-- Ownership may change after recipient resolution, during build or FName.
setup();request(nil)
hook=function(point)if point=='build' then hook=nil;owner.guild='foreign' end end
beat(false);hook=nil
assert(#down==0,'build ownership revocation sent a packet')
down={};beat(false);assert(#down==0,'revoked build tail survived')
for boundary=1,4 do
    setup();request(nil);local converted=0
    hook=function(point)
        if point=='fname' then
            converted=converted+1
            if converted==boundary then hook=nil;owner.guild='foreign' end
        end
    end
    beat(false);hook=nil
    assert(#down==boundary-1,'FName ownership revocation leaked packet '..boundary)
    down={};beat(false);assert(#down==0,'revoked FName tail survived')
end

-- Final proof failures/throws must fail closed, including the totals packet.
for _,failure in ipairs({'missing','throw'})do
    for boundary=1,4 do
        setup();request(nil);local converted=0;local armed=false
        hook=function(point)
            if point=='fname' then
                converted=converted+1;armed=converted==boundary
            elseif point=='guild' and armed then
                hook=nil
                if failure=='throw' then error('final ownership read failed')end
                owner.guild=nil
            end
        end
        beat(false);hook=nil
        assert(#down==boundary-1,failure..' final proof leaked packet '..boundary)
        down={};beat(false);assert(#down==0,'failed final proof retained tail')
    end
end

-- A newer same-peer request during ANY packet supersedes the remaining burst;
-- its response starts on a later callback and resolves ownership afresh.
for boundary=1,4 do
    setup();request('camp-A')
    local sent=0
    hook=function(point)
        if point=='send' then
            sent=sent+1
            if sent==boundary then
                hook=nil;time=time+2
                assert(client.request_stock('guild-A','camp-B'))
                time=time+0.2;client.storage_tick()
                assert(#up==1 and up[1]:match('|2|camp%-B$'))
                assert(server.receive_command(comp,table.remove(up,1),0))
                value.camp='camp-B'
            end
        end
    end
    beat(false);hook=nil
    assert(#down==boundary,'supersession failed at packet '..boundary)
    local old=down;down={}
    for _,message in ipairs(old)do client.receive_state(message)end
    assert(not client.storage_view('guild-A','camp-B').verified)
    local walks=server.storage_stats.transmitter_walks
    finish('camp-B')
    assert(server.storage_stats.transmitter_walks==walks+2,'replacement skipped fresh callback census')
    assert(client.storage_view('guild-A','camp-B').camp=='camp-B')
end
print('net storage: pacing, complete/empty/overflow, TTL, ownership, lifecycle and P/R isolation passed')
