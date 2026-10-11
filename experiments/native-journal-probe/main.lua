-- One-shot, synthetic native journal integration. Never real settings.
local dir=assert(debug.getinfo(1,'S').source:gsub('^@',''):gsub('\\','/'):match('^(.*)/main.lua$'))
local f=io.open(dir..'/run.txt','r');if not f then return end
local request,extra=f:read(128),f:read(1);assert(f:close())
local nonce=not extra and request and request:match('^PWP_JOURNAL_PROBE ([%w%-]+)%s*$')
if not nonce or #nonce>64 then return end
f=assert(io.open(dir..'/run.txt','w'));assert(f:write('DISABLED\n'));assert(f:close())
local stopped=false
local function log(text)
    local out=assert(io.open(dir..'/journal.log','a'))
    assert(out:write(os.date('!%Y-%m-%dT%H:%M:%SZ ')..nonce..' '..text..'\n'));assert(out:close())
end
local function guarded(fn)
    return function(...)
        if stopped then return end
        local ok,err=pcall(fn,...)
        if not ok then stopped=true;pcall(log,'FAIL '..tostring(err)..'; uncertainty retained; no retry') end
    end
end
local function context_diagnostic()
    -- One synchronous game-thread observation before native admission. Engine,
    -- CDO and getter closures die with this call; no worker captures any of them.
    local Pair=dofile(dir..'/experiments/save_context_pair_probe.lua')
    local helpers=require('UEHelpers')
    local engine=helpers.GetEngine()
    local cdo=helpers.GetGameplayStatics(true) -- force a fresh GameplayStatics CDO
    local available=cdo and cdo:IsValid()==true
    local out=Pair.read(engine,
        available and function(ctx) return cdo:GetGameState(ctx) end or nil,
        available and function(ctx) return cdo:GetGameInstance(ctx) end or nil)
    assert(type(out)=='table' and getmetatable(out)==nil, 'context result shape')
    assert(type(out.status)=='string' and type(out.agrees)=='boolean'
        and out.verified==false and out.active==false and out.storage_grant==false,
        'context must remain diagnostic only')
    local keys={'status','agrees','verified','active','storage_grant','world','directory',
        'role','dedicated','world_address','state_address','instance_address','manager_address',
        'identity_selected','identity_selected_status','identity_autosave','identity_autosave_status',
        'identity_loaded_world','identity_loaded_status'}
    table.sort(keys)
    local parts={}
    for _,key in ipairs(keys) do
        local value=rawget(out,key)
        local kind=type(value)
        assert(kind=='nil' or kind=='string' or kind=='boolean'
            or (kind=='number' and value==value and value>-math.huge and value<math.huge),
            'non-scalar context field')
        local text=kind=='string' and value:sub(1,512):gsub('[%c|=]','?') or tostring(value)
        parts[#parts+1]=key..'='..text
    end
    -- A returned disagreement is useful evidence, not a synthetic-destination
    -- veto. Throws/malformed results instead reach guarded() and stop before IO.
    log('CONTEXT_PAIR diagnostic_only=true storage_grant=false '..table.concat(parts,' | '):sub(1,8192))
end
log('ARMED synthetic only; delay=90000; phases=3; NOT production settings')
ExecuteInGameThreadWithDelay(90000,guarded(function()
    context_diagnostic()
    local native=assert(package.loadlib(dir..'/pwp_journal_probe.dll','luaopen_pwp_journal_probe'))
    local function invoke(command,ticket)
        local r=table.pack(native(command,ticket));assert(r.n==5,'native result shape')
        for i=1,5 do assert(math.type(r[i])=='integer','native result type') end
        assert(r[2]>0 and r[3]>=0 and r[4]>=r[3] and r[5]>0,'native timing')
        return r
    end
    local base=invoke(0,0);assert(base[1]==1,'control-thread binding')
    local phase,pending=0,false
    local function run(ticket)
        assert(not pending and ticket==phase+1 and ticket<=3,'phase bound')
        local this=ticket -- immutable dispatch identity retained by every closure
        phase=this;pending=true
        local admitted=invoke(this==1 and 1 or 5,this)
        assert(admitted[1]==1 and admitted[2]==base[2],'admission')
        log('START phase='..this..' game='..base[2])
        ExecuteInGameThreadWithDelay(10000,guarded(function()
            if pending and phase==this then error('timeout; no retry') end
        end))
        ExecuteAsync(guarded(function()
            local result=invoke(2,this)
            ExecuteInGameThread(guarded(function()
                assert(phase==this and pending,'stale completion')
                local polled=invoke(3,this)
                assert(result[1]==1 and polled[1]==1,'journal outcome')
                assert(result[2]~=base[2] and polled[2]==base[2],'thread route')
                assert(result[5]==base[5] and result[3]>=admitted[4] and polled[3]>=result[4],'timing order')
                log('RESULT phase='..this..' values='..table.concat(result,',',1,5)..' completion='..polled[2])
                assert(invoke(4,this)[1]==1,'consume');pending=false
                if this<3 then
                    local next_ticket=this+1
                    ExecuteInGameThreadWithDelay(15000,guarded(function() run(next_ticket) end))
                else
                    assert(invoke(6,this)[1]==1,'retire release')
                    log('COMPLETE native phases=3 owner_released=true independent_readback_required=true durable_ack=false')
                    stopped=true
                end
            end))
        end))
    end
    run(1)
end))
