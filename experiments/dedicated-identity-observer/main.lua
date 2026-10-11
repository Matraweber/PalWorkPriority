-- Diagnostic-only entry. Writes only its arm and evidence log; never save data.
local root=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/')
    :match('^(.*)/main.lua$'))
local config=dofile(root..'/config.lua')
assert(config.parameters==nil or type(config.parameters)=='boolean','invalid parameter opt-in')
local target=config.guild
assert(config.parameters~=true or target~=nil,'parameter observation requires guild')
assert(target==nil or (type(target)=='string' and #target==32 and target:match('^[0-9a-f]+$')
    and target~=string.rep('0',32)),'invalid diagnostic guild target')
local f=io.open(root..'/run.txt','r');if not f then return end
local arm=f:read(128);f:close()
if arm~='PWP_DEDICATED_IDENTITY '..config.nonce..'\n' then return end
f=assert(io.open(root..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
if config.parameters==true then
    dofile(root..'/dedicated_parameter_entry.lua').start(root,config)
    return -- never start both the identity runner and the parameter runner
end
local H=dofile(root..'/save_headless_identity_probe.lua')
local P=dofile(root..'/dedicated_identity.lua')
local R=dofile(root..'/dedicated_identity_runner.lua')
local G=target and dofile(root..'/dedicated_guild_probe.lua') or nil
local guild_stages={configuration=true,context=true,context_recheck=true,
    group_manager_resolve=true,group_manager_identity=true,group_manager_owner=true,
    guild_map=true,guild_map_count=true,guild_lookup=true,roster_array=true,roster_items=true,
    roster_count=true,roster_ids=true,roster_recheck=true,snapshot_compare=true,complete=true}
local fields={'status','directory','project_saved','path_status','expected_root_matches','world_address','state_address',
    'instance_address','manager_address','loaded_world','role','dedicated','samples',
    'timer_cancelled','verified','active','storage_grant','authority_grant',
    'query_guild','guild_query_only','identity_status','guild_status','guild_complete','guild_count',
    'guild_address','group_manager_address','guild_array_address','guild_stability','guild_stage','guild_reason'}
R.start({wall=os.time,clock=os.clock,schedule=LoopInGameThreadWithDelay,cancel=CancelDelayedAction,
    sample=function()
        local engine=FindFirstOf('GameEngine')
        local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        local system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
        local function state(c)return gameplay:GetGameState(c)end
        local function instance(c)return gameplay:GetGameInstance(c)end
        local function identity()
            return P.read(H,engine,state,instance,function()return system:GetProjectSavedDirectory()end,
                config.directory,config.saved)
        end
        local out=identity()
        out.authority_grant=false
        if not G then return out end
        local function unknown(result)
            result.identity_status=result.status
            result.query_guild,result.guild_query_only=target,true
            result.guild_status,result.guild_complete,result.guild_count='unavailable',false,'unknown'
            result.guild_stage,result.guild_reason='identity_unavailable','unavailable_or_changed'
            result.authority_grant=false
            -- Do not let identity-only stability end a failed guild trial early.
            if result.status=='context_agrees'then result.status='guild_unavailable' end
            return result
        end
        if out.status~='context_agrees'then return unknown(out)end
        local call_stage='utility_resolve'
        local ok,guild=pcall(function()
            local utility=StaticFindObject('/Script/Pal.Default__PalUtility')
            call_stage='probe_call'
            return G.read{enabled=true,engine=engine,expected=out,guild=target,
                get_state=state,get_instance=instance,
                get_manager=function(w)return utility:GetGroupManager(w)end,
                unwrap=function(v)
                    if type(v)~='userdata'then return v end
                    local yes,inner=pcall(function()if v.get then return v:get()end end)
                    return yes and inner~=nil and inner or v
                end}
        end)
        -- Guild getters may change the identity; never log a mixed sample.
        local after=identity()
        for _,key in ipairs({'status','directory','world_address','state_address','instance_address',
            'manager_address','loaded_world','role','dedicated','project_saved','path_status'})do
            if out[key]~=after[key]then
                local changed=unknown({status='unavailable',verified=false,active=false,storage_grant=false})
                changed.guild_stage='identity_changed';return changed
            end
        end
        unknown(out)
        out.guild_stage=not ok and call_stage or 'result_rejected'
        if ok and type(guild)=='table' and type(guild.stage)=='string' and guild_stages[guild.stage] then
            out.guild_stage=guild.stage
        end
        if ok and type(guild)=='table' and guild.status=='observed' and guild.complete==true
            and guild.verified==false and guild.active==false and guild.storage_grant==false
            and guild.authority_grant==false and guild.guild==target
            and math.type(guild.count)=='integer' and guild.count>=0 and guild.count<=4096 then
            out.status='context_agrees'
            out.guild_status,out.guild_complete,out.guild_count='observed',true,guild.count
            out.guild_stage,out.guild_reason='complete','observed'
            out.guild_address,out.group_manager_address=guild.guild_address,guild.group_manager_address
            out.guild_array_address=guild.array_address
        end
        return out
    end,
    emit=function(out)
        out.authority_grant=false
        if target then
            out.query_guild,out.guild_query_only,out.guild_stability=target,true,'not_evaluated'
            -- The unchanged runner checks identity stability, not a live guild
            -- roster's stability across samples. Never imply the latter.
            if out.status=='observation_complete'then out.status='identity_observation_complete'end
        end
        local parts={'PWP_DEDICATED_IDENTITY',config.nonce}
        for _,k in ipairs(fields)do
            if out[k]~=nil then parts[#parts+1]=k..'='..tostring(out[k])end
        end
        local file=assert(io.open(root..'/identity.log','a'))
        assert(file:write(table.concat(parts,' | ')..'\n'));assert(file:close())
    end})
