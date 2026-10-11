-- Real profiler + memory filesystem: measurement must not change durability.
local make_fs=require('memory_fs')
local clock=0
os.clock=function() return clock end
local function run(enabled,failure)
    package.loaded.log=nil
    package.loaded.datafile=nil
    local log=require('log')
    local file=require('datafile')
    local fs=make_fs(); file.fs=fs
    assert(file.write('p','old\n',0))
    assert(file.write('p','current\n',1))
    if failure=='protect' then fs.files['p.tmp']=fs.files.p end
    fs.operations={}
    log.set_perf(enabled); log.reset_marks()
    local injected=0
    local function fail() injected=injected+1; return true end
    fs.fault=function(op,path)
        clock=clock+0.001
        if op=='rename' and path=='p.tmp>p' then clock=clock+0.277 end
        if failure=='install' and op=='rename' and path=='p.tmp>p' then return fail() end
        if failure=='restore' and op=='rename' and (path=='p.tmp>p' or path=='p.bak>p') then return fail() end
        if failure=='protect' and op=='rename' and path=='p.tmp>p.pending' then return fail() end
        if failure and op==failure then
            injected=injected+1
            if failure=='read' then error('injected thrown read') end
            return true
        end
    end
    local ok,err,gen=file.write('p','new\n',2)
    if failure then
        assert(not ok and injected>0,'intended failure branch was not exercised')
        if failure=='restore' then assert(injected==2,'restore failure was not reached') end
    else assert(ok and gen==3) end
    assert(log.sinks.console.attempts==0 and log.sinks.file.attempts==0,
        'profiling wrote to a logging sink inside persistence')
    if enabled then
        assert(log.marks['save: inspect temporary open'].timed_n==1)
        if not failure then
            local install=assert(log.marks['save: install temporary'])
            assert(install.timed_n==1 and math.abs(install.ms-278)<0.0001,
                'replacement delay attributed to the wrong save operation')
            assert(log.marks['save: temporary close write'].timed_n==1)
            assert(log.marks['save: verify temporary read'].timed_n==1)
            assert(log.marks['save: rotate backup'].timed_n==1)
        end
    else assert(next(log.marks)==nil,'disabled profiling collected save rows') end
    return {ok=ok,err=err,gen=gen,operations=table.concat(fs.operations,'\n'),files=fs.files}
end
for _,failure in ipairs({false,'open','read','write','close','remove','rename','install','restore','protect'}) do
    local off,on=run(false,failure),run(true,failure)
    assert(off.ok==on.ok and off.err==on.err and off.gen==on.gen,
        'profiling changed checked result: '..tostring(failure))
    local comparable=on.operations:gsub('flush:p.tmp\n','')
    assert(off.operations==comparable,'profiling changed filesystem operation order beyond explicit flush')
    for path,bytes in pairs(off.files) do assert(on.files[path]==bytes) end
    for path,bytes in pairs(on.files) do assert(off.files[path]==bytes) end
end
print('Save timing: exact replacement attribution, profiling off, ordinary/thrown failures and unchanged recovery files passed')

-- A slow fclose may be flushing buffered bytes or closing the OS handle.
-- Split those phases without confusing moved time with time saved.
for _, fault in ipairs({false, 'flush_nil', 'flush_false', 'flush_throw', 'both', 'close', 'write'}) do
    package.loaded.log=nil; package.loaded.datafile=nil
    local log=require('log'); local file=require('datafile')
    local fs=make_fs(); file.fs=fs
    assert(file.write('p','old\n',0))
    local old=fs.files.p
    local flushes,closes=0,0
    local open=fs.open
    fs.open=function(path,mode)
        local f,err,code=open(path,mode)
        if f and path=='p.tmp' and mode=='wb' then
            local flush,close,write=f.flush,f.close,f.write
            f.flush=function(self)
                flushes=flushes+1; clock=clock+0.478
                if fault=='flush_nil' or fault=='both' then return nil,'flush denied' end
                if fault=='flush_false' then return false,'flush denied' end
                if fault=='flush_throw' then error('flush threw') end
                return flush(self)
            end
            f.close=function(self)
                closes=closes+1; clock=clock+0.007
                if fault=='close' or fault=='both' then return nil,'close denied' end
                return close(self)
            end
            f.write=function(self,text)
                if fault=='write' then return nil,'write denied' end
                return write(self,text)
            end
        end
        return f,err,code
    end
    log.set_perf(true); log.reset_marks()
    local ok,err=file.write('p','new\n',1)
    assert(closes==1,'failed flush must still close exactly once')
    assert(flushes==(fault=='write' and 0 or 1))
    if fault then
        assert(not ok and err,'failed operation reported a saved generation')
        if fault=='both' then assert(err:find('flush denied',1,true),'lost primary flush failure') end
        assert(fs.files.p==old,'failed temporary operation replaced live data')
    else
        assert(ok)
        assert(math.abs(log.marks['save: temporary flush write'].ms-478)<0.0001)
        assert(math.abs(log.marks['save: temporary close write'].ms-7)<0.0001)
    end
    assert(log.sinks.console.attempts==0 and log.sinks.file.attempts==0)
end
print('Flush/close split: independent attribution, nil/false/thrown failures, cleanup and previous generation retained')
