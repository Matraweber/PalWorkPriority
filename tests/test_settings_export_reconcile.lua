local Store,Caps=require('store'),require('caps')
local Plan=dofile(TEST_ROOT..'/experiments/settings_export_reconcile.lua')
local W,G,H=string.rep('a',32),'00000001000000020000000300000004',string.rep('c',32)
local function fixture()
    return {enabled=true,storage=W,guild=G,legacy_guild='1-2-3-4',
        membership={{pal='mine',storage=W,guild=G},{pal='deleted',storage=W,guild=G},
            {pal='foreign',storage=W,guild=H}},
        legacy_priorities=assert(Store.serialize_snapshot({mine={[1]=3,[2]=4},deleted={[1]=2},
            foreign={[1]=false},unassigned={[2]=5}},true)),
        legacy_limits=assert(Caps.serialize_snapshot({['1-2-3-4']={Mining={Stone=100,Ore=200}},
            [H]={Mining={Stone=50}},['*']={Mining={Wood=300}}})),
        journal_priorities=assert(Store.serialize_snapshot({mine={[1]=false,[3]=1}},true)),
        journal_limits=assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Wood=400}}}))}
end
local o=fixture();local r=assert(Plan.plan(o))
assert(not r.replacement_allowed and not r.ownership_verified and not r.deletion_coverage_verified)
local p=assert(Store.decode_snapshot(r.bodies.priorities))
assert(p.baseline and p.data.mine[1]==false and p.data.mine[3]==1)
assert(p.data.mine[2]==nil and p.data.deleted==nil,'deleted target rows resurrected')
assert(p.data.foreign[1]==false and p.data.unassigned[2]==5,'unrelated rows lost')
local c=assert(Caps.decode_snapshot(r.bodies.limits))
assert(c.data['1-2-3-4'].Mining.Stone==false and c.data['1-2-3-4'].Mining.Wood==400)
assert(c.data['1-2-3-4'].Mining.Ore==nil and c.data[G]==nil)
assert(c.data[H].Mining.Stone==50 and c.data['*'].Mining.Wood==300)
assert(r.result_counts.priorities==4 and r.preserved_counts.priorities==2)
assert(r.replaced_counts.priorities==3 and r.journal_counts.priorities==2)
assert(o.legacy_priorities==fixture().legacy_priorities and o.journal_limits==fixture().journal_limits)
-- No inferred deletion: lack of a claim keeps the old Pal, explicitly unverified.
o=fixture();table.remove(o.membership,2);r=assert(Plan.plan(o))
assert(Store.decode_snapshot(r.bodies.priorities).data.deleted[1]==2)
assert(not r.deletion_coverage_verified)
-- Empty journals delete target scope only.
o=fixture();o.journal_priorities=Store.serialize_snapshot({},true);o.journal_limits=Caps.serialize_snapshot({})
r=assert(Plan.plan(o));p=Store.decode_snapshot(r.bodies.priorities);c=Caps.decode_snapshot(r.bodies.limits)
assert(not p.data.mine and not p.data.deleted and p.data.foreign and p.data.unassigned)
assert(not c.data['1-2-3-4'] and c.data[H] and c.data['*'])
local function reject(change)
    local v=fixture();change(v);local result=Plan.plan(v);assert(not result,'unsafe reconciliation accepted')
end
reject(function(v)v.membership={}end)
reject(function(v)v.membership[1].guild=H end)
reject(function(v)v.membership[4]=v.membership[1]end)
reject(function(v)v.membership[1].storage=H end)
reject(function(v)v.membership[1].pal='slot1'end)
reject(function(v)v.legacy_guild='1-2-3-5'end)
reject(function(v)v.legacy_guild='*'end)
reject(function(v)v.guild=G:upper():gsub('0','A',1)end)
reject(function(v)v.journal_priorities=Store.serialize_snapshot({mine={[1]=false}},false)end)
reject(function(v)v.journal_limits=Caps.serialize_snapshot({[H]={Mining={Stone=1}}})end)
reject(function(v)v.journal_priorities=v.journal_priorities..'# extra metadata\n'end)
reject(function(v)v.journal_limits='broken'end)
reject(function(v)v.legacy_priorities='broken'end)
reject(function(v)v.legacy_limits=Caps.serialize_snapshot({[G]={Mining={Stone=50}},['1-2-3-4']={Mining={Stone=50}}})end)
reject(function(v)v.legacy_limits=Caps.serialize_snapshot({[G]={Mining={Stone=50}},['1-2-3-4']={Mining={Ore=200}}})end)
reject(function(v)
    v.legacy_limits=Caps.serialize_snapshot({[G]={Mining={Stone=50}},['1-2-3-4']={Mining={Ore=200}}})
    v.journal_limits=Caps.serialize_snapshot({})
end)
reject(function(v)v.membership[1]=nil end)
reject(function(v)v.enabled=false end)
reject(function(v)v.unexpected=true end)
-- Canonical group destination is valid too; no duplicate claim generated.
o=fixture();o.legacy_guild=G;o.legacy_limits=Caps.serialize_snapshot({[G]={Mining={Stone=100}}})
r=assert(Plan.plan(o));assert(Caps.decode_snapshot(r.bodies.limits).data[G].Mining.Stone==false)
