-- Exercise actual store/settings_writer/settings_session with an in-memory
-- journal endpoint. A receipt skips work only inside its one callback.
local file=assert(io.open(TEST_ROOT..'/tests/test_caps_recovery_activation.lua','r'))
local source=file:read('*a');file:close()
local cut=assert(source:find('\nlocal function fresh%(%)'))
local build=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@receipt-real-writer'))()
local function fresh()
    local f=build('store',nil,nil,{palA={[1]=1},palB={[1]=2}})
    f.m.set_role('authority',7);assert(f:activate())
    f.authorizations=0
    f.on_authorize=function()f.authorizations=f.authorizations+1 end
    return f,f.m
end
do
    local f,m=fresh();local retained
    local a,b,c=m.with_flush_receipt(m.flush,function(receipt)
        retained=receipt
        local calls=f.authorizations
        assert(calls>0 and receipt() and not receipt(),'receipt must be single-use')
        assert(f.authorizations==calls,'receipt polled native proofs')
        return 'a',nil,'c'
    end)
    assert(a=='a' and b==nil and c=='c' and not retained())
    m.with_flush_receipt(m.flush,function(receipt)retained=receipt end)
    assert(not retained(),'unused receipt survived callback return')
    local marker={}
    local ok,why=pcall(m.with_flush_receipt,m.flush,function(receipt)retained=receipt;error(marker)end)
    assert(not ok and why==marker and not retained(),'exception retained receipt or changed error')
end
for _,mode in ipairs({'pending','failed','edit','raw_edit','session','detach','fence','nested','saved_edit'})do
    local f,m=fresh()
    if mode=='pending' then local yes,why=f:edit(3);assert(not yes and why=='pending')end
    if mode=='failed' then f.denied=true end
    m.with_flush_receipt(m.flush,function(receipt)
        local gate,token=require('settings_gate')
        if mode=='edit' or mode=='saved_edit' then
            local yes,why=f:edit(3);assert(not yes and why=='pending')
            if mode=='saved_edit' then f:complete();assert(m.flush())end
        elseif mode=='raw_edit' then m.data.palA[1]=4
        elseif mode=='session' then m.session=8
        elseif mode=='detach' then m.detach_persistence()
        elseif mode=='fence' then token=assert(gate.acquire())
        elseif mode=='nested' then m.with_flush_receipt(m.flush,function(inner)assert(inner())end)end
        assert(not receipt(),'invalid receipt accepted: '..mode)
        if token then assert(gate.release(token))end
    end)
end
print('PASS flush receipt: real writer, pending/failure, edits, ownership, callback expiry/reentry')
