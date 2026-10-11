package.loaded.log={warn=function()end,error=function()end}
local Guard=dofile(TEST_ROOT..'/experiments/settings_migration_guard.lua')
local Store,Caps,Data=require('store'),require('caps'),require('datafile')
local W,G=string.rep('a',32),'00000001000000020000000300000004'
local function fixture()
    local f={source={},backup={},reads=0,receipts=0,fenced=true}
    local files={}
    for _,base in ipairs({'priorities.txt','caps.txt'})do
        for _,suffix in ipairs({'','.tmp','.pending','.bak'})do files[base..suffix]=false end
    end
    files['priorities.txt']=assert(Store.serialize_snapshot({pal={[1]=false,[2]=3}},true))
    files['caps.txt']=assert(Caps.serialize_snapshot({['1-2-3-4']={Mining={Stone=100,Ore=false}}}))
    -- Use actual writer envelopes to exercise a newer pending generation.
    local fs=require('memory_fs')();local previous=Data.fs;Data.fs=fs
    local newer=assert(Caps.serialize_snapshot({['1-2-3-4']={Mining={Stone=200,Ore=false}}}))
    assert(Data.write('envelope',newer,4));files['caps.txt.pending']=assert(Data.read_raw('envelope'));Data.fs=previous
    for k,v in pairs(files)do f.source[k]=v;f.backup[k]=v end
    local function read(which,name)
        f.reads=f.reads+1
        if f.on_read then f.on_read(which,name)end
        if f.unreadable==name then return nil,'denied',13 end
        local raw=f[which][name]
        if raw==false then return nil,'missing',2 end
        return raw
    end
    f.o={enabled=true,storage=W,guild=G,runtime_guild='1-2-3-4',files=files,
        read_source=function(name)return read('source',name)end,
        read_backup=function(name)return read('backup',name)end,
        verify_receipt=function(copy)
            f.receipts=f.receipts+1
            if f.on_receipt then f.on_receipt(copy)end
            return not f.bad_receipt
        end,
        fenced=function()return f.fenced end}
    f.guard=assert(Guard.new(f.o))
    f.c={storage=W,guild=G,scope='PWP-SCOPE-1:'..W..':'..G..':limits',stream='limits',authority=true}
    function f:verify()return self.guard:verify(self.c,self.guard:body())end
    return f
end
assert(not Guard.new{} and not Guard.new{enabled='true'})
do
    local f=fixture();local bytes=assert(Caps.decode_snapshot(f.guard:body()))
    assert(bytes.data[G].Mining.Stone==200 and bytes.data[G].Mining.Ore==false)
    local fs=Data.fs
    assert(f:verify() and f.reads==24 and Data.fs==fs)
    assert(not f:verify() and f.reads==24)
end
for _,change in ipairs({
    function(f)f.source['caps.txt.tmp']='new' end,
    function(f)f.source['caps.txt.pending']=false end,
    function(f)f.backup['priorities.txt']='different' end,
    function(f)f.unreadable='caps.txt.bak' end,
    function(f)f.bad_receipt=true end,
    function(f)f.fenced=false end,
    function(f)f.c.storage=G end,
    function(f)f.c.guild=W end,
    function(f)f.c.authority=false end,
    function(f)f.on_receipt=function()error('lost receipt')end end,
    function(f)f.on_receipt=function()f:verify()end end,
    function(f)f.on_read=function(which)if which=='backup' then f.source['caps.txt']='changed' end end end,
    function(f)f.on_read=function()f.fenced=false end end,
})do
    local f=fixture();change(f);assert(not f:verify());assert(not f:verify())
end
do
    local f=fixture();f.o.files['caps.txt']='mutation'
    f.on_receipt=function(copy)copy['caps.txt']='mutation'end
    assert(f:verify()) -- caller copies cannot redirect the frozen bytes
end
do
    local f=fixture();assert(not f.guard:verify(f.c,f.guard:body()..'bad'))
end
for _,where in ipairs({'source','backup'})do
    local f=fixture();f.on_read=function(which)if which==where then f:verify()end end
    assert(not f:verify())
end
do
    local f=fixture();f.o.fenced=function()f:verify();return true end
    f.guard=assert(Guard.new(f.o));assert(not f:verify())
end
for _,value in ipairs({'yes',1,false})do
    local f=fixture();f.o.fenced=function()return value end
    f.guard=assert(Guard.new(f.o));assert(not f:verify())
end
do
    local f=fixture();f.o.files['caps.txt']=false;f.source['caps.txt']=false;f.backup['caps.txt']=false
    f.guard=assert(Guard.new(f.o));assert(f:verify()) -- newer pending alone is valid
end
do
    local f=fixture();f.o.files['caps.txt.pending']='broken';f.source['caps.txt.pending']='broken';f.backup['caps.txt.pending']='broken'
    f.guard=assert(Guard.new(f.o));assert(Caps.decode_snapshot(f.guard:body()).data[G].Mining.Stone==100)
    assert(f:verify()) -- actual recovery parser ignores unprotected pending bytes
end
do
    local f=fixture()
    for name in pairs(f.o.files)do if name:match('^caps') then f.o.files[name]=false end end
    assert(not Guard.new(f.o)) -- wholly absent stream never manufactures empty settings
end
print('migration guard: full recovery set, real newer-generation selection, immutable bytes, proof/fence rejection and one-shot verification passed')
