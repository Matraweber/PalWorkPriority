local path=TEST_ROOT..'/experiments/ue4ss-save-root/Scripts/main.lua'
local f=assert(io.open(path,'r'));local code=f:read('*a');f:close()
local slot='PWP_AsyncDev_v1_'..string.rep('8',32)..'_'..string.rep('e',32)..'_p_B'
local function fixture(o)
    o=o or {}
    local s={logs={},opens=0,closes=0,resolves=0,calls=0,cancels=0,forbidden=0}
    local env={}
    setmetatable(env,{__index=function(_,key)
        s.forbidden=s.forbidden+1;error('forbidden global '..key)
    end})
    for _,key in ipairs({'assert','debug','pcall','type','string','tostring'}) do env[key]=_G[key] end
    env.os={date=function() return 'fixture-time ' end}
    env.print=function() if o.print_failure then error('PRIVATE_ERROR') end end
    env.io={open=function(p,mode)
        assert(p==path:gsub('/Scripts/main.lua$','/root.log') and mode=='a','unexpected file IO')
        s.opens=s.opens+1
        if o.open_failure or (o.late_log_failure and s.opens>1) then return nil end
        return {write=function(_,line)
            if o.write_throw then error('PRIVATE_ERROR') end
            if o.write_failure then return nil end
            s.logs[#s.logs+1]=line;return true
        end,close=function()
            s.closes=s.closes+1
            if o.close_throw then error('PRIVATE_ERROR') end
            return not o.close_failure
        end}
    end}
    env.StaticFindObject=function(p)
        assert(p=='/Script/Engine.Default__KismetSystemLibrary')
        s.resolves=s.resolves+1
        if o.lookup_failure then error('PRIVATE_ERROR') end
        if s.resolves<=(o.unavailable or 0) then return nil end
        local this=s.resolves
        local cdo={
            IsValid=function() assert(this==s.resolves,'stale wrapper');return not o.invalid end,
            GetFullName=function() return o.wrong_class and 'Wrong' or 'KismetSystemLibrary '..p end,
            GetProjectSavedDirectory=function()
                assert(this==s.resolves,'stale wrapper');s.calls=s.calls+1
                if o.reentrant then s.callback() end
                if o.method_failure then error('PRIVATE_ERROR') end
                local value=o.root or 'C:\\Users\\Fixture\\AppData\\Local\\Pal\\Saved\\'
                if o.conversion_failure then return {ToString=function() error('PRIVATE_ERROR') end} end
                if o.nonstring_conversion then return {ToString=function() return {} end} end
                if o.fstring then return {ToString=function() return value end} end
                return value
            end,
        }
        return setmetatable(cdo,{__index=function() s.forbidden=s.forbidden+1;error('unexpected method') end})
    end
    env.LoopInGameThreadWithDelay=function(ms,fn)
        assert(ms==1000);s.callback=fn
        if o.inline then fn() end
        if o.timer_throw then error('PRIVATE_ERROR') end
        if o.timer_nil then return nil end
        return 71
    end
    env.CancelDelayedAction=function(h)
        assert(h==71);s.cancels=s.cancels+1
        if o.cancel_throw then error('PRIVATE_ERROR') end
        return not o.cancel_false
    end
    function s.start()
        local src=code
        if o.slot then src=src:gsub("local slot='[^']+'",function() return 'local slot='..string.format('%q',o.slot) end) end
        return pcall(assert(load(src,'@'..path,'t',env)))
    end
    function s.has(text) return table.concat(s.logs):find(text,1,true)~=nil end
    function s.tick() assert(s.callback)() end
    function s.quiet()
        local r,c,l=s.resolves,s.calls,#s.logs
        for _=1,35 do s.tick() end
        assert(s.resolves==r and s.calls==c and #s.logs==l,'late callback did work')
        assert(s.forbidden==0)
        assert(not s.has('PRIVATE_ERROR'))
    end
    return s
end

for _,o in ipairs({{}, {fstring=true}, {inline=true}, {reentrant=true}, {unavailable=2}}) do
    local s=fixture(o);assert(s.start())
    if not o.inline then for _=1,(o.unavailable or 0)+1 do s.tick() end end
    assert(s.calls==1 and s.cancels==1)
    assert(s.has('derived_file=C:/Users/Fixture/AppData/Local/Pal/Saved/SaveGames/'..slot..'.sav'))
    assert(s.has('file_checked=false | mapping_verified=false | verified=false'))
    assert(s.has('OBSERVATION_COMPLETE timer_cancelled=true verified=false'))
    s.quiet()
end
-- Native return is not rewritten into an assumed Pal/Saved location.
do local s=fixture{root='D:/CustomRoot'};assert(s.start());s.tick()
    assert(s.has('project_saved=D:/CustomRoot/'))
    assert(s.has('derived_file=D:/CustomRoot/SaveGames/'..slot..'.sav'));s.quiet()
end
for _,root in ipairs({'relative/Saved','C:Saved','/Saved','//server/share/Saved',
    '\\\\?\\C:\\Saved','C:/a/../Saved','C:/a/./Saved','C:/a//Saved','C:/a./Saved',
    'C:/a /Saved','C:/bad|log','C:/bad\nlog','C:/bad:ads','C:/bad?name',
    'C:/','',string.rep('a',2049)}) do
    local s=fixture{root=root};assert(s.start());s.tick()
    assert(s.has('FAIL unsupported_root') and not s.has('ROOT_OBSERVED'));s.quiet()
end
for _,o in ipairs({{lookup_failure=true},{method_failure=true},{conversion_failure=true},
    {nonstring_conversion=true},{wrong_class=true}}) do
    local s=fixture(o);assert(s.start());s.tick()
    assert(s.has('FAIL ') and not s.has('ROOT_OBSERVED'));s.quiet()
end
for _,o in ipairs({{invalid=true},{unavailable=100}}) do
    local s=fixture(o);assert(s.start())
    for _=1,29 do s.tick() end
    assert(s.cancels==0 and not s.has('OBSERVATION_COMPLETE'))
    s.tick();assert(s.resolves==30 and s.calls==0 and s.cancels==1)
    assert(s.has('FAIL cdo_unavailable attempts=30'));s.quiet()
end
for _,o in ipairs({{cancel_false=true},{cancel_throw=true}}) do
    local s=fixture(o);assert(s.start());s.tick()
    assert(s.has('FAIL cancellation timer_cancelled=false') and not s.has('OBSERVATION_COMPLETE'));s.quiet()
end
for _,o in ipairs({{timer_nil=true},{timer_throw=true},{inline=true,timer_nil=true}}) do
    local s=fixture(o);assert(s.start());assert(s.has('FAIL timer_unavailable'))
    assert(not s.has('OBSERVATION_COMPLETE'));s.quiet()
end
for _,o in ipairs({{open_failure=true},{write_failure=true},{close_failure=true},
    {write_throw=true},{close_throw=true},{print_failure=true}}) do
    local s=fixture(o);assert(s.start());assert(not s.callback and s.resolves==0)
    if not o.open_failure then assert(s.closes==1) end
end
do local s=fixture{late_log_failure=true};assert(s.start());s.tick();assert(s.cancels==1);s.quiet() end
for _,bad in ipairs({slot..'.sav',slot..'/../x',slot:gsub('_p_B$','_p_C'),
    slot:gsub('_p_B$','_x_B'),slot:gsub(string.rep('8',32),string.rep('0',32)),
    slot:gsub(string.rep('e',32),string.rep('0',32)),slot:gsub('8888','GGGG',1),
    slot:gsub(string.rep('8',32),string.rep('8',31))}) do
    local s=fixture{slot=bad};assert(not s.start());assert(s.opens==0 and not s.callback)
end
print('saved-root driver: fresh static CDO, exact synthetic path, strict grammar, bounded retry, no slot IO, safe shutdown')
