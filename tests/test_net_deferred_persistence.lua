-- Real net/protocol/ledger + main's four bridge callbacks + caps/store + writer
-- + session/codec/barrier. Engine roster/RPC and file completion are test doubles.
-- No native backend, installed paths, launcher, or dedicated enablement involved.
local function prefix(path,boundary,result)
    local h=assert(io.open(TEST_ROOT..path,'r'));local s=h:read('*a');h:close()
    local at=assert(s:find(boundary,1,true),'fixture boundary changed: '..path)
    return assert(load(s:sub(1,at-1)..'\nreturn '..result,'@'..path))()
end
local recovery=prefix('/tests/test_caps_recovery_activation.lua','\nlocal function fresh()','fixture')
local transport=prefix('/tests/test_net_commit_errors.lua','\nlocal f=fixture(false)','fixture')
local h=assert(io.open(TEST_ROOT..'/Scripts/main.lua','r'));local main=h:read('*a');h:close()
local first=assert(main:find('net.publication_guard = function(stream,publication_cfg)',1,true))
local last=assert(main:find('\nnet.on_command = function',first,true))
local bridge=main:sub(first,last-1)
local wire=require('protocol')
local ALIAS='-758686034-1314655308-1294252187-537966059'
local function fixture(name,cfg)
    cfg=cfg or {}
    local rows=name=='store' and {palA={[1]=1},palB={[1]=2}} or nil
    local p=recovery(name,nil,name=='caps' and ALIAS or nil,rows)
    local m=p.m;m.set_role('authority',7);assert(p:activate())
    m.on_change=function()p.notices=p.notices+1 end
    local f=transport(nil);f.server.begin_session(7)
    f.client_api.has_authority=function()return false end
    local guild=name=='caps' and ALIAS or p.context.guild
    local stream=name=='caps' and 'R' or 'P'
    f.component.guild=guild
    FindAllOf=function(class)
        assert(class=='PalNetworkBaseCampComponent');return {f.component}
    end
    f.client.on_snapshot=function(data,meta)
        assert(meta.guild==guild and meta.epoch==77)
        f.view=data;return true
    end
    local function stand()
        if name~='store' then return f.rows() end
        local out={}
        for key,prios in pairs(m.data)do out[#out+1]={key=key,ranks={[1]=3},prios=prios}end
        return out
    end
    local caps=name=='caps' and m or f.caps
    local inert={publication_guard=function()return function()return true end end}
    -- Execute the actual source adapter block, so receipt/guard wiring is not
    -- independently reimplemented by the test. Only engine roster construction
    -- is replaced; its publication still goes through real push_pals.
    local env=setmetatable({net=f.server,caps=name=='caps' and m or inert,
        store=name=='store' and m or inert,cfg=cfg,push_stand=function(comp,key,current)
            return f.server.push_pals(stand,comp,key,current)
        end},{__index=_G})
    if name=='store' then env.caps=caps;caps.publication_guard=inert.publication_guard end
    assert(load(bridge,'@main-deferred-adapters','t',env))()
    f.server.on_command=function(command,_,comp)
        local args=f.server.split(command)
        if args[1]=='PWP_Hello' then
            assert(f.server.push_rules(caps,cfg,comp));assert(f.server.push_pals(stand,comp));return true
        end
        f.calls=f.calls+1
        local ok,why,r
        if name=='caps' then ok,why,r=m.apply_set(args[2],args[3],tonumber(args[4]),guild)
        else ok,why,r=m.apply_set(args[2],tonumber(args[3]),wire.decode_priority(args[4]))end
        f.receipt=r;return ok,why,r
    end
    assert(f.server.enable_deferred(true))
    assert(f.client.hello());f.to_server();f.to_client();f.to_server();f.to_client()
    assert(f.client.status=='ready')
    f.peer=f.server.clients['comp-A']
    function f.request()
        if name=='caps' then assert(f.client.request('set','Mining','Stone',43000))
        else assert(f.client.request_prio('palA',1,4));f.now=f.now+0.2;f.client.poll()end
        local messages=f.to_server();assert(#messages==1 and f.calls==1)
        assert(f.receipt and f.receipt.attachment and f.receipt.epoch==7)
        f.request_message=messages[1]
    end
    function f.acks()
        local list={}
        for _,packet in ipairs(f.down)do
            local a=wire.parts(packet)
            if a[2]=='A' and a[7]=='1' then list[#list+1]=a end
        end
        return list
    end
    return f,p,m,stream
end

-- Effective defaults belong to the publication proof even though they are not
-- in the journal body. Mutating one during native FName conversion must abort
-- both an unstarted batch (B) and a batch whose data packets already went out (E).
for _,boundary in ipairs({'B','E'})do
    local cfg={work_caps={Mining={Ore=100}}}
    local f,p,m=fixture('caps',cfg)
    local found=false
    for _,row in ipairs(f.view)do
        if row.item=='Ore' then assert(row.amount==100);found=true end
    end
    assert(found,'fixture did not publish actual configured default')
    f.request();p:complete();assert(m.flush())
    local body=m.serialize()
    local revision=f.peer.revisions.R
    local fired=false
    FName=function(packet)
        local fields=wire.parts(packet)
        if not fired and fields[2]==boundary and fields[6]=='R' then
            fired=true;cfg.work_caps.Mining.Ore=200
        end
        return packet
    end
    f.server.complete_pending()
    assert(fired,'did not cross '..boundary..' FName boundary')
    assert(m.serialize()==body and m.state=='saved','test changed durable settings instead of defaults')
    assert(#f.acks()==0,'changed effective defaults allowed a success ACK')
    assert(f.peer.revisions.R==revision,'changed defaults committed a peer revision')
    for _,packet in ipairs(f.down)do
        local fields=wire.parts(packet)
        assert(not (fields[2]=='E' and fields[6]=='R'),'invalidated batch sent completion')
    end
    f.to_client()
    for _,row in ipairs(f.view)do
        if row.item=='Ore' then assert(row.amount==100,'partial snapshot replaced confirmed defaults')end
    end
    assert(p.writes==1 and f.calls==1 and #p.fs.operations==p.io)
end

for _,name in ipairs({'caps','store'})do
    for _,mode in ipairs({'complete','send_failure','timeout','role_change','body_change','uncertain'})do
        local f,p,m,stream=fixture(name)
        f.request();assert(p.writes==1 and m.state=='saving')
        f.server.receive_command(f.component,f.request_message,0)
        assert(f.calls==1 and p.writes==1,'wire duplicate resubmitted bytes')
        f.server.complete_pending();assert(#f.acks()==0 and p.notices==0)
        if mode=='uncertain' then p:complete('uncertain') else p:complete()end
        -- Native completion alone cannot confirm client state or bypass flush.
        f.server.complete_pending();assert(#f.acks()==0 and p.notices==0 and m.state=='saving')
        if mode=='uncertain' then
            m.flush();assert(m.receipt_status(f.receipt).state~='saved')
        else
            assert(m.flush());assert(p.notices==1 and m.state=='saved')
            local status=m.receipt_status(f.receipt)
            assert(status.state=='saved' and status.request_revision==f.receipt.revision)
            if mode=='timeout' then f.now=f.now+8
            elseif mode=='role_change' then m.set_role('client',8)
            elseif mode=='body_change' then
                if name=='caps' then m.data[ALIAS].Mining.Stone=1 else m.data.palA[1]=1 end
            end
        end
        local send=f.component.Notify_RequestClient_int32
        if mode=='send_failure' then
            f.component.Notify_RequestClient_int32=function()error('mock RPC send failed')end
            f.server.complete_pending();assert(#f.acks()==0)
            f.component.Notify_RequestClient_int32=send
        end
        f.server.complete_pending()
        local a=f.acks()
        if mode=='complete' or mode=='send_failure' then
            assert(#a==1,name..'/'..mode..': missing durable ACK')
            local end_at,ack_at
            for i,packet in ipairs(f.down)do
                local fields=wire.parts(packet)
                if fields[2]=='E' and fields[6]==stream then end_at=i end
                if fields[2]=='A' and fields[7]=='1' then ack_at=i end
            end
            assert(end_at and end_at<ack_at,'ACK before full durable snapshot')
            assert(tonumber(a[1][stream=='P' and 9 or 10])==f.peer.revisions[stream])
            f.to_client()
            assert(f.events[#f.events].status=='accepted','client did not settle durable edit')
            if name=='caps' then
                local found=false
                for _,row in ipairs(f.view)do if row.item=='Stone' then assert(row.amount==43000);found=true end end
                assert(found)
            else assert(f.client.pals.palA.prios[1]==4)end
        else assert(#a==0,name..'/'..mode..': false success')end
        assert(p.writes==1 and f.calls==1,'completion path replayed mutation')
        assert(#p.fs.operations==p.io,'async test unexpectedly wrote legacy files')
    end
end
