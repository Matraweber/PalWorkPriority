local snapshot=require('storage_snapshot')
local function fixture()
    return {pass_id=8,last_storage_by_camp={
        a={guild='g',pass=8,scope='camp',verified=true,sampled_at=100,ttl=30},
        b={guild='other',pass=8,scope='camp',verified=true,sampled_at=100,ttl=30}},
        last_totals_by_camp={a={Stone=42,Ore=0},b={Stone=999}}}
end
local s=fixture()
local v=snapshot.build({},s,'g',nil,105)
assert(v.verified and v.camp=='a' and #v.choices==1 and v.totals.Stone==42)
assert(v.age_ms==5000 and v.remaining_ms==25000 and v.totals.Ore==0)
s.last_totals_by_camp.a.Stone=55
assert(v.totals.Stone==42,'snapshot must own its data')
assert(not snapshot.build({},s,'g','b',105).verified,'no foreign selection')
assert(not snapshot.build({},s,'g','missing',105).verified,'no silent base substitution')
assert(not snapshot.build({},s,nil,nil,105).verified)
assert(not snapshot.build({},s,'g',nil,130).verified,'expired cache')
assert(not snapshot.build({},s,'g',nil,99).verified,'clock reversal')
s.last_storage_by_camp.a.pass=7
assert(not snapshot.build({},s,'g',nil,105).verified,'old pass')
s=fixture(); s.last_storage_by_camp.a.sampled_at=nil
assert(not snapshot.build({},s,'g',nil,105).verified,'missing sample time')
s=fixture(); s.last_storage_by_camp.a.unknown_scope=1
assert(not snapshot.build({},s,'g',nil,105).verified,'unknown ownership')
s=fixture(); s.last_storage_by_camp.a.verified=false
assert(not snapshot.build({},s,'g',nil,105).verified,'failed scan')
s=fixture(); s.last_totals_by_camp.a={}
assert(snapshot.build({},s,'g',nil,105).verified,'verified empty stock is real')
for _, bad in ipairs({-1,1.5,math.huge,2147483648}) do
    s=fixture();s.last_totals_by_camp.a.Stone=bad
    assert(not snapshot.build({},s,'g',nil,105).verified)
end
s=fixture();s.last_totals_by_camp.a['bad|id']=1
assert(not snapshot.build({},s,'g',nil,105).verified)
s=fixture();for i=1,snapshot.MAX_ITEMS+1 do s.last_totals_by_camp.a['Item'..i]=1 end
v=snapshot.build({},s,'g',nil,105)
assert(not v.verified and next(v.totals)==nil,'never publish truncation')
s=fixture();s.last_storage={g={pass=8,scope='guild',verified=true,sampled_at=100,ttl=30}}
s.last_totals_by_guild={g={Stone=123}}
v=snapshot.build({storage_scope='global'},s,'g',nil,105)
assert(v.verified and v.scope=='guild' and v.camp==nil and v.totals.Stone==123)
s.last_storage.g.unknown_scope=1
assert(not snapshot.build({storage_scope='global'},s,'g',nil,105).verified)
s.last_storage.g.unknown_scope=0;s.last_storage.g.pass=7
assert(not snapshot.build({storage_scope='global'},s,'g',nil,105).verified,'old guild pass')
s=fixture();s.last_totals_by_camp.a={}
for i=1,513 do s.last_totals_by_camp.a['Item'..i]=1 end
assert(not snapshot.build({},s,'g',nil,105).verified,'wire permits at most 512 items')
print('storage snapshot: scoped complete copies, freshness and bounded failure passed')
