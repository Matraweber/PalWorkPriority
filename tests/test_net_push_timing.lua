-- Real transport/profiler: instrumentation must not alter recipients, packets,
-- incomplete-roster refusal, send failure, or revision commitment.
local clock = 0
os.clock = function() return clock end
os.time = function() return 1900000000 end
FName = function(s) return s end
local log = require('log')
local function run(enabled, failure, direct)
    clock = 0
    local packets, operations = {}, {}
    local function step(name, ms)
        operations[#operations+1] = name
        clock = clock + ms/1000
    end
    local tx = {}
    function tx:GetFullName() return 'tx-A' end
    function tx:GetOwner() step('owner', 2); return {guild='guild-A'} end
    local comp = {}
    function comp:GetFullName() return 'component-A' end
    function comp:GetOuter() return tx end
    function comp:Notify_RequestClient_int32(_, message)
        step('send', 3)
        if failure == 'send' then error('injected send failure') end
        packets[#packets+1] = message
    end
    FindAllOf = function(class)
        if class == 'PalNetworkBaseCampComponent' then step('components', 10); return {comp} end
        assert(class == 'PalNetworkTransmitter')
        step('transmitters', 20); return {tx}
    end
    package.loaded.palapi = {
        valid=function(o) return type(o)=='table' end,
        has_authority=function() return true end,
        guild_of=function(owner) return failure == 'guild' and 'guild-B' or owner.guild end,
    }
    package.loaded.net = nil
    local net = require('net')
    net.begin_session(1)
    local peer = {guild='guild-A',server=net.local_nonce,client='client',
        revisions={P=1,R=1},next_revision={P=1,R=1}}
    net.clients['component-A'] = peer
    log.set_perf(enabled); log.reset_marks()
    local result = net.push_pals(function(guild)
        assert(guild == 'guild-A', 'cross-guild roster disclosure')
        step('roster', 30)
        if failure == 'roster' then return nil, 'incomplete' end
        return {{key='PAL-A',ranks={[1]=3},prios={[1]=false}}}
    end, direct and comp or nil, 'PAL-A')
    local snapshot = log.snapshot()
    return {result=result, packets=table.concat(packets,'\n'),
        operations=table.concat(operations,','),revision=peer.revisions.P,
        next_revision=peer.next_revision.P, present=net.clients['component-A']~=nil,
        snapshot=snapshot}
end
local direct_off, direct_on = run(false, 'none', true), run(true, 'none', true)
assert(direct_on.result and direct_on.packets == direct_off.packets)
assert(direct_on.operations == direct_off.operations and direct_on.revision == 2)
local direct_seen = false
for _, row in ipairs(direct_on.snapshot.rows) do
    assert(row.name ~= 'network push: component scan')
    if row.name == 'network push: direct guild' then
        direct_seen = true
        assert(row.timed_samples == 1 and math.abs(row.total_ms-22)<0.0001)
    end
end
assert(direct_seen)
-- Prevent expected failure warnings from writing to either sink.
log.warn = function() end
for _, failure in ipairs({'none','roster','send','guild'}) do
    local off, on = run(false,failure), run(true,failure)
    for _, field in ipairs({'result','packets','operations','revision','next_revision','present'}) do
        assert(off[field] == on[field], failure .. ': altered ' .. field)
    end
    assert(#off.snapshot.rows == 0, 'disabled push created timing buckets')
    if failure == 'none' then
        assert(on.result and on.revision == 2 and on.packets:find('|U|',1,true))
        local rows = {}
        for _, row in ipairs(on.snapshot.rows) do rows[row.name] = row end
        for name, ms in pairs({['component scan']=10,transmitters=20,['peer guild']=2,roster=30}) do
            local row = assert(rows['network push: '..name])
            assert(row.timed_samples==1 and math.abs(row.total_ms-ms)<0.0001, name)
        end
        local sends = assert(rows['network push: send message'])
        assert(sends.timed_samples > 0 and math.abs(sends.mean_ms-3)<0.0001)
    else
        assert(not on.result and on.revision == 1, 'failed push committed revision')
        if failure == 'guild' then assert(not on.present and on.packets=='') end
    end
end
