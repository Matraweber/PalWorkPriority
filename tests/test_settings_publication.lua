-- Real persistence owner, writer, session, journal/barrier. Native IO completion
-- is fake; publication checks must not run another persistence poll.
local h=assert(io.open(TEST_ROOT..'/tests/test_caps_recovery_activation.lua','r'))
local source=h:read('*a');h:close()
local cut=assert(source:find('\nlocal function fresh%(%)'))
local fixture=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@publication-fixture'))()
for _,name in ipairs({'caps','store'})do
    local alias=name=='caps' and '-758686034-1314655308-1294252187-537966059' or nil
    local data=name=='store' and {palA={[1]=1},palB={[1]=2}} or nil
    local f=fixture(name,nil,alias,data);local m=f.m
    m.set_role('authority',7);assert(f:activate())
    local initial=assert(m.publication_guard());assert(initial())
    local writes,notices=f.writes,f.notices
    local proof_calls=0
    f.on_authorize=function()proof_calls=proof_calls+1;error('guard must not call provider')end
    for _=1,20 do assert(initial() and assert(m.publication_guard())())end
    assert(f.writes==writes and f.notices==notices and proof_calls==0)
    f.on_authorize=nil
    local accepted,state,receipt=f:edit(3)
    assert(not accepted and state=='pending')
    assert(not initial() and not m.publication_guard(),'pending body published')
    -- Spoofing UI fields does not change the private durable body.
    local old_state=m.state;m.state='saved';m.error=nil
    assert(not m.publication_guard(),'public saved flag granted durability')
    m.state=old_state
    f:complete();assert(not m.publication_guard(),'IO completion bypassed module publication')
    assert(m.flush());local committed=assert(m.publication_guard());assert(committed())
    assert(not initial(),'old revision revived after commit')
    local before=m.serialize()
    if name=='store'then m.data.palA[1]=5 else m.data[alias].Mining.Stone=5 end
    assert(not committed() and not m.publication_guard(),'out-of-band mutation published')
    if name=='store'then m.data.palA[1]=3 else m.data[alias].Mining.Stone=3 end
    assert(m.serialize()==before and committed())
    -- Guard calls must recheck identity after any serialization boundary.
    local serialize=m.serialize
    m.serialize=function()m.set_role('client',8);return before end
    assert(not committed(),'role changed during serialization escaped guard')
    m.serialize=serialize
    assert(not m.publication_guard())
end
print('PASS publication guards: pending/durable, metadata spoof, raw mutation and lifecycle')

-- Effective defaults are not journal bytes, but must stay fixed throughout a
-- publication. Reloads invalidate even when values happen to be identical.
for _,mode in ipairs({'nested','replace','reload','invalid'})do
    local f=fixture('caps',nil,'-758686034-1314655308-1294252187-537966059')
    local m=f.m;m.set_role('authority',7);assert(f:activate())
    local cfg={work_caps={Mining={Ore=100}}};m.configure(cfg)
    local guard=assert(m.publication_guard(nil,nil,cfg));assert(guard())
    if mode=='nested' then cfg.work_caps.Mining.Ore=200
    elseif mode=='replace' then cfg.work_caps={Mining={Ore=300}}
    elseif mode=='reload' then m.configure({work_caps={Mining={Ore=100}}})
    else cfg.work_caps.Mining.Ore={} end
    assert(not guard(),'changed defaults escaped publication guard: '..mode)
end
-- The explicit snapshot config, not a different configured source, is guarded.
do
    local f=fixture('caps',nil,'-758686034-1314655308-1294252187-537966059')
    local m=f.m;m.set_role('authority',7);assert(f:activate())
    m.configure({work_caps={Mining={Ore=100}}})
    local cfg={work_caps={Mining={Ore=200}}}
    local guard=assert(m.publication_guard(nil,nil,cfg));cfg.work_caps.Mining.Ore=201
    assert(not guard())
end
