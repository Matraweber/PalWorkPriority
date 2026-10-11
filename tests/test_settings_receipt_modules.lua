local h=assert(io.open(TEST_ROOT..'/tests/test_caps_recovery_activation.lua','r'))
local source=h:read('*a');h:close()
local cut=assert(source:find('\nlocal function fresh%(%)'))
local build=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@receipt-module-fixture'))()
for _,name in ipairs({'caps','store'})do
    local rows=name=='store' and {palA={[1]=1},palB={[1]=2}} or nil
    local alias=name=='caps' and '-758686034-1314655308-1294252187-537966059' or nil
    local f=build(name,nil,alias,rows);local m=f.m;m.set_role('authority',7);assert(f:activate());m.on_change=function()f.notices=f.notices+1 end
    local yes,why,r=f:edit(3);assert(not yes and why=='pending')
    assert(m.receipt_status(r).state=='saving' and f.notices==0)
    f:complete()
    assert(m.receipt_status(r).state=='saving','query bypassed normal module notification')
    assert(f.notices==0 and m.state=='saving')
    local flushed,reason=m.flush();assert(flushed,name..' flush '..tostring(reason)..' state '..tostring(m.state)..' error '..tostring(m.error));assert(f.notices==1,name..' notices '..f.notices)
    local result=m.receipt_status(r)
    assert(result.state=='saved' and result.request_revision==r.revision)
    local forged={};for k,v in pairs(r)do forged[k]=v end;forged.attachment=forged.attachment+1
    assert(m.receipt_status(forged).state=='invalid_receipt')
    -- Public UI counters cannot authorize another body or a detached writer.
    if name=='store' then m.data.palA[1]=5 else m.data[alias].Mining.Stone=5 end
    assert(m.receipt_status(r).state~='saved','changed memory treated as durable snapshot')
    m.set_role('client',8);assert(m.receipt_status(r).state=='unavailable')
    assert(f.notices==1,'query sent a notification')
end
print('PASS receipt modules: original writer, durable module commit, snapshot mismatch and client fence')
