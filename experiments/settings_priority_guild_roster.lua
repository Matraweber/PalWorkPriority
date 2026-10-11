-- Declared property route, not live proof or an authority/admission grant.
-- Call synchronously with fresh LocalAuthority scalars plus Pair world fields.
-- No discovery, IO, module dependencies, cached wrappers, or absence/deletion
-- inference. Includes ALL guild entries, including human IDs.
-- SDK Source/Pal/Public: PalGroupBase.h (IndividualIdArray),
-- PalGroupIndividualCharacterHandleIdArray.h (IndividualCharacterHandleIds),
-- FastPalIndividualCharacterHandleIdArray.h (Items),
-- PalIndividualCharacterHandleId.h (HandleId). Retain observed guild.Id spelling
-- from save_local_authority.lua, despite the header spelling ID.
local M = {}
local MAX_IDS = 4096
local ADDRESS_FIELDS = {'world_address', 'state_address', 'instance_address',
    'player_address', 'controller_address', 'player_state_address', 'guild_address'}
local OPTIONAL_ADDRESSES = {'engine_address', 'viewport_address', 'manager_address'}
local function integer(v)
    return type(v) == 'number' and math.tointeger(v) or nil
end
local function positive(v)
    local n = integer(v)
    return n and n > 0
end
local function canonical(v)
    return type(v) == 'string' and #v == 32 and v:match('^[0-9a-f]+$')
        and v ~= string.rep('0', 32)
end

-- Optional visitor is trusted synchronous read-only code. It must not retain
-- the native identity, yield, or authorize writes. A later array/context failure
-- invalidates the entire observation, including any visitor-produced scalars.
function M.read(engine, expected, api, visit, visit_key)
    local out = {complete=false, keys={}, count=0, reason='invalid_dependencies'}
    if type(api) ~= 'table' or getmetatable(api) ~= nil
        or type(rawget(api, 'unwrap')) ~= 'function'
        or type(rawget(api, 'instance_key')) ~= 'function' then return out end
    if visit ~= nil and type(visit) ~= 'function' then return out end
    if visit_key ~= nil and (type(visit) ~= 'function' or type(visit_key) ~= 'string'
        or #visit_key ~= 64 or not visit_key:match('^[0-9A-F]+$')) then return out end
    out.reason = 'invalid_expected'
    if type(expected) ~= 'table' or getmetatable(expected) ~= nil then return out end
    local wanted = {}
    for _, k in ipairs(ADDRESS_FIELDS) do
        local v = rawget(expected, k)
        if not positive(v) then return out end
        wanted[k] = v
    end
    for _, k in ipairs(OPTIONAL_ADDRESSES) do
        local v = rawget(expected, k)
        if v ~= nil and not positive(v) then return out end
        wanted[k] = v
    end
    wanted.guild, wanted.legacy_guild = rawget(expected, 'guild'), rawget(expected, 'legacy_guild')
    local world = rawget(expected, 'world')
    if not canonical(wanted.guild) or type(wanted.legacy_guild) ~= 'string'
        or #wanted.legacy_guild == 0 or #wanted.legacy_guild > 64
        or not wanted.legacy_guild:match('^[%d%-]+$')
        or type(world) ~= 'string' or #world == 0 or #world > 512 or world:find('%c') then return out end
    -- World name is caller evidence only: no GetFullName/GetLevel UFunctions.
    -- Address checks bind this read to the externally observed chain.
    local unwrap, instance_key = api.unwrap, api.instance_key
    local function address(obj)
        assert(obj ~= nil and obj:IsValid() == true)
        local n = unwrap(obj:GetAddress())
        assert(positive(n))
        return n
    end
    local function snapshot()
        local s = {engine_address=address(engine)}
        local view = engine.GameViewport; s.viewport_address = address(view)
        local w = view.World; s.world_address = address(w)
        local inst = w.OwningGameInstance; s.instance_address = address(inst)
        s.state_address = address(w.GameState)
        assert(address(engine.GameInstance) == s.instance_address)
        if wanted.manager_address then s.manager_address = address(inst.SaveGameManager) end
        local players = inst.LocalPlayers
        local player_count = integer(#players)
        assert(player_count and player_count >= 1 and player_count <= 64)
        local player = players[1]; s.player_address = address(player)
        local pc = player.PlayerController; s.controller_address = address(pc)
        local ps = pc.PlayerState; s.player_state_address = address(ps)
        local guild = ps.GuildBelongTo; s.guild_address = address(guild)
        local id, hex, legacy = guild.Id, {}, {}
        for _, field in ipairs({'A', 'B', 'C', 'D'}) do
            local n = integer(unwrap(id[field]))
            assert(n and n >= -2147483648 and n <= 4294967295)
            hex[#hex+1] = string.format('%08x', n % 4294967296)
            legacy[#legacy+1] = tostring(n)
        end
        s.guild, s.legacy_guild = table.concat(hex), table.concat(legacy, '-')
        for k, v in pairs(wanted) do assert(s[k] == v) end
        local array = guild.IndividualIdArray
        s.array_address = address(array)
        local items = array.IndividualCharacterHandleIds.Items
        assert(type(items) == 'table' or type(items) == 'userdata')
        local n = integer(#items)
        assert(n and n >= 0 and n <= MAX_IDS)
        -- Plain Lua fixtures must also be dense. Engine arrays use only # and
        -- indexed property reads; never call methods on arrays or structs.
        if type(items) == 'table' and getmetatable(items) == nil then
            local count = 0
            for i in next, items do
                count = count + 1
                assert(count <= MAX_IDS and integer(i) and i >= 1 and i <= n)
            end
            assert(count == n)
        end
        s.count = n
        return s, items
    end
    local function identity_key(id)
        assert(id ~= nil)
        -- Reject malformed words before a formatter can floor or wrap them.
        for _, name in ipairs({'PlayerUId', 'InstanceId'}) do
            for _, field in ipairs({'A', 'B', 'C', 'D'}) do
                local word = unwrap(id[name][field])
                assert(type(word) == 'number' and math.tointeger(word)
                    and word >= -2147483648 and word <= 4294967295)
            end
        end
        local k = instance_key(id)
        assert(type(k) == 'string' and #k == 64 and k:match('^[0-9A-F]+$')
            and k:sub(33) ~= string.rep('0', 32))
        return k
    end
    local stage = 'context_or_array_unavailable'
    local ok = pcall(function()
        local before, items = snapshot()
        out.array_address = before.array_address
        stage = 'invalid_or_duplicate_id'
        local keys, seen = {}, {}
        for i = 1, before.count do
            -- UE4SS out-of-range indexing can AddZeroed: refuse before access.
            assert(integer(#items) == before.count)
            local item = unwrap(items[i])
            assert(item ~= nil)
            local id = item.HandleId
            assert(id ~= nil)
            local k = identity_key(id)
            assert(not seen[k])
            seen[k] = true
            keys[#keys+1] = k
            if visit and (visit_key == nil or visit_key == k) then
                visit(k, id)
                -- The native call may have changed the slot without changing
                -- array length. Reacquire through the checked chain; do not
                -- dereference the old struct after the call.
                local current, fresh_items = snapshot()
                for field, value in pairs(before) do assert(current[field] == value) end
                assert(integer(#fresh_items) == before.count)
                local fresh_item = unwrap(fresh_items[i])
                assert(fresh_item and identity_key(fresh_item.HandleId) == k)
                items = fresh_items
            end
        end
        stage = 'context_or_array_changed'
        local after = snapshot()
        for k, v in pairs(before) do assert(after[k] == v) end
        table.sort(keys)
        out.keys, out.count = keys, #keys
    end)
    out.complete = ok
    out.reason = ok and 'observed' or stage -- never stringify a thrown wrapper
    return out
end

return M
