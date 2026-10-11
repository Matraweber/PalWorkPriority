-- Read-only, default-off prototype; no authority/storage grants or native driver.
-- Declared SDK route (PalworldModdingKit/Source/Pal/Public):
-- PalUtility.h GetGroupManager(WorldContextObject), BlueprintPure;
-- PalGroupManager.h : PalWorldSubsystem, reflected GuildMap<FGuid,GuildBase*>;
-- PalGroupBase.h GetId(), IndividualIdArray; existing handle-array property route.
-- SDK .cpp is a stub: reflection/outer behavior needs independent native proof.
-- No FindAllOf, connected player, viewport, guessed class or camp-membership inference.
local M={}
local MAX_GUILDS,MAX_IDS=128,4096
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function canonical(s)
    return type(s)=='string' and #s==32 and s:match('^[0-9a-f]+$') and s~=string.rep('0',32)
end
local function integer(n)return math.type(n)=='integer' end
local function address(o)
    assert(o and o:IsValid()==true)
    local n=o:GetAddress();assert(integer(n) and n>0);return n
end
local function equal(a,b)
    if type(a)~=type(b)then return false end
    if type(a)~='table'then return a==b end
    for k,v in pairs(a)do if not equal(v,b[k])then return false end end
    for k in pairs(b)do if a[k]==nil then return false end end
    return true
end
local context_fields={'directory','world_address','state_address','instance_address','manager_address','loaded_world'}
function M.read(o)
    local failed={status='unavailable',complete=false,verified=false,active=false,
        storage_grant=false,authority_grant=false,keys={},stage='configuration',reason='unavailable_or_changed'}
    if not plain(o) or o.enabled~=true then failed.status='disabled';failed.reason='disabled';return failed end
    local stage='configuration'
    local ok,result=pcall(function()
        assert(plain(o.expected) and canonical(o.guild) and canonical(o.expected.directory))
        local expected={};for _,k in ipairs(context_fields)do expected[k]=o.expected[k]end
        for _,k in ipairs({'world_address','state_address','instance_address','manager_address'})do
            assert(integer(expected[k]) and expected[k]>0)
        end
        assert(type(expected.loaded_world)=='boolean')
        local engine,wanted=o.engine,o.guild
        local get_state,get_instance,get_manager,unwrap=o.get_state,o.get_instance,o.get_manager,o.unwrap
        assert(type(get_state)=='function' and type(get_instance)=='function'
            and type(get_manager)=='function' and type(unwrap)=='function')
        local function guid(raw,allow_zero)
            local parts={}
            for _,k in ipairs({'A','B','C','D'})do
                local n=unwrap(raw[k]);assert(integer(n) and n>=-2147483648 and n<=4294967295)
                parts[#parts+1]=string.format('%08x',n%4294967296)
            end
            local s=table.concat(parts);assert(allow_zero or s~=string.rep('0',32));return s
        end
        local function context(resolve_manager)
            stage='context'
            address(engine)
            local instance=engine.GameInstance;assert(address(instance)==expected.instance_address)
            local state=get_state(instance);assert(address(state)==expected.state_address)
            assert(address(get_instance(state))==expected.instance_address)
            local level=state:GetLevel();address(level)
            local world=level.OwningWorld;assert(address(world)==expected.world_address)
            assert(address(world.OwningGameInstance)==expected.instance_address
                and address(world.GameState)==expected.state_address)
            local directory=state.WorldSaveDirectoryName
            if type(directory)~='string'then directory=directory:ToString()end
            assert(type(directory)=='string' and directory:lower()==expected.directory)
            assert(state.Role==3 and state.bIsDedicatedServer==true)
            local save=instance.SaveGameManager
            assert(address(save)==expected.manager_address and address(save:GetOuter())==expected.instance_address)
            assert(save.bIsLoadedWorldSaveData==expected.loaded_world)
            local manager,mid
            if resolve_manager~=false then
                stage='group_manager_resolve';manager=get_manager(world)
                stage='group_manager_identity';mid=address(manager)
            end
            -- World-subsystem outer is checked, never inferred from its class/name.
            if manager then stage='group_manager_owner';assert(address(manager:GetOuter())==expected.world_address)end
            stage='context_recheck'
            assert(address(get_state(instance))==expected.state_address
                and address(get_instance(state))==expected.instance_address)
            local lastlevel=state:GetLevel();address(lastlevel)
            local lastdirectory=state.WorldSaveDirectoryName
            if type(lastdirectory)~='string'then lastdirectory=lastdirectory:ToString()end
            assert(type(lastdirectory)=='string' and lastdirectory:lower()==expected.directory
                and state.Role==3 and state.bIsDedicatedServer==true
                and (not manager or address(manager:GetOuter())==expected.world_address)
                and address(save:GetOuter())==expected.instance_address)
            assert(address(lastlevel.OwningWorld)==expected.world_address
                and address(world.OwningGameInstance)==expected.instance_address
                and address(world.GameState)==expected.state_address
                and address(engine.GameInstance)==expected.instance_address
                and address(instance.SaveGameManager)==expected.manager_address
                and save.bIsLoadedWorldSaveData==expected.loaded_world)
            return manager,mid
        end
        local function snapshot(manager,mid)
            stage='guild_map'
            local map=manager.GuildMap;assert(map and map:type()=='TMap')
            stage='guild_map_count'
            local count=#map;assert(integer(count) and count>=0 and count<=MAX_GUILDS)
            local seen,signature,found,n={}, {},nil,0
            stage='guild_lookup'
            map:ForEach(function(k,v)
                n=n+1;assert(n<=count and n<=MAX_GUILDS and #map==count)
                local key=guid(unwrap(k));assert(not seen[key]);seen[key]=true
                local guild=unwrap(v);local id=address(guild)
                assert(guid(guild:GetId())==key)
                signature[key]=id
                if key==wanted then found=guild end
                if n==count then return true end
            end)
            assert(n==count and #map==count and found,'guild absent or map incomplete')
            local gid=address(found)
            stage='roster_array'
            local array=found.IndividualIdArray;local aid=address(array)
            stage='roster_items'
            local items=array.IndividualCharacterHandleIds.Items
            assert(type(items)=='table' or type(items)=='userdata')
            stage='roster_count'
            local size=#items;assert(integer(size) and size>=0 and size<=MAX_IDS)
            if plain(items)then
                local entries=0
                for i in next,items do entries=entries+1;assert(integer(i) and i>=1 and i<=size)end
                assert(entries==size)
            end
            local keys,ids={},{}
            stage='roster_ids'
            for i=1,size do
                assert(#items==size) -- never index beyond checked native length
                local item=unwrap(items[i]);local id=item.HandleId
                local key=(guid(id.PlayerUId,true)..guid(id.InstanceId)):upper()
                assert(not ids[key]);ids[key]=true;keys[#keys+1]=key
            end
            stage='roster_recheck'
            assert(#items==size and #map==count and guid(found:GetId())==wanted
                and address(found.IndividualIdArray)==aid)
            table.sort(keys)
            return {group_manager_address=mid,guild_address=gid,array_address=aid,
                map=signature,keys=keys,count=size}
        end
        local function once()
            local manager,mid=context()
            local before=snapshot(manager,mid)
            local current,after=context()
            stage='group_manager_owner'
            assert(after==mid and address(current:GetOuter())==expected.world_address)
            -- Context getters can revoke a guild or replace its roster. Recopy
            -- through the freshly resolved manager before accepting this pass.
            local final=snapshot(current,after)
            stage='snapshot_compare'
            assert(equal(before,final))
            stage='group_manager_owner'
            assert(address(current)==after and address(current:GetOuter())==expected.world_address)
            return final
        end
        -- Full second read catches observed same-length entry replacement, not just
        -- size changes. Ordered reads are not atomic and cannot exclude unseen ABA.
        local first,second=once(),once();stage='snapshot_compare';assert(equal(first,second))
        -- Final scalar/ownership reproof after roster callbacks. Do not invoke
        -- the group resolver again: that would reopen the late-map transition.
        context(false)
        return {status='observed',stage='complete',reason='observed',complete=true,verified=false,active=false,storage_grant=false,
            authority_grant=false,guild=wanted,directory=expected.directory,keys=first.keys,count=first.count,
            group_manager_address=first.group_manager_address,guild_address=first.guild_address,
            array_address=first.array_address,role=3,dedicated=true}
    end)
    if ok then return result end
    failed.stage=stage
    return failed
end
return M
