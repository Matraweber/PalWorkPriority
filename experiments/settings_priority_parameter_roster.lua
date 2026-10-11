-- Diagnostic only. An identity/group cross-check is NOT world membership proof.
-- Caller brackets this synchronous read with fresh world/authority observations.
-- enumerate must supply a fresh FindAllOf('PalIndividualCharacterParameter') Lua
-- array. No engine wrappers escape this call or survive into another callback.
-- SDK PalIndividualCharacterParameter.h: IndividualId; GetGroupId() const FGuid.
local M = {}
local function plain(t) return type(t)=='table' and getmetatable(t)==nil end
local function key(k)
    return type(k)=='string' and #k==64 and k:match('^[0-9A-F]+$')
        and k:sub(33)~=string.rep('0',32)
end
local function guid(g,unwrap)
    local parts={}
    for _,field in ipairs({'A','B','C','D'}) do
        local n=unwrap(g[field])
        assert(type(n)=='number' and math.tointeger(n) and n>=-2147483648 and n<=4294967295)
        parts[#parts+1]=string.format('%08x',n%4294967296)
    end
    local s=table.concat(parts);assert(s~=string.rep('0',32));return s
end
local function identity(id,api)
    local copied={}
    for _,name in ipairs({'PlayerUId','InstanceId'})do
        local g={};copied[name]=g
        for _,field in ipairs({'A','B','C','D'})do
            local n=api.unwrap(id[name][field])
            assert(type(n)=='number' and math.tointeger(n) and n>=-2147483648 and n<=4294967295)
            g[field]=n
        end
    end
    local k=api.instance_key(copied);assert(key(k));return k
end
function M.read(enumerate,api,expected_guild,wanted,resolve_world)
    local out={complete=false,reason='invalid_input',records={},matched=0,
        activation_allowed=false,world_membership_proven=false}
    if resolve_world~=nil and type(resolve_world)~='function' then return out end
    if type(enumerate)~='function' or not plain(api) or type(api.unwrap)~='function'
        or type(api.instance_key)~='function' or not plain(wanted)
        or type(expected_guild)~='string' or #expected_guild~=32
        or not expected_guild:match('^[0-9a-f]+$') or expected_guild==string.rep('0',32) then return out end
    local requested,n={},0
    for k,v in pairs(wanted) do
        if not key(k) or v~=true then return out end
        requested[k]=true;n=n+1;if n>4096 then return out end
    end
    local stage='enumeration_unavailable'
    local ok=pcall(function()
        local params=enumerate()
        assert(plain(params))
        local count=0
        for i in pairs(params) do
            assert(math.type(i)=='integer' and i>=1 and i<=32768)
            count=count+1;assert(count<=32768)
        end
        local seen,records={},{}
        stage='parameter_unreadable'
        for i=1,count do
            local p=api.unwrap(params[i]);assert(p and p:IsValid()==true)
            local k=identity(p.IndividualId,api)
            assert(key(k))
            if requested[k] then
                assert(not seen[k]);seen[k]=true
                local address=api.unwrap(p:GetAddress())
                assert(math.type(address)=='integer' and address>0)
                local group=guid(p:GetGroupId(),api.unwrap)
                -- Re-read the same fresh parameter after the group UFunction.
                assert(p:IsValid()==true and api.unwrap(p:GetAddress())==address
                    and identity(p.IndividualId,api)==k)
                local world_resolved=false
                if resolve_world then
                    stage='world_lookup_rejected'
                    -- Forward the original reflected struct, never the Lua copy
                    -- used for strict validation/formatting. No wrapper escapes.
                    local native_id=p.IndividualId
                    assert(identity(native_id,api)==k)
                    local resolved=api.unwrap(resolve_world(native_id))
                    assert(resolved and resolved:IsValid()==true
                        and api.unwrap(resolved:GetAddress())==address
                        and identity(resolved.IndividualId,api)==k
                        and guid(resolved:GetGroupId(),api.unwrap)==group)
                    assert(p:IsValid()==true and api.unwrap(p:GetAddress())==address
                        and identity(p.IndividualId,api)==k)
                    world_resolved=true
                    stage='parameter_unreadable'
                end
                records[#records+1]={key=k,group=group,matches=group==expected_guild,address=address,
                    world_resolved=world_resolved}
            end
        end
        table.sort(records,function(a,b)return a.key<b.key end)
        local matched=0;for _,r in ipairs(records)do if r.matches then matched=matched+1 end end
        out.records,out.matched=records,matched
        out.requested,out.observed=n,#records
    end)
    out.complete=ok;out.reason=ok and 'observed' or stage
    return out
end
return M
