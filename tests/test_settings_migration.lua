-- Actual codecs/partitioner, fake IO boundaries. No live evidence or activation.
local io_calls=0
local function no_io() io_calls=io_calls+1;error('unexpected filesystem IO') end
package.loaded.datafile={read=no_io,write=no_io}
package.loaded.log={warn=no_io,error=no_io}
local Store,Caps=require('store'),require('caps')
local Planner=dofile(TEST_ROOT..'/experiments/settings_migration.lua')
local function plan(o)
    if type(o)=='table' and getmetatable(o)==nil and o.original_files==nil then
        local supplied={}
        for k,v in pairs(o) do supplied[k]=v end
        supplied.original_files={priorities=o.priorities,limits=o.limits}
        return Planner.plan(supplied)
    end
    return Planner.plan(o)
end
local Codec=dofile(TEST_ROOT..'/experiments/save_settings_codec.lua')
local W,G,H=string.rep('a',32),'00000001000000020000000300000004',string.rep('c',32)
local function clone(t)
    if type(t)~='table' then return t end
    local c={};for k,v in pairs(t) do c[k]=clone(v) end;return c
end
local function options()
    return {enabled=true,storage=W,guild=G,
        priorities=assert(Store.serialize_snapshot({mine={[1]=false,[2]=1,[3]=2,[4]=3,[5]=4,[6]=5},
            theirs={[1]=4},orphan={[1]=false}},true)),
        limits=assert(Caps.serialize_snapshot({[G]={Mining={Stone=false,Ore=100}},[H]={Mining={Ore=300}}})),
        membership={{pal='mine',storage=W,guild=G},{pal='theirs',storage=W,guild=H}},
        limit_membership={{legacy_guild=G,storage=W,guild=G}}}
end
Store.data={never={[1]=false}};Store.baseline=false;Store.state='saving';Store.path='DO-NOT-USE';Store.generation=18
Caps.data={['*']={Mining={Stone=false}}};Caps.state='error';Caps.generation=19;Caps.path='DO-NOT-USE'
local before_p,before_l=Store.serialize(),Caps.serialize()
local function unchanged()
    assert(io_calls==0 and Store.serialize()==before_p and Caps.serialize()==before_l)
    assert(Store.state=='saving' and Store.generation==18 and Store.path=='DO-NOT-USE')
    assert(Caps.state=='error' and Caps.generation==19 and Caps.path=='DO-NOT-USE')
end
local checks=0
local function reject(o)
    local ok,plan,why=pcall(plan,o)
    assert(ok and plan==nil and type(why)=='string','invalid input was not cleanly rejected')
    checks=checks+1;unchanged()
end
local o=options();local p=assert(plan(o))
assert(p.contract=='PWP-MIGRATION-PLAN-1' and not p.verified and not p.authorized and not p.activation_allowed)
assert(p.backup.required and not p.backup.verified and p.backup.exact_source_comparison_required)
assert(p.backup.original.priorities==o.priorities and p.backup.original.limits==o.limits)
assert(p.backup.retain_original and not p.preserved.replace_legacy_source)
local a=assert(Store.decode_snapshot(p.candidate.bodies.priorities))
local b=assert(Store.decode_snapshot(p.preserved.bodies.priorities))
assert(a.count==6 and a.baseline and a.data.mine[1]==false)
for i=2,6 do assert(a.data.mine[i]==i-1) end
assert(not a.data.theirs and not a.data.orphan and b.data.orphan[1]==false and b.data.theirs[1]==4)
local limits=assert(Caps.decode_snapshot(p.candidate.bodies.limits))
assert(limits.data[G].Mining.Stone==false and limits.data[G].Mining.Ore==100 and not limits.data[H])
assert(Caps.decode_snapshot(p.preserved.bodies.limits).data[H].Mining.Ore==300)
assert(not p.evidence.membership_verified and not p.evidence.baseline_coverage_verified)
for _,stream in ipairs({'priorities','limits'}) do
    local codec=Codec.new{storage=W,guild=G,stream=stream}
    assert(codec.supported(p.candidate.payloads[stream]))
    assert(codec.encode(p.candidate.bodies[stream])==p.candidate.payloads[stream])
    assert(p.candidate.counts[stream]+p.preserved.counts[stream]==p.evidence.source_counts[stream])
end
-- Missing ownership retains even a matching guild's raw limit group: no guessing.
local none=options();none.membership={};none.limit_membership={}
local empty=assert(plan(none))
assert(empty.candidate.counts.priorities==0 and empty.candidate.counts.limits==0)
assert(empty.preserved.bodies.priorities==none.priorities and empty.preserved.bodies.limits==none.limits)
-- Unclaimed/foreign records remain exactly representable; no inherited view.
local legacy=options();legacy.limits=Caps.serialize_snapshot({[G]={Mining={Stone=false}},
    ['*']={Mining={Stone=200,Ore=false}},['unknown-alias']={Mining={Ore=700}},[H:upper()]={Mining={Stone=5}}})
reject(legacy)
legacy.limits_policy='preserve-unassigned-v1'
local preserved=assert(plan(legacy))
local rows=Caps.decode_snapshot(preserved.preserved.bodies.limits).data
assert(rows['*'].Mining.Ore==false and rows['unknown-alias'].Mining.Ore==700 and rows[H:upper()])
assert(Caps.decode_snapshot(preserved.candidate.bodies.limits).data[G].Mining.Ore==nil)
-- Explicit correlated decimal alias -> canonical guild, never inferred from text.
local alias=options();alias.limits_policy='explicit-alias-preserve-v1'
alias.limits=Caps.serialize_snapshot({['1-2-3-4']={Mining={Stone=false,Ore=250}},
    ['9-8-7-6']={Mining={Stone=900}},['*']={Mining={Ore=500}}})
alias.limit_membership={{legacy_guild='1-2-3-4',storage=W,guild=G}}
local mapped=assert(plan(alias))
assert(Caps.decode_snapshot(mapped.candidate.bodies.limits).data[G].Mining.Ore==250)
assert(Caps.decode_snapshot(mapped.candidate.bodies.limits).data[G].Mining.Stone==false)
rows=Caps.decode_snapshot(mapped.preserved.bodies.limits).data
assert(not rows['1-2-3-4'] and rows['9-8-7-6'].Mining.Stone==900 and rows['*'].Mining.Ore==500)
assert(mapped.backup.original.limits==alias.limits and mapped.evidence.limit_membership[1].legacy_guild=='1-2-3-4')
local no_alias=clone(alias);no_alias.limit_membership={}
assert(plan(no_alias).candidate.counts.limits==0)
local wrong_policy=clone(alias);wrong_policy.limits_policy='preserve-unassigned-v1';reject(wrong_policy)
local signed=options();signed.guild='ffffffff800000000000000000000001';signed.limits_policy='explicit-alias-preserve-v1'
signed.limits=Caps.serialize_snapshot({['-1--2147483648-0-1']={Mining={Stone=false}}})
signed.limit_membership={{legacy_guild='-1--2147483648-0-1',guild=signed.guild,storage=W}}
assert(Caps.decode_snapshot(plan(signed).candidate.bodies.limits).data[signed.guild].Mining.Stone==false)
-- Compose the actual callback reader and its signed-ID fixture with migration.
do
local Reader=dofile(TEST_ROOT..'/experiments/save_local_authority.lua')
local function fixture()
    local f={}
    local function obj(fields,id)
        fields.IsValid=function() return true end;fields.GetAddress=function()return id end
        return fields
    end
    f.guild=obj({Id={A=-1,B=2,C=3,D=4}},8)
    f.state=obj({Role=3,bIsDedicatedServer=false},3)
    f.world=obj({GameState=f.state,GetFullName=function()return 'World test' end},1)
    f.level=obj({OwningWorld=f.world},9)
    f.ps=obj({GuildBelongTo=f.guild,GetLevel=function()return f.level end},7)
    f.pc=obj({Role=3,PlayerState=f.ps,GetLevel=function()return f.level end},6)
    f.player=obj({PlayerController=f.pc},5)
    f.instance=obj({LocalPlayers={f.player}},2);f.world.OwningGameInstance=f.instance
    f.view=obj({World=f.world},4)
    f.engine=obj({GameInstance=f.instance,GameViewport=f.view},10)
    f.expected={world='World test',world_address=1,state_address=3,instance_address=2}
    return f
end
    local f=fixture()
    local observed=Reader.read(f.engine,f.expected)
    assert(observed.authority==true)
    local input=options();input.guild=observed.guild
    input.limits_policy='explicit-alias-preserve-v1'
    input.limit_membership={{legacy_guild=observed.legacy_guild,guild=observed.guild,storage=W}}
    input.limits=Caps.serialize_snapshot({[observed.legacy_guild]={Mining={Stone=false}},
        ['7-8-9-10']={Mining={Ore=50}}})
    local migrated=assert(plan(input))
    assert(Caps.decode_snapshot(migrated.candidate.bodies.limits).data[observed.guild].Mining.Stone==false)
    assert(Caps.decode_snapshot(migrated.preserved.bodies.limits).data['7-8-9-10'].Mining.Ore==50)
    assert(not migrated.authorized and not migrated.evidence.membership_verified)
end
-- Canonical+decimal claims with overlapping rules are ambiguous, even equal OFF.
local ambiguous=clone(alias)
ambiguous.limits=Caps.serialize_snapshot({[G]={Mining={Stone=false}},['1-2-3-4']={Mining={Stone=false}}})
ambiguous.limit_membership[2]={legacy_guild=G,guild=G,storage=W};reject(ambiguous)
local upper=options();upper.limits_policy='preserve-unassigned-v1'
upper.limits=Caps.serialize_snapshot({[H]={Mining={Stone=1}},[H:upper()]={Mining={Ore=2}}});reject(upper)
-- No implicit normalizations, unsupported schema/rows or transient identifiers.
for _,bytes in ipairs({'',o.priorities..'# future fields\n',o.priorities:gsub('\n','\r\n'),
    o.priorities:gsub('mine|2|1\nmine|3|2', 'mine|3|2\nmine|2|1'),
    o.priorities..'slot12|1|X\n',o.priorities..'mine|2|1\n',o.priorities:gsub('mine|2|1','mine|2|01'),
    o.priorities:gsub('mine|2|1','mine|2|6')}) do local bad=options();bad.priorities=bytes;reject(bad) end
for _,bytes in ipairs({'',o.limits..'bad|UnknownWork|Stone|1\n',o.limits..G..'|Mining|Ore|100\n',
    o.limits:gsub('|100','|0100'),o.limits..'# unknown schema\n'}) do local bad=options();bad.limits=bytes;reject(bad) end
for _,mutation in ipairs({
    function(x)x.enabled=false end,function(x)x.storage=H:upper() end,function(x)x.guild=string.rep('0',32) end,
    function(x)x.membership={x.membership[1],x.membership[1]} end,
    function(x)x.membership[2]={pal='mine',guild=H,storage=W} end,
    function(x)x.membership[1].storage=H end,function(x)x.membership[1].pal='slot5' end,
    function(x)x.membership[1].guild='1-2-3-4' end,function(x)x.membership={[2]=x.membership[1]} end,
    function(x)x.membership={[4097]=x.membership[1]} end,function(x)x.membership.mine=G end,
    function(x)x.limit_membership[2]=x.limit_membership[1] end,
    function(x)x.limit_membership[1].storage=H end,function(x)x.limit_membership[1].guild=H end,
    function(x)x.limit_membership[1].legacy_guild='*' end,
    function(x)x.limit_membership[1].legacy_guild='unknown-alias' end,
    function(x)x.limit_membership[1].legacy_guild='01-2-3-4' end,
    function(x)x.limit_membership[1].legacy_guild='4294967296-2-3-4' end,
    function(x)x.limit_membership[1].legacy_guild='-2147483649-2-3-4' end,
    function(x)x.limit_membership[1].legacy_guild='0-0-0-0' end,
    function(x)x.limits_policy=false end,function(x)x.max_payload_bytes=false end,
    function(x)x.limits_policy='flatten-wildcards' end,function(x)x.max_payload_bytes=65535 end,
    function(x)x.membership[1].proved=true end,function(x)x.path='somewhere' end}) do
    local bad=options();mutation(bad);reject(bad)
end
-- Tables with behavior cannot invoke engine wrappers through validation.
local meta_calls=0
local proxy=setmetatable({}, {__index=function()meta_calls=meta_calls+1;error('wrapper')end,
    __pairs=function()meta_calls=meta_calls+1;error('wrapper')end})
reject(proxy)
for _,field in ipairs({'membership','limit_membership'}) do
    local bad=options();bad[field]=proxy;reject(bad)
    bad=options();bad[field]={proxy};reject(bad)
end
assert(meta_calls==0)
-- Candidate capacity is independent of the larger legacy source/read bound.
local large=options();local records={};large.membership={}
for i=1,500 do
    local pal=string.rep('p',140)..i;records[pal]={[1]=1}
    large.membership[i]={pal=pal,storage=W,guild=G}
end
large.priorities=Store.serialize_snapshot(records,false);reject(large)
large.max_payload_bytes=262144;assert(plan(large))
-- Original FILE bytes are mandatory and retained with their integrity envelope.
-- They are not synthesized by production code from canonical payload bodies.
local missing_original=options()
assert(Planner.plan(missing_original)==nil)
local function envelope(body)
    local h=2166136261
    for i=1,#body do h=((h ~ body:byte(i))*16777619) & 0xffffffff end
    return string.format('# PWP-DATA 1 17 %d %08x\n',#body,h)..body
end
local exact=options()
exact.original_files={priorities=envelope(exact.priorities),limits=envelope(exact.limits)}
local exact_plan=assert(Planner.plan(exact))
assert(exact_plan.backup.original.priorities==exact.original_files.priorities)
assert(exact_plan.backup.original.limits==exact.original_files.limits)
assert(exact_plan.backup.original.priorities~=exact.priorities)
for _,change in ipairs({
    function(x)x.original_files.priorities=x.original_files.priorities..'x' end,
    function(x)x.original_files.limits=x.original_files.limits:gsub('1 17','1 0') end,
    function(x)x.original_files.limits=x.original_files.limits:gsub('1 17','2 17') end,
    function(x)x.original_files.limits=x.original_files.limits:gsub(' %x+\n',' deadbeef\n',1) end,
    function(x)x.original_files.limits='# comment\n'..x.limits end,
    function(x)x.original_files.limits=nil end,
}) do local bad=clone(exact);change(bad);reject(bad) end
exact.original_files.priorities='mutated'
assert(exact_plan.backup.original.priorities==envelope(exact.priorities))
-- Actual older installs retain legacy comments/order. Explicit normalization
-- checks the original decoded meaning while preserving every original byte.
do
    local legacy=options()
    local function old_body(body,baseline)
        local rows={}
        for line in body:gmatch('[^\n]+') do if line:sub(1,1)~='#' then table.insert(rows,1,line) end end
        return '# Pal Work Priority - stock limits set with !pwp limit.\r\n'
            ..(baseline and '# baseline=vanilla\r\n' or '')..table.concat(rows,'\r\n')..'\r\n'
    end
    local p_raw,l_raw=old_body(legacy.priorities,true),old_body(legacy.limits,false)
    legacy.original_files={priorities=envelope(p_raw),limits=l_raw}
    reject(legacy)
    legacy.source_policy='validated-legacy-v1'
    local result=assert(Planner.plan(legacy))
    assert(result.backup.original.priorities==envelope(p_raw) and result.backup.original.limits==l_raw)
    assert(result.evidence.source_policy=='validated-legacy-v1')
    assert(Store.decode_snapshot(result.candidate.bodies.priorities).data.mine[1]==false)
    for _,change in ipairs({
        function(x)x.original_files.limits=x.original_files.limits:gsub('|OFF','|200',1)end,
        function(x)x.original_files.priorities=envelope(p_raw:gsub('# baseline=vanilla\r\n',''))end,
        function(x)x.original_files.priorities=envelope(p_raw..'slot1|1|X\n')end,
        function(x)x.original_files.limits='# ignored\n# PWP-DATA 99\n'..l_raw end,
        function(x)x.original_files.limits='# PWP-DATA invalid\n'..l_raw end,
        function(x)x.original_files.limits=envelope('# PWP-DATA 99\n'..l_raw)end,
        function(x)x.original_files.priorities=x.original_files.priorities..'x'end,
        function(x)x.source_policy='guess'end,
    }) do local bad=clone(legacy);change(bad);reject(bad) end
    for _,prefix in ipairs({'#\tPWP-DATA','#  PWP-DATA','#PWP-DATA','# pwp-data','  # PWP-DATA'}) do
        local bad=clone(legacy);bad.original_files.limits=prefix..' invalid\n'..l_raw;reject(bad)
        bad=clone(legacy);bad.original_files.limits=envelope('# ordinary comment\n'..prefix..' invalid\n'..l_raw);reject(bad)
    end
end
-- Every returned claim/table is detached; strings preserve exact original bytes.
local original_p,original_l=o.priorities,o.limits
local candidate_p,candidate_l=p.candidate.payloads.priorities,p.candidate.payloads.limits
local independently=assert(plan(o))
o.membership[1].guild=H;o.limit_membership[1].legacy_guild='changed';o.storage=H;o.priorities='changed';o.limits='changed'
assert(p.scope.storage==W and p.evidence.membership[1].guild==G)
assert(p.backup.original.priorities==original_p and p.backup.original.limits==original_l)
p.evidence.membership[1].guild=H;p.candidate.bodies.priorities='changed';p.backup.original.limits='changed'
assert(independently.evidence.membership[1].guild==G and independently.backup.original.limits==original_l)
assert(p.candidate.payloads.priorities==candidate_p and p.candidate.payloads.limits==candidate_l)
unchanged()
print('migration planner: real canonical codecs, explicit membership/decimal aliases, X/OFF, lossless remainder, exact backup, '..checks..' clean rejections and detached outputs passed')
