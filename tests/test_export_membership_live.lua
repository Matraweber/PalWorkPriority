local source_path=TEST_ROOT..'/experiments/export-membership-live/main.lua'
local file=assert(io.open(source_path,'rb'));local source=file:read('*a');file:close()
local Observer=dofile(TEST_ROOT..'/experiments/settings_export_membership_observer.lua')
local dir='fixture/Scripts'
local nonce=string.rep('a',32)
local W,G=string.rep('1',32),string.rep('00000001',4)
local A,B=string.rep('A',64),string.rep('B',64)
local function copy(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function fixture(edit,code)
    local f={arm='PWP_EXPORT_MEMBERSHIP '..nonce..'\n',queue={},delays={},logs={},lookups=0,
        readers=0,contexts=0,opens={},config_reads=0,origin_modules={},callbacks={}}
    f.config={manifest_sha256=string.rep('b',64),storage=W,guild=G,alias='1-1-1-1',keys={A,B}}
    f.pair={status='context_agrees',agrees=true,identity_loaded_status='read',identity_loaded_world=true,
        identity_selected_status='format_valid',identity_selected=W,identity_autosave_status='empty',
        directory=W,world='Pal world',world_address=1,state_address=2,instance_address=3,manager_address=4}
    f.auth={authority_status='read',authority=true,guild_status='format_valid',guild=G,legacy_guild='1-1-1-1',
        player_address=5,controller_address=6,player_state_address=7,guild_address=8}
    local env=setmetatable({},{__index=_G})
    env.package={path='unchanged'}
    env.io={open=function(path,mode)
        f.opens[#f.opens+1]={path,mode}
        assert(path==dir..'/run.txt' or path==dir..'/export-membership.log','unexpected file IO')
        if f.open_failure==mode then return nil end
        local h={}
        function h:read(n)assert(n==128);if f.read_failure then error({})end;return f.arm end
        function h:write(text)
            if f.write_failure==mode then return nil end
            if mode=='w'then assert(text=='DISABLED\n');f.arm=text
            else
                assert(text:sub(-1)=='\n'and not text:sub(1,-2):find('\n',1,true))
                assert(#text<=4096);f.logs[#f.logs+1]=text
                if f.on_log then f.on_log(text)end
            end
            return self
        end
        function h:flush()if f.flush_failure==mode then return nil end;return true end
        function h:close()if f.close_failure==mode then return nil end;return true end
        return h
    end}
    local Pair={read=function()
        assert(f.arm=='DISABLED\n');f.contexts=f.contexts+1
        if f.on_context then f.on_context()end
        return copy(f.pair)
    end}
    local Authority={read=function()return copy(f.auth)end}
    local Direct={new=function(o)
        f.readers=f.readers+1
        if f.on_factory then f.on_factory(o)end
        local stopped=false
        return {owns_key=function(k,c)
            assert(not stopped,'reused poisoned reader')
            assert(c.scope==o.context.scope and o.authorize()==true)
            local native=o.read_context();assert(native.world_address==f.pair.world_address)
            f.lookups=f.lookups+1
            local yes=true
            if f.on_lookup then yes=f.on_lookup(k,c)end
            if yes~=true then stopped=true end
            return yes
        end}
    end}
    env.dofile=function(path)
        assert(f.arm=='DISABLED\n','config/helper loaded before disarm')
        if path==dir..'/target.lua'then f.config_reads=f.config_reads+1;return f.config end
        local name=path:match('/([^/]+)%.lua$')
        local modules={save_context_pair_probe=Pair,save_local_authority=Authority,
            settings_priority_live_reader=Direct,settings_export_membership_observer=Observer}
        return assert(modules[name],path)
    end
    for name,method in pairs({palapi='camp_pals',store='durable_key',datafile='read',settings_gate='blocked',
        log='say',trace='at',perf='new',frame_trace='new'})do
        f.origin_modules[name]={[method]=assert(load('return function()end','@'..dir..'/'..name..'.lua'))()}
    end
    local cdo={IsValid=function()return true end,GetGameState=function()end,GetGameInstance=function()end}
    env.require=function(name)
        if name=='UEHelpers'then return {GetEngine=function()return {}end,GetGameplayStatics=function()return cdo end}end
        return assert(f.origin_modules[name],name)
    end
    env.ExecuteInGameThreadWithDelay=function(ms,fn)
        f.delays[#f.delays+1]=ms;f.callbacks[#f.callbacks+1]=fn
        if f.schedule_failure then error({})end
        if f.inline then fn()else f.queue[#f.queue+1]=fn end
    end
    if edit then edit(f)end
    assert(load(code or source,'@'..dir..'/main.lua','t',env))()
    function f.step()
        local fn=table.remove(f.queue,1);assert(fn,'no callback');fn()
    end
    function f.events()
        local rows={}
        for _,line in ipairs(f.logs)do
            assert(line:match('^PWP_EXPORT_MEMBERSHIP\t'))
            local row={}
            for part in line:sub(1,-2):gmatch('[^\t]+')do
                if part~='PWP_EXPORT_MEMBERSHIP'then
                    local k,v=part:match('^([^=]+)=(.*)$');assert(k and not row[k]);row[k]=v
                end
            end
            assert(row.nonce==nonce and row.manifest_sha256==f.config.manifest_sha256)
            for _,k in ipairs({'activation_allowed','ownership_verified','deletion_coverage_verified',
                'history_coverage_verified','authority_grant','storage_grant','coverage_grant',
                'replacement_allowed','deletion_allowed'})do assert(row[k]=='false')end
            rows[#rows+1]=row
        end
        return rows
    end
    return f
end
do
    local f=fixture();assert(f.contexts==0 and f.arm=='DISABLED\n'and f.delays[1]==30000)
    for _=1,3 do f.step()end
    assert(f.readers==6 and f.lookups==6 and #f.queue==0 and #f.delays==3)
    assert(f.delays[2]==10000 and f.delays[3]==10000)
    local r=f.events();assert(#r==11 and r[1].event=='armed'and r[1].world_hex=='none')
    for sample=1,3 do
        local i=2+(sample-1)*3
        assert(r[i].event=='key'and r[i].key==A and r[i].status=='current_target_confirmed')
        assert(r[i+1].key==B and r[i+2].event=='sample'and r[i+2].confirmed=='2')
        assert(r[i+2].sample==tostring(sample)and r[i+2].complete=='true')
        assert(r[i].world_address=='1'and r[i].world_hex=='50616c20776f726c64')
    end
    assert(r[11].event=='done'and r[11].sample=='3')
    local reads=f.contexts;for _,fn in ipairs(f.callbacks)do fn()end;assert(f.contexts==reads)
end
do
    local f=fixture(function(x)x.on_lookup=function(k)return k==B end end)
    for _=1,3 do f.step()end
    local r=f.events();assert(r[2].status=='unresolved'and r[3].status=='current_target_confirmed')
    assert(r[4].complete=='true'and r[4].unresolved=='1'and r[11].event=='done')
end
do
    local f=fixture(function(x)x.pair.status='not_ready'end)
    for _=1,120 do f.step()end
    assert(#f.delays==120 and f.contexts==120 and f.readers==0 and #f.queue==0)
    for i=2,120 do assert(f.delays[i]==2000)end
    assert(f.events()[2].reason=='context_readiness_timeout')
end
do
    local f=fixture(function(x)x.pair.status='not_ready'end)
    f.step();f.pair.status='context_agrees';f.step();f.step();f.step()
    assert(f.events()[11].event=='done'and f.delays[2]==2000 and f.delays[3]==10000)
end
for _,mode in ipairs({'session_between','during_lookup','authority','throw','nested','factory_mutation','factory_throw','lookup_throw'})do
    local f=fixture();f.step()
    if mode=='session_between'then f.pair.manager_address=99
    elseif mode=='authority'then f.auth.authority=false
    elseif mode=='throw'then f.on_context=function()error({secret='never print'})end
    elseif mode=='nested'then f.on_lookup=function()f.callbacks[2]();return true end
    elseif mode=='factory_mutation'then f.on_factory=function(c)c.context.epoch=2 end
    elseif mode=='factory_throw'then f.on_factory=function()error({})end
    elseif mode=='lookup_throw'then f.on_lookup=function()error({})end
    else f.on_lookup=function()f.pair.world_address=99;return true end end
    f.step();assert(#f.queue==0,mode)
    local rows=f.events();assert(rows[#rows].event=='failed',mode)
    for _,r in ipairs(rows)do assert(r.event~='done'and not r.reason:find('secret',1,true))end
end
for _,mode in ipairs({'read','readclose','write','writeclose','flush','missing','wrong','extra'})do
    local f=fixture(function(x)
        if mode=='read'then x.read_failure=true elseif mode=='readclose'then x.close_failure='r'
        elseif mode=='write'then x.write_failure='w'elseif mode=='writeclose'then x.close_failure='w'
        elseif mode=='flush'then x.flush_failure='w'elseif mode=='missing'then x.open_failure='r'
        elseif mode=='wrong'then x.arm='WRONG\n'else x.arm=x.arm..'extra'end
    end)
    assert(f.contexts==0 and f.config_reads==0 and #f.queue==0 and #f.logs==0,mode)
end
for _,mode in ipairs({'alias','hash','keys','unknown','origin'})do
    local f=fixture(function(x)
        if mode=='alias'then x.config.alias='1-1-1-2'elseif mode=='hash'then x.config.manifest_sha256='BAD'
        elseif mode=='keys'then x.config.keys={B,A}elseif mode=='unknown'then x.config.extra=true
        else x.origin_modules.store.durable_key=function()end end
    end)
    assert(#f.queue==0 and f.contexts==0,mode)
end
for _,mode in ipairs({'write','flush','close','open','schedule','inline'})do
    local f=fixture(function(x)
        if mode=='write'then x.write_failure='a'elseif mode=='flush'then x.flush_failure='a'
        elseif mode=='close'then x.close_failure='a'elseif mode=='open'then x.open_failure='a'
        elseif mode=='schedule'then x.schedule_failure=true else x.inline=true end
    end)
    assert(#f.queue==0 and f.contexts==0,mode)
end
local function final_context_check(code) -- completion reproof after sample3 logging
    local f=fixture(function(x)x.on_log=function(line)
        if line:find('event=sample\t',1,true)and line:find('\tsample=3\t',1,true)then x.pair.manager_address=99 end
    end end,code)
    f.step();f.step();f.step()
    local r=f.events();assert(r[#r].event=='failed','late context change accepted')
    for _,row in ipairs(r)do assert(row.event~='done')end
end
final_context_check()
do -- Negative control exercises real runner completion, not a mirrored checker.
    local mutant,n=source:gsub('not fresh or not equal%(fresh,before%)','not fresh ')
    assert(n==1)
    local ok,why=pcall(final_context_check,mutant)
    assert(not ok and tostring(why):find('late context change accepted',1,true))
end
do -- IO failure after readiness ends the run without another native callback.
    local f=fixture();f.step();f.write_failure='a';f.step()
    assert(#f.queue==0);local reads=f.contexts
    for _,fn in ipairs(f.callbacks)do fn()end;assert(f.contexts==reads)
end
print('export membership runner: one-shot, bounded retries/samples, stable context, strict evidence and failure stop')
-- Offline parser composition may consume these in-memory events; no log files.
return fixture
