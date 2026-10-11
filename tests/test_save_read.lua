local Read=dofile(TEST_ROOT..'/experiments/save_read.lua')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local scope='test-scope'
for _,s in ipairs({false,true,{}, {exists=false}, {exists=true}, {schema='foreign',fields_read=true},
    {schema='PWP-SCRATCH-1',fields_read=false},
    {schema='PWP-SCRATCH-1',fields_read=true,record={session='foreign'}}}) do
    assert(Read.from_native(scope,s).status=='unreadable')
end
assert(Read.from_native(scope,nil).status=='unreadable')
local r={session=scope,generation=1,payload='1|X',checksum='00000000'}
local snapshot={schema='PWP-SCRATCH-1',fields_read=true,record=r}
local out=Read.from_native(scope,snapshot)
assert(out.status=='ok' and out.record~=r)
r.payload='changed';assert(out.record.payload=='1|X')
r.payload=string.rep('x',65537);assert(Read.from_native(scope,snapshot).status=='unreadable')
r.payload='x';r.generation=1.5;assert(Read.from_native(scope,snapshot).status=='invalid')
r.generation=1;r.checksum='bad';assert(Read.from_native(scope,snapshot).status=='invalid')
-- Critical integration: failed native load cannot initialize empty settings.
local writes=0
local q=Queue.new({start_read=function() return true end,
    start=function() writes=writes+1;return true end,
    poll=function(ticket) return {ticket=ticket,success=false,read=Read.from_native(scope,nil)} end},scope)
assert(q:recover());assert(q:poll()==false and q.state=='error')
assert(not pcall(q.submit,q,'new defaults') and writes==0)
print('native read classification: ambiguous absence refused, scoped scalar copy, recovery blocks defaults')
