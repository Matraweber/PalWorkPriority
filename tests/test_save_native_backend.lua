-- Contract tests of the Lua adapter. Native execution/filesystem have separate tests.
local M=dofile(TEST_ROOT..'/experiments/save_native_backend.lua')
local Scope=dofile(TEST_ROOT..'/experiments/save_scope.lua')
local W,G=string.rep('a',32),string.rep('b',32)
local scope=Scope.new(W,G,'priorities').key
local function fixture()
    local s={thread=10,calls={},workers={},callbacks={},status=1}
    function s.native(cmd,handle,ticket,hex,n)
        assert(handle==4 and #hex==n)
        local bytes=hex:gsub('..',function(v)return string.char(tonumber(v,16))end)
        s.calls[#s.calls+1]={cmd=cmd,ticket=ticket,bytes=bytes}
        if s.throw then error('native return lost') end
        local data=''
        if cmd==5 then data=s.reply or '' end
        return cmd==5 and (s.reply and 1 or 2) or s.status,data,s.thread,20,21,1000
    end
    s.backend=M.new{enabled=true,native=s.native,binding=4,game_thread=10,
        storage=W,guild=G,stream='priorities',incarnation='boot',epoch=7,
        schedule=function(fn)
            if s.schedule_throw then error('route failed') end
            if s.schedule_false then return false end
            s.workers[#s.workers+1]=fn
        end,
        resume=function(fn) s.callbacks[#s.callbacks+1]=fn end}
    function s.request(ticket,kind)
        return {scope=scope,incarnation='boot',epoch=7,ticket=ticket,kind=kind or 'recover',
            max_payload_bytes=65536}
    end
    function s.terminal(certain,kind)
        local f={scope,'boot','7',kind=='update' and 'updated' or 'recovered',
            certain==false and '0' or '1','0','0','pair','0','0',
            'missing','0','','missing','0',''}
        if kind=='update' then for i=11,16 do f[i]='' end end
        s.reply=M.pack(f);return f
    end
    return s
end
do
    local fields={'a\0b','',string.char(255),'\n'}
    local got=M.unpack(M.pack(fields),4)
    for i,v in ipairs(fields) do assert(got[i]==v) end
    for _,f in ipairs({{[0]='bad'},{a='bad'},{[2]='hole'}}) do assert(not pcall(M.pack,f)) end
    assert(not pcall(M.unpack,'\1\0',1))
    assert(not pcall(M.unpack,string.pack('<I4',5)..'a',1))
    assert(not pcall(M.unpack,M.pack({'a','b'}),1))
    local large=string.rep('x\0',131072)
    assert(M.unpack(M.pack({large,large}),2)[2]==large)
    assert(not pcall(M.pack,{string.rep('x',600000)}))
    for _,bad in ipairs({
        function() return 1,'',10,2,1,1000 end,
        function() return 1,'',10,1,2,0 end,
        function() return 1,'',10,1,2,1000,'extra' end,
    }) do assert(not pcall(M.call,bad,5,4,1,{})) end
    local all={};for i=0,255 do all[#all+1]=string.char(i) end
    all=table.concat(all)
    M.call(function(_,_,_,hex,n)
        assert(n==#hex)
        local binary=hex:gsub('..',function(v)return string.char(tonumber(v,16))end)
        assert(M.unpack(binary,1)[1]==all,'all byte values survive native transport')
        return 1,'',10,1,2,1000
    end,3,4,1,{all})
end
do
    local s=fixture();local r=s.request(1)
    assert(s.backend.recover(r)==true and #s.workers==1)
    assert(s.backend.peek(r)==nil and s.backend.consume(r)==false)
    assert(s.backend.recover(s.request(2))==false)
    -- Mutating the caller's request cannot retarget the accepted worker.
    r.ticket=90;s.thread=11;s.workers[1]();s.thread=10
    assert(s.calls[#s.calls].cmd==4 and s.calls[#s.calls].ticket==1)
    r=s.request(1);s.terminal();local result=s.backend.peek(r)
    result.slots[1].status='valid'
    assert(s.backend.peek(r).slots[1].status=='missing')
    assert(s.backend.consume(r)==true)
    local count=#s.calls;assert(s.backend.consume(r)==true and #s.calls==count)
    assert(s.backend.recover(r)==false)
    assert(s.backend.recover(s.request(2))==true)
    s.callbacks[1]() -- a late completion cannot affect the new reservation
end
do
    local s=fixture();s.status=0
    assert(s.backend.recover(s.request(1))==false and #s.workers==0)
    s.status=1;assert(s.backend.recover(s.request(2))==true)
end
for _,failure in ipairs({'throw','schedule_throw','schedule_false'}) do
    local s=fixture();s[failure]=true
    assert(s.backend.recover(s.request(1))==nil)
    s[failure]=false
    assert(s.backend.recover(s.request(2))==false,'ambiguous admission must remain owned')
end
do
    local s=fixture();local r=s.request(1)
    assert(s.backend.recover(r));s.terminal(false)
    assert(s.backend.peek(r).certain==false and s.backend.consume(r)==false)
    assert(s.backend.recover(s.request(2))==false)
end
do
    local s=fixture();local r=s.request(1)
    assert(s.backend.recover(r));local f=s.terminal();f[3]='8';s.reply=M.pack(f)
    assert(not pcall(s.backend.peek,r));assert(s.backend.consume(r)==false)
    s.terminal();assert(s.backend.peek(r));s.status=0
    assert(s.backend.consume(r)==false)
    s.status=1;assert(s.backend.consume(r)==true)
end
do
    local s=fixture();local r=s.request(1,'update')
    r.preimages='token';r.payload='binary\0\255\n';r.journal_generation=2
    r.covered_revision=5;r.initialize=false
    assert(s.backend.update(r))
    local f=M.unpack(s.calls[1].bytes,5)
    assert(f[1]=='token' and f[2]==r.payload and f[3]=='2' and f[4]=='5' and f[5]=='0')
    s.terminal(true,'update');assert(s.backend.peek(r));assert(s.backend.consume(r))
end
do
    local s=fixture();local r=s.request(1)
    assert(s.backend.recover(r));s.terminal()
    s.thread=11;assert(not pcall(s.backend.peek,r),'wrong-thread reply cannot be accepted')
    s.thread=10;assert(s.backend.peek(r))
    s.throw=true;assert(not pcall(s.backend.consume,r))
    s.throw=false;assert(s.backend.consume(r))
end
print('native adapter: binary protocol, immutable tickets, uncertainty, retained ACK and scope checks passed')
