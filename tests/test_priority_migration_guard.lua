-- Actual migration/parser/guard. Ownership and filesystem readers are injected,
-- not represented as live engine evidence. No installed settings are touched.
package.loaded.log={warn=function()end,error=function()end}
local Guard=dofile(TEST_ROOT..'/experiments/settings_migration_guard.lua')
local Store,Caps=require('store'),require('caps')
local W,G=string.rep('a',32),'00000001000000020000000300000004'
local function fixture()
    local f={checks=0,reads=0,fenced=true,source={},backup={}}
    local files={}
    for _,base in ipairs({'priorities.txt','caps.txt'})do
        for _,suffix in ipairs({'','.tmp','.pending','.bak'})do files[base..suffix]=false end
    end
    files['priorities.txt']=assert(Store.serialize_snapshot({alice={[1]=false,[2]=1,[3]=5},bob={[4]=3}},true))
    files['caps.txt']=assert(Caps.serialize_snapshot({['1-2-3-4']={Mining={Stone=100}}}))
    for k,v in pairs(files)do f.source[k]=v;f.backup[k]=v end
    local function read(which,name)
        f.reads=f.reads+1
        if f.on_read then f.on_read(which,name)end
        local value=f[which][name];if value==false then return nil,'missing',2 end
        return value
    end
    f.o={enabled=true,stream='priorities',storage=W,guild=G,runtime_guild='1-2-3-4',files=files,
        read_source=function(n)return read('source',n)end,
        read_backup=function(n)return read('backup',n)end,
        verify_receipt=function()return true end,fenced=function()return f.fenced end,
        owns_key=function(key,c)
            f.checks=f.checks+1
            assert(c.storage==W and c.guild==G and c.stream=='priorities' and c.session=='boot')
            if f.on_owns then return f.on_owns(key,c)end
            return true
        end}
    f.g=assert(Guard.new(f.o))
    f.c={storage=W,guild=G,stream='priorities',scope='PWP-SCOPE-1:'..W..':'..G..':priorities',
        authority=true,session='boot',incarnation='inc',epoch=1,camp='camp'}
    function f:verify()return self.g:verify(self.c,self.g:body())end
    return f
end
do
    local f=fixture();assert(f.checks==0 and f.reads==0)
    local decoded=assert(Store.decode_snapshot(f.g:body()))
    assert(decoded.baseline and decoded.count==4 and decoded.data.alice[1]==false
        and decoded.data.alice[2]==1 and decoded.data.alice[3]==5 and decoded.data.bob[4]==3)
    assert(f:verify() and f.checks==4 and f.reads==24)
    assert(not f:verify() and f.checks==4)
end
for _,v in ipairs({false,'true',1})do
    local f=fixture();f.on_owns=function(key)return key=='alice' or v end
    assert(not f:verify() and f.reads==0)
end
do
    local f=fixture();f.on_owns=function()return nil end;assert(not f:verify())
end
for _,change in ipairs({
    function(f)f.on_owns=function()error('lost ownership reply')end end,
    function(f)f.on_owns=function()f:verify();return true end end,
    function(f)f.on_owns=function()f.fenced=false;return true end end,
    function(f)f.on_read=function()f.on_owns=function()return false end end end,
    function(f)f.source['priorities.txt']='changed' end,
    function(f)f.backup['priorities.txt.bak']='new recovery generation' end,
    function(f)f.c.stream='limits' end,
    function(f)f.c.guild=W end,
    function(f)f.c.authority=false end,
})do
    local f=fixture();change(f);assert(not f:verify());assert(not f:verify())
end
do
    local f=fixture();f.on_owns=function(_,c)c.guild='mutated';return true end
    f.o.owns_key=function()return false end -- captured callback, immutable candidate
    f.o.files['priorities.txt']='mutated'
    assert(f:verify() and f.c.guild==G)
end
do
    local f=fixture();f.o.owns_key=nil;assert(not pcall(Guard.new,f.o))
    f.o.stream='typo';assert(not pcall(Guard.new,f.o))
    f.o.stream=false;assert(not pcall(Guard.new,f.o))
end
print('priority migration: full row preservation, X/baseline, twice-fresh ownership, immutable context and fail-closed proof passed')
