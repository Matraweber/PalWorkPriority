-- Reuse the real transport fixture, with actual Caps admission and memory IO.
local file=assert(io.open(TEST_ROOT..'/tests/test_net_commit_errors.lua','rb'))
local source=file:read('*a');file:close()
local boundary=assert(source:find('\nlocal f=fixture(false)',1,true))
local fixture=assert(load(source:sub(1,boundary-1)..'\nreturn fixture','transport fixture'))()
local f=fixture(false)
local normal=f.server.on_command
package.loaded.caps=nil;package.loaded.datafile=nil;package.loaded.producers=nil
local fs=require('memory_fs')();require('datafile').fs=fs
local caps=require('caps');caps.load('server-caps');caps.configure{work_caps={}}
caps.set_role('authority',1)
f.caps=caps
assert(f.server.push_rules(caps,{},f.component));f.to_client()
assert(#f.view==0 and f.client.status=='ready')
f.server.on_command=function(command,_,comp)
    local p=f.server.split(command)
    if p[1]=='PWP_Set'then
        local ok,reason=caps.apply_set(p[2],p[3],p[4],comp.guild)
        if ok then assert(f.server.push_rules(caps,{},comp))end
        return ok,reason
    end
    return normal(command,0,comp)
end
local before=caps.serialize();local operations=#fs.operations
assert(f.client.request('set','Mining','Stone',35001))
f.to_server();local replies=f.to_client()
assert(f.events[#f.events].status=='rejected' and f.events[#f.events].reason=='unsupported_limit',
    'unsupported limit lost its bounded rejection reason')
assert(#f.view==0 and caps.serialize()==before and #fs.operations==operations and next(fs.files)==nil,
    'rejected unsupported limit mutated settings or wrote files')
assert(f.client.status=='ready' and f.remote_status=='ready', 'rejection poisoned confirmed empty snapshot')
local state,label,hint=require('panel_status').save{view_status=function()return f.remote_status,f.remote_error end}
assert(state=='ready' and label=='Synced with server' and hint:find('no verified output control',1,true))
local events=#f.events
assert(not f.client.receive_state(replies[#replies]),'completed request retained after rejection')
f.advance(9)
assert(#f.events==events and f.client.status=='ready','rejected request later timed out')
assert(f.client.request_prio('PAL-A',1,4));f.advance(.2);f.to_server();f.to_client()
assert(f.client.pals['PAL-A'].prios[1]==4 and f.client.status=='ready' and not f.remote_error)
-- Once a legitimate legacy rule exists, a subsequent limit edit also works.
caps.configure{work_caps={Mining={Stone=100}}}
assert(f.client.request('set','Mining','Stone',200));f.to_server();f.to_client()
assert(f.view[1].amount==200 and caps.data['guild-A'].Mining.Stone==200 and fs.files['server-caps'])
assert(f.events[#f.events].status=='accepted' and f.client.status=='ready' and not f.remote_error)

-- Unknown handler text must never be emitted as a reason, including delimiters.
for _,reason in ipairs({'rejected','private path | injected\nerror','unsupported_limit','no_active_legacy_rule'})do
    f=fixture(false)
    f.server.on_command=function()return false,reason end
    assert(f.client.request('set','Mining','Stone',35001));f.to_server()
    assert(#f.down==1)
    local expected=reason:find('private',1,true) and 'rejected' or reason
    assert(f.server.split(f.down[1])[8]==expected and #f.server.split(f.down[1])==10)
    f.to_client()
    assert(f.events[#f.events].reason==expected and f.client.status=='ready')
end

-- A schema-3 peer may send the old generic code or an unknown diagnostic.
f=fixture(false);f.server.on_command=function()return false end
assert(f.client.request('set','Mining','Stone',35001));f.to_server()
local unknown=f.down[1]:gsub('|rejected|','|private diagnostic|')
assert(f.client.receive_state(unknown))
assert(f.events[#f.events].reason=='rejected' and f.remote_error=='rejected')

-- Rejection cannot make an incomplete snapshot usable.
f=fixture(false);f.server.on_command=function()return false,'unsupported_limit' end
assert(f.client.request('set','Mining','Stone',35001));f.to_server()
local ack=f.down[1];f.down={}
local wire=require('protocol')
local gap=assert(wire.snapshot(f.server.local_nonce,f.client.local_nonce,'guild-A','P',3,'D',
    {'PAL-A|'..string.rep('1',14)..'|'..string.rep('4',14)}))
f.client.receive_state(gap[1]);assert(f.client.status=='connecting')
assert(f.client.receive_state(ack))
assert(f.client.status=='connecting' and f.remote_status=='connecting')
assert(not f.client.request('set','Mining','Stone',200))

-- Reject one request while another is still pending. Its ACK and snapshot
-- must still settle the second request, without an extra send or timeout.
f=fixture(false)
local handler=f.server.on_command
f.server.on_command=function(command,_,comp)
    if command=='PWP_Set|Mining|Ore|35001' then return false,'unsupported_limit' end
    return handler(command,0,comp)
end
assert(f.client.request('set','Mining','Ore',35001))
assert(f.client.request('set','Mining','Stone',200))
f.to_server()
local pending=f.down;f.down={}
assert(f.client.receive_state(pending[1]))
assert(f.events[#f.events].status=='rejected' and f.view[1].amount==100)
local pending_ack=pending[#pending]
assert(f.client.receive_state(pending_ack),'other pending request was discarded by rejection')
assert(f.events[#f.events].status=='acknowledged' and f.view[1].amount==100,
    'other edit settled before its snapshot arrived')
for i=2,#pending-1 do assert(f.client.receive_state(pending[i]))end
assert(f.events[#f.events].status=='accepted' and f.view[1].amount==200)
assert(not f.client.receive_state(pending_ack))
local settled=#f.events;f.advance(9)
assert(#f.events==settled and f.client.status=='ready')

-- A rejection is not a successful save of either stream.
for _,stream in ipairs({'P','R'})do
    f=fixture(false);f.outcome='applied_unsaved'
    if stream=='P'then assert(f.client.request_prio('PAL-A',1,3));f.advance(.2)
    else assert(f.client.request('set','Mining','Stone',200))end
    f.to_server();f.to_client()
    local watermark=assert(f.client.save_failures[stream])
    f.server.on_command=function()return false,'unsupported_limit' end
    assert(f.client.request('set','Mining','Ore',35001));f.to_server();f.to_client()
    assert(f.events[#f.events].reason=='unsupported_limit')
    assert(f.client.save_failures[stream]==watermark and f.client.status=='applied_unsaved')
    assert(f.remote_status=='applied_unsaved' and f.remote_error=='save_failed')
end
print('limit rejection: bounded reason, no writes, confirmed empty snapshot, retry and save-failure retention')
