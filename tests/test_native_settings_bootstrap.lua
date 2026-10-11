local path=TEST_ROOT..'/experiments/native-settings-live/main.lua'
local file=assert(io.open(path,'r'));local source=file:read('*a');file:close()
local Adapter=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local function fixture(marker,bad_config)
    local s={files={['run.txt']=marker},delays={},reports=0,native_calls=0,starts=0,polls=0}
    local env=setmetatable({},{__index=_G})
    env.io={open=function(name,mode)
        local key=assert(name:match('/([^/]+)$'))
        assert(key=='run.txt' or key=='settings-trial.jsonl','unexpected file')
        if mode=='r' and s.files[key]==nil then return end
        if mode=='w' then s.files[key]='' end
        local offset=1
        return {read=function(_,n)
            local value=s.files[key]:sub(offset,offset+n-1);offset=offset+#value
            return #value>0 and value or nil
        end,write=function(self,value)
            s.files[key]=(s.files[key] or '')..value;return self
        end,close=function() return true end}
    end}
    env.package={path='original',loadlib=function()
        return function(command,handle,ticket,hex,length)
            s.native_calls=s.native_calls+1
            assert(command==0 and handle==0 and ticket==0 and hex=='' and length==0)
            return bad_config and 0 or 1,Adapter.pack({'1'}),10,1,2,1000
        end
    end}
    env.ExecuteInGameThreadWithDelay=function(ms,fn) s.delays[#s.delays+1]={ms=ms,fn=fn} end
    env.ExecuteAsync=function() error('fake trial must not dispatch') end
    env.ExecuteInGameThread=function() error('fake trial must not dispatch') end
    env.dofile=function(name)
        if name:match('/save_native_backend.lua$') then return Adapter end
        assert(name:match('/native_settings_trial.lua$'))
        return {new=function(o)
            assert(o.game_thread==10 and o.boot=='test-123' and type(o.schedule)=='function')
            s.options=o
            return {start=function() s.starts=s.starts+1;return true end,
                poll=function() s.polls=s.polls+1;o.report{event='passed',text='X\n"\\',synthetic=true} end,
                status=function() return {state='passed',phase='complete'} end}
        end}
    end
    assert(load(source,'@'..path,'t',env))()
    return s
end
for _,marker in ipairs({'wrong','PWP_SETTINGS_TRIAL '..string.rep('a',65),'PWP_SETTINGS_TRIAL a\nextra'}) do
    local s=fixture(marker);assert(#s.delays==0 and s.files['run.txt']==marker)
end
assert(#fixture(nil).delays==0)
do
    local s=fixture('PWP_SETTINGS_TRIAL test-123\n')
    assert(s.files['run.txt']=='DISABLED\n' and s.delays[1].ms==90000 and s.native_calls==0)
    s.delays[1].fn();assert(s.starts==1 and s.native_calls==1 and s.delays[2].ms==100)
    s.delays[2].fn();assert(s.polls==1 and #s.delays==2)
    assert(s.files['settings-trial.jsonl']:find('\\u000a',1,true))
    s.delays[2].fn();assert(s.polls==1,'stopped callback cannot rerun trial')
end
do
    local s=fixture('PWP_SETTINGS_RECOVERY test-123\n')
    s.delays[1].fn();assert(s.options.recovery_only==true)
    s.delays[2].fn();assert(s.polls==1)
end
do
    local s=fixture('PWP_SETTINGS_TRIAL test-123\n',true)
    s.delays[1].fn();assert(s.starts==0 and s.native_calls==1 and #s.delays==1)
    assert(s.files['settings-trial.jsonl']:find('bootstrap-failed',1,true))
    s.delays[1].fn();assert(s.native_calls==1,'no automatic config retry')
end
print('typed trial bootstrap: opt-in consumed first, bounded scheduling, failure stops, escaped logs')
