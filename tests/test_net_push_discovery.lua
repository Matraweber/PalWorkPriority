-- Real protocol, mocked native boundaries. Optional module override permits a
-- fail-before run against a saved baseline without replacing production files.
local root = TEST_ROOT or '.'
local module_path = NET_PUSH_DISCOVERY_MODULE or (root .. '/Scripts/net.lua')
local selected = NET_PUSH_DISCOVERY_ONLY
local passed, failures = 0, {}
local function check(name, fn)
    if selected and not name:find(selected, 1, true) then return end
    local ok, err = pcall(fn)
    if ok then passed = passed + 1
    else failures[#failures + 1] = name .. ': ' .. tostring(err) end
end

local function run(stream, options)
    local o = options or {}
    local net, push, fired, in_nested = nil, nil, false, false
    local authority, fallback, stale_reads = true, false, 0
    local counts = {transmitters=0, components=0, class=0, lookup=0}
    local peers, comps, txs, packets, builds = {}, {}, {}, {}, {}
    local class = {kind='class'}
    local global_cancel = o.change ~= 'peer' and o.change ~= 'scope'
    local function access()
        if fired and global_cancel and not in_nested then
            stale_reads = stale_reads + 1
            error('native access after cancellation')
        end
    end
    local function boundary(at)
        if in_nested or fired or at ~= o.boundary then return end
        fired = true
        if o.change == 'session' then net.begin_session(net.epoch + 1)
        elseif o.change == 'nonce' then net.local_nonce = 'replaced-server'
        elseif o.change == 'authority' then authority = false
        elseif o.change == 'peer' then
            for name, p in pairs(net.clients) do
                net.clients[name] = {server=p.server, client=p.client, guild=p.guild,
                    revisions={P=1,R=1}, next_revision={P=1,R=1}}
            end
        elseif o.change == 'scope' then
            for _, p in pairs(net.clients) do p.guild = 'changed-guild' end
        elseif o.change == 'nested' or o.change == 'nested_success' then
            in_nested = true
            -- Always another stream: P and R must share cancellation lifetime.
            if o.change == 'nested_success' then
                assert(push(stream == 'P' and 'R' or 'P'), 'nested push failed')
            else
                assert(not net.push_pals(function() return nil end), 'unexpected nested success')
            end
            in_nested = false
        else error('unknown cancellation mode') end
    end
    local function native(at)
        access()
        boundary(at)
    end
    local function make_component(i, name)
        local c = {kind='component', index=i}
        function c:GetFullName()
            native(fallback and 'fallback_name' or 'component_name')
            return name
        end
        function c:GetOuter()
            native('outer')
            return {kind='outer', GetFullName=function()
                native('outer_name')
                return o.bad_outer and 'unlisted-transmitter' or ('transmitter-' .. i)
            end}
        end
        function c:Notify_RequestClient_int32(_, message)
            access()
            packets[#packets + 1] = {index=i, name=name, message=message, nested=in_nested}
            boundary('send')
        end
        return c
    end
    for i = 1, 2 do
        comps[i] = make_component(i, 'component-' .. i)
        local t = {kind='transmitter'}
        function t:GetFullName() native('transmitter_name'); return 'transmitter-' .. i end
        function t:GetOwner()
            native('owner')
            return {kind='owner', guild=o.reject_guild and 'outsider' or ('guild-' .. i)}
        end
        if o.route ~= 'method_missing' then
            function t:GetComponentByClass(cls)
                native('component')
                assert(cls == class, 'wrong UClass')
                counts.lookup = counts.lookup + 1
                if o.route == 'method_error' then error('method unavailable') end
                if o.route == 'mismatch' then return make_component(i, 'component-' .. i .. '-decoy') end
                if o.route == 'partial' and i == 2 then return nil end
                if o.route == 'invalid' then return {kind='invalid'} end
                return comps[i]
            end
        end
        txs[i] = t
    end
    FindAllOf = function(kind)
        if kind == 'PalNetworkTransmitter' then
            native('transmitters')
            counts.transmitters = counts.transmitters + 1
            return txs
        end
        assert(kind == 'PalNetworkBaseCampComponent', 'unexpected global scan')
        native('fallback')
        counts.components, fallback = counts.components + 1, true
        if o.fallback_missing then return {} end
        -- Deliberately reverse order: peer routing must use exact names.
        return {comps[2], comps[1]}
    end
    local api = {
        has_authority=function() return authority end,
        valid=function(obj)
            access()
            if type(obj) ~= 'table' or obj.kind == 'invalid' then return false end
            local at = obj.kind .. '_valid'
            if obj.kind == 'component' and fallback then at = 'fallback_valid' end
            boundary(at)
            return true
        end,
        guild_of=function(owner) native('guild'); return owner.guild end,
        cdo=function(path)
            native('class')
            counts.class = counts.class + 1
            assert(path == '/Script/Pal.PalNetworkBaseCampComponent', 'wrong class path')
            if o.route == 'class_nil' then return nil end
            if o.route == 'class_error' then error('class unavailable') end
            return class
        end,
    }
    if o.route == 'class_method_missing' then api.cdo = nil end
    package.loaded.palapi = api
    package.loaded.log = {warn=function() end, debug=function() end, perf=false}
    FName = function(message) native('fname'); return message end
    net = assert(loadfile(module_path))()
    net.begin_session(1)
    for i = 1, 2 do
        peers[i] = {server=net.local_nonce, client='client-' .. i, guild='guild-' .. i,
            revisions={P=1,R=1}, next_revision={P=1,R=1}, misses=2}
        net.clients['component-' .. i] = peers[i]
    end
    push = function(which)
        local function record(guild)
            assert(guild == 'guild-1' or guild == 'guild-2', 'unauthorized guild data read')
            builds[#builds + 1] = guild
            boundary('rows')
            return guild:sub(-1)
        end
        if which == 'P' then
            return net.push_pals(function(guild)
                local i = record(guild)
                return {{key='PAL-' .. i, ranks={[1]=1}, prios={[1]=tonumber(i)}}}
            end)
        end
        return net.push_rules({all=function(_, guild)
            local i = record(guild)
            return {Mining={['Stone' .. i]=tonumber(i)}}
        end}, {})
    end
    local result = push(stream)
    assert(stale_reads == 0, 'pcall concealed ' .. stale_reads .. ' stale native accesses')
    return {result=result, counts=counts, peers=peers, net=net, packets=packets,
        builds=builds, fired=fired}
end

local function delivered(r, stream, scans)
    assert(r.result, 'broadcast failed')
    assert(r.counts.transmitters == 1, 'transmitter enumeration repeated')
    assert(r.counts.components == scans,
        'component scans: expected ' .. scans .. ', got ' .. r.counts.components)
    assert(#r.builds == 2 and r.builds[1] ~= r.builds[2], 'guild builders not isolated')
    assert(#r.packets == 6, 'expected two complete three-packet snapshots')
    local rows = 0
    for _, packet in ipairs(r.packets) do
        local i, message = packet.index, packet.message
        assert(packet.name == 'component-' .. i, 'sent to a decoy component')
        assert(message:find('|client-' .. i .. '|guild-' .. i .. '|' .. stream .. '|', 1, true),
            'cross-peer or cross-guild envelope')
        if message:find('PWP_V2|D|', 1, true) then
            rows = rows + 1
            local own = stream == 'P' and ('|PAL-' .. i .. '|') or ('|Stone' .. i .. '|')
            local other = stream == 'P' and ('|PAL-' .. (3-i) .. '|') or ('|Stone' .. (3-i) .. '|')
            assert(message:find(own, 1, true) and not message:find(other, 1, true), 'cross-guild payload')
        end
    end
    assert(rows == 2, 'missing guild payloads')
    for i, peer in ipairs(r.peers) do
        assert(peer.revisions[stream] == 2 and peer.next_revision[stream] == 2)
        assert(peer.misses == 0 and r.net.clients['component-' .. i] == peer,
            'fast-path miss incorrectly evicted peer')
    end
end

for _, stream in ipairs({'P','R'}) do
    check(stream .. ' fast route', function() delivered(run(stream), stream, 0) end)
    for _, route in ipairs({'mismatch','partial','invalid','class_nil','class_error',
        'class_method_missing','method_missing','method_error'}) do
        check(stream .. ' fallback ' .. route, function()
            delivered(run(stream, {route=route}), stream, 1)
        end)
    end
    for _, flag in ipairs({'reject_guild','bad_outer'}) do
        check(stream .. ' rejection ' .. flag, function()
            local r = run(stream, {[flag]=true})
            assert(not r.result and #r.packets == 0 and #r.builds == 0)
            assert(r.counts.components == 0, 'guild rejection triggered discovery fallback')
            for i, peer in ipairs(r.peers) do
                assert(peer.revisions[stream] == 1)
                if flag == 'reject_guild' then assert(r.net.clients['component-' .. i] == nil) end
            end
        end)
    end
    check(stream .. ' absent after fallback', function()
        local r = run(stream, {route='mismatch', fallback_missing=true})
        assert(not r.result and #r.packets == 0 and r.counts.components == 1)
        for i, peer in ipairs(r.peers) do
            assert(peer.misses == 3 and r.net.clients['component-' .. i] == nil)
        end
    end)
    for _, at in ipairs({'transmitters','transmitter_valid','transmitter_name','class',
        'component','component_valid','component_name','fallback','fallback_valid','fallback_name',
        'outer','outer_valid','outer_name','owner','owner_valid','guild','rows','fname','send'}) do
        for _, change in ipairs({'session','nonce','authority','peer','scope','nested','nested_success'}) do
            check(stream .. ' cancel ' .. at .. '/' .. change, function()
                local r = run(stream, {boundary=at, change=change,
                    route=at:find('fallback',1,true) and 'mismatch' or nil})
                assert(r.fired, 'invalidation boundary not reached')
                assert(not r.result, 'cancelled outer push reported success')
                local outer, nested = 0, 0
                for _, packet in ipairs(r.packets) do
                    if packet.nested then nested = nested + 1 else outer = outer + 1 end
                end
                assert(outer == (at == 'send' and 1 or 0), 'outer packets sent after cancellation')
                assert(nested == (change == 'nested_success' and 6 or 0), 'nested batch damaged')
                for _, peer in ipairs(r.peers) do
                    assert(peer.revisions[stream] == 1, 'cancelled outer revision committed')
                    if change == 'nested_success' then
                        local other = stream == 'P' and 'R' or 'P'
                        assert(peer.revisions[other] == 2 and peer.next_revision[other] == 2,
                            'nested revision lost')
                    end
                end
            end)
        end
    end
end
for i = 1, math.min(#failures, 8) do print('FAIL discovery: ' .. failures[i]) end
assert(#failures == 0, #failures .. ' discovery cases failed; ' .. passed .. ' passed')
assert(passed > 0, 'no discovery cases selected')
print('push discovery: ' .. passed .. ' cases passed')
