-- One-shot read-only world/guild observation. Never grants IO or touches settings.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local marker=f:read('*a');assert(f:close())
local nonce=marker:match('^PWP_AUTHORITY_READ ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local function report(label,fields)
    local rows={os.date('!%Y-%m-%dT%H:%M:%SZ'),nonce,label}
    local keys={};for k in pairs(fields or {}) do keys[#keys+1]=k end;table.sort(keys)
    for _,k in ipairs(keys) do
        local v=fields[k];assert(type(v)=='string' or type(v)=='boolean' or type(v)=='number')
        rows[#rows+1]=k..'='..tostring(v):gsub('[\r\n\t]',' ')
    end
    local out=assert(io.open(dir..'/authority.log','a'))
    assert(out:write(table.concat(rows,'\t')..'\n'));assert(out:close())
end
report('armed',{read_only=true,delay_ms=90000})
ExecuteInGameThreadWithDelay(90000,function()
    local ok,why=pcall(function()
        local Pair=dofile(dir..'/experiments/save_context_pair_probe.lua')
        local Authority=dofile(dir..'/experiments/save_local_authority.lua')
        local h=require('UEHelpers')
        local engine=h.GetEngine()
        local cdo=h.GetGameplayStatics(true)
        assert(cdo and cdo:IsValid()==true,'GameplayStatics unavailable')
        local pair=Pair.read(engine,function(ctx)return cdo:GetGameState(ctx)end,
            function(ctx)return cdo:GetGameInstance(ctx)end)
        assert(pair.status=='context_agrees' and pair.agrees==true,'world context unavailable')
        local observed=Authority.read(engine,pair)
        assert(observed.authority_status=='read' and observed.authority==true
            and observed.guild_status=='format_valid','fresh local authority unavailable')
        observed.storage=pair.directory
        observed.read_only=true;observed.activation_allowed=false
        report('observed',observed)
    end)
    if not ok then report('failed',{reason=tostring(why):sub(1,1000),activation_allowed=false}) end
end)
