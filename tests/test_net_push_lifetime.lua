-- A snapshot must stop when synchronous engine callbacks replace its session
-- or peer. The first packet may already be sent; never finish the stale batch.
FName = function(s) return s end
package.loaded.log = {warn=function() end,debug=function() end,perf=false}
local function run(boundary, stream, direct, change)
    local net, peers, comps, txs, sent = nil, {}, {}, {}, {}
    local fired, stale_reads = false, 0
    local authority = true
    local function invalidate(at)
        if at ~= boundary or fired then return end
        fired = true
        if change == 'nonce' then net.local_nonce = 'new-server'
        elseif change == 'peer' then
            for name,p in pairs(net.clients) do
                net.clients[name]={server=p.server,client=p.client,guild=p.guild,
                    revisions={P=1,R=1},next_revision={P=1,R=1}}
            end
        elseif change == 'scope' then for _,p in pairs(net.clients) do p.guild='new-guild' end
        elseif change == 'authority' then authority = false
        elseif change == 'nested' then net.push_pals(function() return nil end)
        elseif change == 'nested_success' then
            if stream=='P' then
                assert(net.push_pals(function()
                    return {{key='PAL-A',ranks={[1]=1},prios={[1]=2}}}
                end))
            else
                assert(net.push_rules({all=function() return {Mining={Stone=200}} end},{}))
            end
        else net.begin_session(net.epoch+1) end
    end
    local function native_access()
        if fired and change=='session' then
            stale_reads=stale_reads+1
            error('native wrapper used after session invalidation')
        end
    end
    for i=1,2 do
        local name='component-'..i
        local tx={}
        function tx:GetFullName() native_access(); return 'tx-'..i end
        function tx:GetOwner() native_access(); invalidate('guild'); return {guild='guild-A'} end
        local c={}
        function c:GetFullName() native_access(); invalidate('name'); return name end
        function c:GetOuter() native_access(); return tx end
        function c:Notify_RequestClient_int32(_,message)
            native_access()
            sent[#sent+1]=message
            invalidate('send')
        end
        comps[i],txs[i]=c,tx
    end
    package.loaded.palapi={valid=function(o) native_access(); return type(o)=='table' end,
        has_authority=function() return authority end,guild_of=function(o) return o.guild end}
    FName=function(s) invalidate('fname'); return s end
    FindAllOf=function(class)
        invalidate('discovery')
        return class=='PalNetworkBaseCampComponent' and comps or txs
    end
    package.loaded.net=nil; net=require('net'); net.begin_session(1)
    for i=1,2 do
        peers[i]={server=net.local_nonce,client='client-'..i,guild='guild-A',
            revisions={P=1,R=1},next_revision={P=1,R=1}}
        net.clients['component-'..i]=peers[i]
    end
    local result
    if stream=='P' then
        result=net.push_pals(function()
            invalidate('rows')
            return {{key='PAL-A',ranks={[1]=1},prios={[1]=1}}}
        end,direct and comps[1] or nil)
    else
        result=net.push_rules({all=function() invalidate('rows'); return {Mining={Stone=100}} end},
            {},direct and comps[1] or nil)
    end
    assert(fired,'test never reached '..boundary)
    assert(stale_reads==0,'caught native error concealed stale wrapper use')
    assert(result==false, boundary..': stale batch reported success')
    if change=='nested_success' then
        assert(#sent==7,'outer batch resumed after successful nested broadcast')
        for _,peer in ipairs(peers) do
            assert(peer.revisions[stream]>1 and peer.revisions[stream]==peer.next_revision[stream],
                'outer commit overwrote newer nested revision')
        end
        return
    end
    assert(#sent==(boundary=='send' and 1 or 0),boundary..': packets sent after invalidation')
    for _,peer in ipairs(peers) do assert(peer.revisions[stream]==1,'stale revision committed') end
end
for _,stream in ipairs({'P','R'}) do
    for _,boundary in ipairs({'discovery','guild','rows','send','fname','name'}) do
        for _,change in ipairs({'session','nonce','peer','scope','authority','nested'}) do
            run(boundary,stream,false,change)
            run(boundary,stream,true,change)
        end
    end
    run('send',stream,false,'nested_success')
    run('send',stream,true,'nested_success')
end
