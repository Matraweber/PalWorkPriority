-- Composition test: real caps/store -> writer -> session -> barrier and the
-- pending-edit ledger. Backend completion is fake. This is NOT net/main or
-- transport acceptance: the explicit publication barrier below models its caller.
local h=assert(io.open(TEST_ROOT..'/tests/test_caps_recovery_activation.lua','r'))
local source=h:read('*a');h:close()
local cut=assert(source:find('\nlocal function fresh%(%)'))
local fixture=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@pending-durability-fixture'))()
local Ledger=dofile(TEST_ROOT..'/experiments/settings_pending_edits.lua')
for _,name in ipairs({'caps','store'})do
    for _,mode in ipairs({'complete','timeout','role_change','uncertain'})do
        local alias=name=='caps' and '-758686034-1314655308-1294252187-537966059' or nil
        local rows=name=='store' and {palA={[1]=1},palB={[1]=2}} or nil
        local f=fixture(name,nil,alias,rows);local m=f.m
        m.set_role('authority',7);assert(f:activate())
        local ledger=assert(Ledger.new{enabled=true})
        -- The canonical identity comes from verified fixture context, NOT a
        -- client's claimed guild or a guessed conversion of the runtime alias.
        local binding=assert(ledger:bind{name='peer',server='server',client='client',
            guild=f.context.guild,epoch=f.context.epoch})
        local request=assert(ledger:reserve(binding,1,f.context.stream,'edit:3',0))
        assert(request.status=='reserved')
        local accepted,reason,receipt=f:edit(3)
        assert(accepted==false and reason=='pending')
        assert(ledger:accepted(request.ticket,receipt,0).state=='pending')
        local writes=f.writes
        local duplicate=assert(ledger:reserve(binding,1,f.context.stream,'edit:3',1))
        assert(duplicate.status=='duplicate' and duplicate.state=='pending')
        assert(not ledger:reserve(binding,2,f.context.stream,'edit:4',1))
        assert(f.writes==writes and m.receipt_status(duplicate.receipt).state=='saving')
        if mode=='uncertain' then f:complete('uncertain') else f:complete() end
        if mode=='role_change' then m.set_role('client',8) end
        if mode=='timeout' then assert(#ledger:expire(8)==1) end
        -- Storage completion alone does not publish module success.
        if mode=='complete' or mode=='timeout' then
            assert(m.receipt_status(receipt).state=='saving')
            assert(m.flush())
        end
        local proof=m.receipt_status(receipt)
        if mode=='complete' then
            assert(proof.state=='saved' and proof.body==assert(m.serialize_snapshot(
                name=='store' and m.data or {[f.context.guild]=m.data[alias]})))
            -- No completion before a successful snapshot send. The ledger still
            -- reports pending even though the storage module is now saved.
            assert(ledger:reserve(binding,1,f.context.stream,'edit:3',2).state=='pending')
            local done=assert(ledger:complete(request.ticket,{receipt=receipt,
                covered_revision=proof.revision,snapshot_revision=17},3))
            assert(done.state=='durable' and done.publication.snapshot_revision==17)
            assert(ledger:reserve(binding,1,f.context.stream,'edit:3',4).publication.snapshot_revision==17)
        elseif mode=='timeout' then
            assert(proof.state=='saved','fixture did not durably finish after deadline')
            assert(not ledger:complete(request.ticket,{receipt=receipt,
                covered_revision=proof.revision,snapshot_revision=17},8))
            assert(ledger:reserve(binding,1,f.context.stream,'edit:3',8).state=='unknown')
        else
            assert(proof.state~='saved','uncertain or retired attachment became durable')
            assert(ledger:unknown(request.ticket,2).state=='unknown')
        end
        assert(f.writes==writes,'query/retry resubmitted accepted bytes')
    end
end
print('PASS pending durability composition: both streams, canonical alias, timeout, role change and uncertainty')
