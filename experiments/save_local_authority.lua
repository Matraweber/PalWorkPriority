-- Fresh callback-local local-host/guild evidence. No IO, discovery, caching,
-- lifecycle grant or native admission. Call with a freshly resolved engine and
-- the scalar context from save_context_pair_probe/save_local_binding.
local M={}
local function integer(v)
    if type(v)=='userdata' then v=v:get() end
    return type(v)=='number' and math.tointeger(v) or nil
end
local function address(v)
    assert(v and v:IsValid()==true,'unavailable object')
    local n=integer(v:GetAddress());assert(n and n>0,'unavailable address');return n
end
local function guild_id(g)
    local hex,legacy={},{}
    for _,k in ipairs({'A','B','C','D'}) do
        local n=integer(g[k]);assert(n and n>=-2147483648 and n<=4294967295,'invalid GUID word')
        hex[#hex+1]=string.format('%08x',n%4294967296)
        legacy[#legacy+1]=tostring(n) -- match palapi.guid_key, including signed words
    end
    local canonical=table.concat(hex)
    assert(canonical~=string.rep('0',32),'unset guild')
    return canonical,table.concat(legacy,'-')
end
function M.read(engine,expected)
    local unavailable={authority_status='unavailable',guild_status='unavailable'}
    if type(expected)~='table' or getmetatable(expected)~=nil then return unavailable end
    local wanted={world=expected.world,world_address=expected.world_address,
        state_address=expected.state_address,instance_address=expected.instance_address}
    local ok,result=pcall(function()
        address(engine)
        local function snapshot()
            local view=engine.GameViewport;address(view)
            local world=view.World;local wid=address(world)
            local instance=world.OwningGameInstance;local iid=address(instance)
            local state=world.GameState;local sid=address(state)
            assert(address(engine.GameInstance)==iid,'instance mismatch')
            assert(wid==wanted.world_address and iid==wanted.instance_address
                and sid==wanted.state_address and world:GetFullName()==wanted.world,'context mismatch')
            assert(integer(state.Role)==3 and state.bIsDedicatedServer==false,'not local authority')
            local player=instance.LocalPlayers[1];local lid=address(player)
            local pc=player.PlayerController;local pid=address(pc)
            assert(integer(pc.Role)==3,'controller not authoritative')
            local level=pc:GetLevel();address(level)
            assert(address(level.OwningWorld)==wid,'controller belongs to another world')
            local ps=pc.PlayerState;local psid=address(ps)
            local pslevel=ps:GetLevel();address(pslevel)
            assert(address(pslevel.OwningWorld)==wid,'player state belongs to another world')
            local guild=ps.GuildBelongTo;local gid=address(guild)
            local canonical,legacy=guild_id(guild.Id)
            return {world_address=wid,state_address=sid,instance_address=iid,
                player_address=lid,controller_address=pid,player_state_address=psid,guild_address=gid,
                guild=canonical,legacy_guild=legacy}
        end
        local first,last=snapshot(),snapshot()
        for k,v in pairs(first) do assert(last[k]==v,'identity changed while reading') end
        first.authority_status,first.authority,first.guild_status='read',true,'format_valid'
        return first
    end)
    return ok and result or unavailable
end
return M
