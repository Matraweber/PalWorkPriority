local path=TEST_ROOT..'/experiments/ue4ss-save-transition/Scripts/main.lua'
local file=assert(io.open(path,'r'))
local code=file:read('*a');file:close()
local Probe=dofile(TEST_ROOT..'/experiments/save_identity_probe.lua')
local target='World /Game/Pal/Maps/MainWorld_5/PL_MainWorld5.PL_MainWorld5'
local id=string.rep('a',32)

local function fixture(options)
    options=options or {}
    local s={now=0,control=options.control or 'PWP_TRANSITION_RUN fixture',
        logs={},cancels=0,reads=0,loads=0,forbidden=0}
    local env={}
    setmetatable(env,{__index=function(_,key)
        error('unexpected driver global: '..tostring(key))
    end})
    for _,key in ipairs({'assert','debug','ipairs','pcall','table','tostring'}) do env[key]=_G[key] end
    local function object(fields)
        fields.IsValid=function() return true end
        return setmetatable({}, {
            __index=function(_,key)
                if fields[key]~=nil then return fields[key] end
                -- Count even accesses swallowed by the probe's pcall.
                s.forbidden=s.forbidden+1
                error('unexpected property or native getter: '..tostring(key))
            end,
            __newindex=function(_,key)
                s.forbidden=s.forbidden+1
                error('game state write: '..tostring(key))
            end
        })
    end
    local generation=0
    function s.world(name,selected,autosave)
        -- Fresh native identities and owner links accompany replacement wrappers.
        generation=generation+1
        local base=generation*10
        local instance_fields={SelectedWorldSaveDirectoryName=selected or id,
            GetAddress=function() return base+2 end}
        local instance=object(instance_fields)
        instance_fields.SaveGameManager=object{
            AutoSaveWorldDefaultName=autosave or id,bIsLoadedWorldSaveData=true,
            GetAddress=function() return base+3 end,GetOuter=function() return instance end}
        s.engine=object{GameViewport=object{World=object{
            GetFullName=function() return name end,GetAddress=function() return base+1 end,
            OwningGameInstance=instance
        }}}
    end
    s.world('World splash')
    env.os={time=function() return s.now end,date=function() return 'fixture-time ' end}
    env.print=function() end
    env.io={open=function(p,mode)
        if p:match('/run.txt$') then
            if mode=='r' then
                if options.missing then return nil end
                return {read=function() return s.control end,close=function() return true end}
            end
            assert(mode=='w')
            if options.open_failure then return nil end
            return {write=function(_,text)
                assert(text=='DISABLED\n')
                if options.write_failure then return nil end
                s.control=text;return true
            end,close=function() return not options.close_failure end}
        end
        assert(p:match('/transition.log$') and mode=='a','unexpected file access')
        assert(s.control=='DISABLED\n')
        return {write=function(_,text) s.logs[#s.logs+1]=text;return true end,
            close=function() return true end}
    end}
    env.dofile=function(p)
        assert(p:match('/experiments/save_identity_probe.lua$'))
        assert(s.control=='DISABLED\n')
        s.loads=s.loads+1
        return Probe
    end
    env.require=function(name)
        assert(name=='UEHelpers')
        return {GetEngine=function()
            s.reads=s.reads+1
            if options.engine_failure then error('fixture engine unavailable') end
            return s.engine
        end}
    end
    env.LoopInGameThreadWithDelay=function(ms,fn)
        assert(ms==1000 and not s.callback and s.control=='DISABLED\n')
        s.callback=fn;return 73
    end
    env.CancelDelayedAction=function(handle)
        assert(handle==73)
        s.cancels=s.cancels+1
        if options.cancel_throws then error('fixture cancellation unavailable') end
        return not options.cancel_failure
    end
    function s.clean()
        assert(s.forbidden==0,'unexpected native access or game state write')
        assert(not s.has('verified=true'),'candidate agreement must not infer authority')
    end
    function s.start() return pcall(assert(load(code,'@'..path,'t',env))) end
    function s.tick(time) s.now=time;assert(s.callback)() end
    function s.log() return table.concat(s.logs) end
    function s.has(text) return s.log():find(text,1,true)~=nil end
    function s.quiet_after_stop()
        local count,reads,cancels=#s.logs,s.reads,s.cancels
        s.tick(s.now+1);s.tick(s.now+300)
        assert(#s.logs==count and s.reads==reads and s.cancels==cancels)
        s.clean()
    end
    return s
end

-- Fixture identities must satisfy the real collector while remaining unverified.
do
    local sample=fixture()
    local before=Probe.read(sample.engine)
    assert(before.context_status=='context_agrees' and before.verified==false)
    assert(before.world_address and before.instance_address and before.manager_address)
    sample.world(target)
    local after=Probe.read(sample.engine)
    assert(after.context_status=='context_agrees' and after.verified==false)
    for _,key in ipairs({'world_address','instance_address','manager_address'}) do
        assert(after[key]~=before[key],'replacement must refresh '..key)
    end
    assert(sample.forbidden==0)
end


-- All filesystem I/O is mocked: only consuming run.txt and appending the
-- observation log are allowed. No real trigger, log, save or storage is touched.
local title='World /Game/Pal/Maps/Title/PL_Title.PL_Title'
local login='World /Game/Pal/Maps/Login/PL_Login.PL_Login'
local function incomplete(s)
    assert(not s.has('SECOND_GAMEPLAY ') and not s.has('TRANSITION_COMPLETE'))
    assert(s.cancels==0)
    s.clean()
end
local function first(s)
    s.world(target);s.tick(0);s.tick(9)
    assert(not s.has('FIRST_GAMEPLAY '))
    s.tick(10);assert(s.has('FIRST_GAMEPLAY '));incomplete(s)
end
local function completed(s)
    assert(s.has('SECOND_GAMEPLAY world='..target))
    assert(s.has('TRANSITION_COMPLETE identity remains unverified'))
    assert(s.has('verified=false') and s.cancels==1)
    s.quiet_after_stop()
end

for _,options in ipairs({{missing=true},{control='DISABLED\n'},
    {control='PWP_IDENTITY_RUN fixture'},
    {control='PWP_TRANSITION_RUN '..string.rep('x',65)},
    {control='PWP_TRANSITION_RUN fixture extra'}}) do
    local s=fixture(options);assert(s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0 and s.reads==0)
    s.clean()
end
for _,fault in ipairs({'open_failure','write_failure','close_failure'}) do
    local s=fixture({[fault]=true});assert(not s.start())
    assert(not s.callback and s.loads==0 and #s.logs==0 and s.reads==0)
    s.clean()
end

-- One stable visit, even lasting the whole observation window, never completes.
local s=fixture();assert(s.start())
assert(s.control=='DISABLED\n' and s.loads==1 and s.reads==0)
first(s)
local count=#s.logs
s.tick(11);s.tick(100);s.tick(599)
assert(#s.logs==count,'unchanged samples and first entry must not repeat')
incomplete(s)
s.tick(600)
assert(s.has('TIMEOUT observations incomplete') and s.cancels==1)
s.quiet_after_stop()
local callback,loads=s.callback,s.loads
assert(s.start());assert(s.callback==callback and s.loads==loads)

-- An earlier Title does not qualify: the boundary must follow stable first entry.
s=fixture();assert(s.start());s.world(title);s.tick(0)
s.world(target);s.tick(1);s.tick(11);s.tick(30)
assert(s.has('FIRST_GAMEPLAY ') and not s.has('TITLE_BOUNDARY '));incomplete(s)

-- Login, arbitrary gaps, unavailable world and Title-like names are insufficient.
for _,gap in ipairs({login,'World splash','World intermediate title',
    title..'_suffix',false}) do
    s=fixture();assert(s.start());first(s)
    if gap then s.world(gap) else s.engine=nil end
    s.tick(11);s.tick(25)
    s.world(target);s.tick(30);s.tick(40);s.tick(100)
    assert(not s.has('TITLE_BOUNDARY '));incomplete(s)
end

-- A short first visit is not counted, and its intervening Title cannot qualify.
s=fixture();assert(s.start());s.world(target);s.tick(0);s.tick(9)
s.world(title);s.tick(10)
assert(not s.has('FIRST_GAMEPLAY ') and not s.has('TITLE_BOUNDARY '))
s.world(target);s.tick(20);s.tick(29)
assert(not s.has('FIRST_GAMEPLAY '));s.tick(30);incomplete(s)
s.world(title);s.tick(31);assert(s.has('TITLE_BOUNDARY '))
s.world(target);s.tick(40);s.tick(49);incomplete(s)
s.tick(50);completed(s)

-- Title may be followed by login, but second entry still needs ten fresh seconds.
-- Fresh wrapper/identity reads must survive the same-process map transition.
s=fixture();assert(s.start());first(s)
s.world(title);s.tick(11);s.tick(12)
s.world(login);s.tick(20)
s.world(target,string.rep('b',32));s.tick(30);s.tick(39);incomplete(s)
s.tick(40);completed(s)
assert(s.has('SECOND_GAMEPLAY world='..target..' | state=candidates_conflict'))
assert(s.has('selected='..string.rep('b',32)))
local _,boundaries=s.log():gsub('TITLE_BOUNDARY ','')
assert(boundaries==1)

-- Interrupting the second dwell resets it, even though Title was already seen.
for _,gap in ipairs({title,login,false}) do
    s=fixture();assert(s.start());first(s)
    s.world(title);s.tick(11)
    s.world(target);s.tick(20);s.tick(29);incomplete(s)
    if gap then s.world(gap) else s.engine=nil end
    s.tick(30)
    s.world(target);s.tick(40);s.tick(49);incomplete(s)
    s.tick(50);completed(s)
end

-- Timeout at exactly 600 wins over a second dwell maturing at that instant.
for _,late_target in ipairs({false,true}) do
    s=fixture();assert(s.start());first(s)
    s.world(title);s.tick(11)
    if late_target then s.world(target);s.tick(590) end
    s.tick(599);incomplete(s);assert(not s.has('TIMEOUT'))
    local reads=s.reads
    s.tick(600)
    assert(s.reads==reads,'deadline must be checked before another native read')
    assert(s.has('TIMEOUT observations incomplete') and s.cancels==1)
    assert(not s.has('SECOND_GAMEPLAY ') and not s.has('TRANSITION_COMPLETE'))
    s.quiet_after_stop()
end

s=fixture({cancel_failure=true});assert(s.start());first(s)
s.world(title);s.tick(11);s.world(target);s.tick(20);s.tick(30)
assert(s.has('timer_cancelled=false'));completed(s)
-- Throwing cancellation is contained for every terminal path, attempted once,
-- truthfully reported, and never retried by callbacks after the driver stops.
for _,reason in ipairs({'completion','timeout','failure'}) do
    s=fixture({cancel_throws=true,engine_failure=reason=='failure'})
    assert(s.start())
    local terminal
    if reason=='completion' then
        first(s);s.world(title);s.tick(11);s.world(target);s.tick(20)
        assert(pcall(s.tick,30),'cancellation must not escape completion')
        terminal='TRANSITION_COMPLETE identity remains unverified'
        completed(s)
        assert(not s.has('FAIL '))
    elseif reason=='timeout' then
        s.tick(599);incomplete(s)
        assert(pcall(s.tick,600),'cancellation must not escape timeout')
        terminal='TIMEOUT observations incomplete'
        assert(not s.has('TRANSITION_COMPLETE') and not s.has('FAIL '))
    else
        assert(pcall(s.tick,0),'cancellation must not escape failure handling')
        terminal='FAIL '
        assert(not s.has('TRANSITION_COMPLETE'))
    end
    local _,terminals=s.log():gsub(terminal,'')
    assert(terminals==1,'terminal reason must be reported exactly once')
    assert(s.cancels==1 and s.has('timer_cancelled=false'))
    assert(s.control=='DISABLED\n')
    s.quiet_after_stop()
end

s=fixture({engine_failure=true});assert(s.start());s.tick(0)
assert(s.has('FAIL ') and s.cancels==1 and not s.has('TRANSITION_COMPLETE'))
s.quiet_after_stop()

-- Observation completion never promotes agreeing, conflicting or malformed IDs
-- to verified authority, nor invokes getters/storage or writes to game objects.
s=fixture();assert(s.start());first(s)
s.world(title);s.tick(11)
s.world(target,'RAW_MALFORMED_SELECTED','RAW_MALFORMED_AUTOSAVE')
s.tick(20);s.tick(30);completed(s)
assert(s.has('selected_status=malformed') and s.has('autosave_status=malformed'))
assert(not s.has('RAW_MALFORMED'))
print('transition driver: two stable visits, observed Title, dwell resets, timeout, disarm and no game/storage writes passed')
