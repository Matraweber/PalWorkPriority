-- Real transport/protocol/ledger; only persistence and engine endpoints are fake.
-- Reuse the setup, not the assertions, of the synchronous transport regression.
local file=assert(io.open(TEST_ROOT..'/tests/test_net_commit_errors.lua','rb'))
local source=file:read('*a');file:close()
local cut=assert(source:find('\nlocal f=fixture%(false%)'),'fixture boundary changed')
local base=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@deferred-fixture'))()
local wire=require('protocol')
local G,W=string.rep('b',32),string.rep('a',32)
local function fixture(enabled)
    local f=base(nil)
    f.client_api.has_authority=function()return false end
    f.server.begin_session(41)
    f.saved=false;f.body='durable body';f.queries=0;f.publications=0;f.census=0
    f.receipts={};f.query_receipts={}
    FindAllOf=function(class)
        assert(class=='PalNetworkBaseCampComponent')
        f.census=f.census+1
        return f.disconnected and {} or {f.component}
    end
    f.server.pending_owner=function()
        return {guild=G,epoch=f.server.epoch}
    end
    f.server.pending_status=function(stream,r)
        f.queries=f.queries+1;f.query_receipts[#f.query_receipts+1]=r
        local body=f.body
        return {state=f.saved and 'saved' or 'saving',body=body,revision=r.revision,
            request_revision=r.revision},
            function()return f.saved and f.body==body end
    end
    f.server.publish_pending=function(stream,comp,current)
        f.publications=f.publications+1
        if stream=='P' then return f.server.push_pals(f.rows,comp,nil,current) end
        return f.server.push_rules(f.caps,{},comp,current)
    end
    local original=f.server.on_command
    f.server.on_command=function(command,value,comp,token)
        local p=f.server.split(command)
        if p[1]=='PWP_Hello' then return original(command,value,comp,token) end
        f.calls=f.calls+1
        if f.during_mutation then f.during_mutation() end
        local stream=p[1]=='PWP_Prio' and 'P' or 'R'
        if stream=='P' then f.priority=wire.decode_priority(p[4])
        elseif p[1]=='PWP_Clear' then f.amount=nil
        else f.amount=tonumber(p[4]) end
        local r={scope='PWP-SCOPE-1:'..W..':'..G..':'..(stream=='P' and 'priorities' or 'limits'),
            session='writer-session',incarnation='writer-incarnation',epoch=f.server.epoch,
            revision=f.calls,attachment=7}
        f.receipts[#f.receipts+1]=r
        return false,'pending',r
    end
    if enabled then assert(f.server.enable_deferred(true),'pre-handshake opt-in rejected') end
    assert(f.client.hello());f.to_server();f.to_client();f.to_server();f.to_client()
    assert(f.client.status=='ready')
    f.peer=f.server.clients['comp-A']
    function f.message(id,edit)
        return wire.envelope('Q',f.peer.server,f.peer.client,f.peer.guild)..'|'..id..'|'..(edit or 'Set|Mining|Stone|400')
    end
    function f.submit(id,edit)
        local message=f.message(id,edit)
        f.server.receive_command(f.component,message,0)
        return message
    end
    function f.successes()
        local out={}
        for _,m in ipairs(f.down)do
            local p=wire.parts(m)
            if p[2]=='A' and p[7]=='1' then out[#out+1]=p end
        end
        return out
    end
    function f.no_success(label)assert(#f.successes()==0,label or 'premature success ACK')end
    return f
end

-- Default-off preserves unknown legacy pending results, with no durable query.
do
    local f=fixture(false);local m=f.submit(1)
    f.saved=true;f.server.complete_pending()
    f.server.receive_command(f.component,m,0)
    assert(f.calls==1 and f.queries==0 and f.publications==0)
    f.no_success();assert(not f.server.enable_deferred(true),'enabled after handshake')
end

-- Legacy sync owners still work; unavailable ownership never enters mutation.
do
    local f=fixture(true)
    f.server.pending_owner=function()return false end
    f.server.on_command=function()f.calls=f.calls+1;return true end
    f.submit(1);assert(f.calls==1 and #f.successes()==1)
    f=fixture(true);f.server.pending_owner=function()return nil end
    f.submit(1);assert(f.calls==0);f.no_success()
end

-- Reservation precedes mutation and survives acceptance: exact duplicates and
-- altered IDs never mutate twice; a different ID cannot bypass stream capacity.
do
    local f=fixture(true)
    f.during_mutation=function()
        f.during_mutation=nil
        f.submit(1);f.submit(2)
    end
    local m=f.submit(1)
    f.server.receive_command(f.component,m,0)
    f.submit(1,'Set|Mining|Stone|999');f.submit(3)
    assert(f.calls==1,'duplicate or occupied stream entered mutator')
    f.no_success()
end

-- Both streams require durability AND an entire real wire snapshot. ACK replay
-- retains that snapshot revision even after a later unrelated publication.
for _,edit in ipairs({'Set|Mining|Stone|400','Clear|Mining|Stone','Prio|PAL-A|1|4'})do
    local f=fixture(true);local m=f.submit(1,edit)
    f.server.complete_pending();assert(f.publications==0);f.no_success()
    f.saved=true;f.server.complete_pending()
    local a=f.successes();assert(#a==1 and a[1][6]=='1','durable edit not acknowledged')
    local stream=edit:match('^Prio') and 'P' or 'R'
    local index=stream=='P' and 9 or 10
    assert(tonumber(a[1][index])==f.peer.revisions[stream])
    local end_index,ack_index
    for i,mess in ipairs(f.down)do
        local p=wire.parts(mess)
        if p[2]=='E' then end_index=i end
        if p[2]=='A' and p[7]=='1' then ack_index=i end
    end
    assert(end_index and end_index<ack_index,'ACK preceded complete snapshot')
    local pinned=a[1][index]
    if stream=='P' then assert(f.server.push_pals(f.rows,f.component))
    else assert(f.server.push_rules(f.caps,{},f.component))end
    f.server.receive_command(f.component,m,0)
    a=f.successes();assert(#a==2 and a[2][index]==pinned and f.calls==1)
end

-- At most one queued job per beat, including when both streams are pending.
do
    local f=fixture(true);f.submit(1);f.submit(2,'Prio|PAL-A|1|4')
    assert(f.calls==2);f.saved=true
    f.server.complete_pending();assert(f.queries==1 and #f.successes()==1)
    f.server.complete_pending();assert(f.queries==2 and #f.successes()==2)
end

-- Receipt identity must be copied at acceptance, including attachment.
do
    local f=fixture(true);f.submit(1)
    f.receipts[1].attachment=999;f.receipts[1].revision=999
    f.server.complete_pending()
    assert(f.query_receipts[1].attachment==7 and f.query_receipts[1].revision==1)
end

-- Maintenance's publication fence suppresses even the receipt query until ready.
do
    local f=fixture(true);f.submit(1);f.saved=true
    f.server.publication_guard=function()return function()return false end end
    f.server.complete_pending()
    assert(f.queries==0 and f.publications==0);f.no_success()
    f.server.publication_guard=nil -- standalone transport has no maintenance gate
    f.server.complete_pending()
    assert(f.queries==1 and #f.successes()==1)
end

-- Eight seconds is an absolute unknown deadline, never renewed by duplicates.
do
    local f=fixture(true);local m=f.submit(1)
    f.now=7.9;f.server.receive_command(f.component,m,0)
    f.now=8;f.saved=true;f.server.complete_pending()
    f.no_success();assert(f.publications==0)
    f.now=9;f.server.receive_command(f.component,m,0);f.server.complete_pending()
    f.no_success();assert(f.calls==1,'timeout replayed accepted mutation')
end

-- Lifecycle/ownership failures revoke replies without implying write rollback.
for _,invalidate in ipairs({
    function(f)f.server.begin_session(42)end,
    function(f)f.component.guild='guild-B'end,
    function(f)f.disconnected=true end,
    function(f)f.server.clients['comp-A']=nil end,
    function(f)f.peer.client='replacement-client'end,
    function(f)f.server_api.has_authority=function()return false end end,
})do
    local f=fixture(true);f.submit(1);invalidate(f);f.saved=true
    f.server.complete_pending();f.no_success();assert(f.publications==0 and f.calls==1)
end

-- Failed/unknown durability and incomplete publication never mean saved.
for _,status in ipairs({
    function()error('query failure')end,
    function()return nil end,
    function()return {state='stale'}end,
    function()return {state='saved',body='body',revision=0,request_revision=1},function()return true end end,
    function()return {state='saved',body='body',revision=1,request_revision=1},function()return false end end,
    function()return {state='saved',body='body',revision=1},function()return true end end,
    function()return {state='saved',body='body',revision=2,request_revision=2},function()return true end end,
})do
    local f=fixture(true);f.submit(1);f.server.pending_status=status;f.saved=true
    f.server.complete_pending();f.no_success();assert(f.publications==0)
end
for _,publish in ipairs({function()return false end,function()error('send failure')end})do
    local f=fixture(true);f.submit(1);f.saved=true;f.server.publish_pending=publish
    f.server.complete_pending();f.no_success();assert(f.calls==1)
end

-- Reacquire the component; retaining the request's native wrapper is forbidden.
do
    local f=fixture(true);f.submit(1)
    local old=f.component
    old.GetFullName=function()error('retained old native component')end
    old.Notify_RequestClient_int32=function()error('sent using old native component')end
    f.component={guild='guild-A',GetFullName=function()return 'comp-A'end,
        Notify_RequestClient_int32=function(_,_,m)f.down[#f.down+1]=m end}
    f.saved=true;f.server.complete_pending()
    assert(f.census>0 and #f.successes()==1)
end

-- Native conversion/send can synchronously invalidate an exact-body guard or
-- session. No successful ACK is legal after either callback boundary.
for _,boundary in ipairs({'fname','send'})do
    for _,change in ipairs({'body','session'})do
        local f=fixture(true);f.submit(1);f.saved=true
        local fired=false
        local function interrupt(m)
            if not fired and wire.parts(m)[2]=='B' then
                fired=true
                if change=='body' then f.body='superseded'
                else f.server.begin_session(42)end
            end
        end
        if boundary=='fname' then FName=function(m)interrupt(m);return m end
        else f.component.Notify_RequestClient_int32=function(_,_,m)
            f.down[#f.down+1]=m;interrupt(m)
        end end
        f.server.complete_pending();assert(fired);f.no_success()
    end
end

-- A nested completion callback cannot service another job or ACK twice.
do
    local f=fixture(true);f.submit(1);f.submit(2,'Prio|PAL-A|1|4');f.saved=true
    local publish=f.server.publish_pending
    f.server.publish_pending=function(...)
        f.server.complete_pending()
        return publish(...)
    end
    f.server.complete_pending()
    assert(f.queries==1 and f.publications==1 and #f.successes()==1 and f.calls==2)
end
