local Entry=dofile(TEST_ROOT..'/experiments/dedicated_clock_entry.lua')
local Probe=dofile(TEST_ROOT..'/experiments/dedicated_clock_probe.lua')
local nonce=string.rep('a',32)
local function fixture()
    local f={arm='PWP_DEDICATED_CLOCK '..nonce..'\n',logs={},opens={},close_n=0,
        reads=0,resolves=0,scheduled=0,cancelled=0,time=0}
    local fs={}
    function fs.open(path,mode)
        f.opens[#f.opens+1]={path=path,mode=mode}
        if f.open_fail==mode then return nil end
        assert(path=='fixture/run.txt' or path=='fixture/clock.log')
        local h={}
        function h:read(n) assert(n==128);if f.read_throw then error('read')end;return f.arm end
        function h:write(text)
            if f.write_fail==mode then return nil end
            if path=='fixture/run.txt'then assert(text=='DISABLED\n');f.arm=text
            else f.logs[#f.logs+1]=text end
            return self
        end
        function h:close()f.close_n=f.close_n+1;if f.close_fail==mode then return nil end;return true end
        return h
    end
    local Clock={new=function(resolve)
        local active=false
        return {begin=function()resolve();active=true end,
            read=function()assert(active);f.reads=f.reads+1;f.time=f.time+0.00001;return f.time end,
            finish=function()active=false end,close=function()active=false end}
    end}
    f.options={root='fixture',config={nonce=nonce},fs=fs,probe=Probe,clock_module=Clock,
        resolve=function()f.resolves=f.resolves+1 end,
        schedule=function(ms,fn)assert(ms==1000);f.scheduled=f.scheduled+1;f.tick=fn;return 0 end,
        cancel=function(handle)assert(handle==0);f.cancelled=f.cancelled+1;return true end}
    return f
end
do
    local f=fixture();local c=assert(Entry.start(f.options))
    assert(f.arm=='DISABLED\n' and f.scheduled==1)
    for _=1,8 do f.time=f.time+1;f.tick()end
    assert(#f.logs==9 and f.reads==272 and f.resolves==8 and f.cancelled==1)
    assert(f.logs[9]:find('advancement_observed=true',1,true))
    assert(f.logs[9]:find('elapsed_validated=false',1,true))
    f.tick();c.close();assert(#f.logs==9 and f.cancelled==1)
    assert(not Entry.start(f.options));assert(f.scheduled==1,'consumed arm restarted probe')
end
for _,failure in ipairs({'missing','wrong','oversized','read','readclose','write','writeclose','openwrite'})do
    local f=fixture()
    if failure=='missing'then f.open_fail='r'
    elseif failure=='wrong'then f.arm='PWP_DEDICATED_CLOCK '..string.rep('b',32)..'\n'
    elseif failure=='oversized'then f.arm=f.arm..'extra'
    elseif failure=='read'then f.read_throw=true
    elseif failure=='readclose'then f.close_fail='r'
    elseif failure=='write'then f.write_fail='w'
    elseif failure=='writeclose'then f.close_fail='w'
    else f.open_fail='w'end
    assert(not Entry.start(f.options));assert(f.scheduled==0 and f.reads==0,failure)
end
for _,mode in ipairs({'write','close','open'})do
    local f=fixture();assert(Entry.start(f.options))
    if mode=='write'then f.write_fail='a' elseif mode=='close'then f.close_fail='a' else f.open_fail='a'end
    f.tick();assert(f.cancelled==1);local reads=f.reads;f.tick();assert(f.reads==reads)
end
do
    local f=fixture();local c=assert(Entry.start(f.options));c.close()
    assert(f.reads==0 and #f.logs==1 and f.cancelled==1)
    assert(f.logs[1]:find('reason=closed',1,true))
end
-- Reject grants and injectable/unbounded values before opening the evidence file.
for _,bad in ipairs({{verified=true},{nonce='different'},{reason='line\nbreak'},
    {resolver_ms=math.huge},{reason=string.rep('a',97)}})do
    local f=fixture();local caught=false
    f.options.probe={start=function(o)
        local row={nonce=nonce,status='finished',verified=false,active=false,
            storage_grant=false,authority_grant=false,coverage_grant=false,elapsed_validated=false}
        for k,v in pairs(bad)do row[k]=v end
        caught=not pcall(o.emit,row);return {}
    end}
    assert(Entry.start(f.options));assert(caught and #f.logs==0)
end
print('PASS clock harness: one-shot arm, exact providers, bounded evidence, IO failure and close')
