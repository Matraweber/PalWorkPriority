-- Checksums prove bytes, not valid settings. Unknown newer semantics must block
-- recovery instead of selecting an older generation and overwriting the newer.
package.loaded.datafile={read=function() error('IO') end,write=function() error('IO') end}
package.loaded.log={error=function() error('log') end,warn=function() error('log') end}
local Store,Caps=require('store'),require('caps')
local Queue=dofile(TEST_ROOT..'/experiments/save_scratch.lua')
local function record(generation,payload)
    local text=string.format('PWP-SCRATCH-1:%d:%s:%d:%s',5,'scope',generation,payload)
    local h=2166136261
    for i=1,#text do h=((h~text:byte(i))*16777619)&0xffffffff end
    return {session='scope',generation=generation,payload=payload,checksum=string.format('%08x',h)}
end
local function fixture(records,validator)
    local f={reads=0,writes=0}
    local adapter={start_read=function(_,ticket) f.reads=f.reads+1;f.ticket=ticket;return true end,
        start=function() f.writes=f.writes+1;return true end,
        poll=function(ticket)
            assert(ticket==f.ticket)
            local r=records[f.reads]
            return {ticket=ticket,success=true,read=r and {status='ok',record=r} or {status='missing'}}
        end}
    f.options={validate_payload=validator}
    f.q=Queue.new(adapter,'scope','boot',f.options)
    return f
end
local function validator(module) return function(payload) return module.decode_snapshot(payload)~=nil end end
for _,case in ipairs({{Store,'pal|1|X\n','slot1|1|X\n'},
    {Store,'pal|1|1\n','pal|1|X\npal|1|2\n'},
    {Caps,'guild|Mining|Stone|OFF\n','guild|Unknown|Stone|1\n'}}) do
    local module,good,bad=table.unpack(case)
    -- No generation increment, enqueued write or payload loss on invalid edits.
    local f=fixture({},validator(module));assert(f.q:recover());f.q:poll();assert(f.q:poll())
    assert(not pcall(f.q.submit,f.q,bad),'invalid snapshot was admitted')
    assert(f.q.generation==0 and f.writes==0 and f.q.state=='idle')
    -- Either slot order: valid checksummed newer-but-unparseable blocks all writes.
    for _,rows in ipairs({{record(1,good),record(2,bad)},{record(2,bad),record(1,good)}}) do
        f=fixture(rows,validator(module));assert(f.q:recover())
        f.q:poll();if f.q.state=='recovering' then f.q:poll() end
        assert(f.q.state=='error' and f.q.recovered_payload==nil)
        assert(not pcall(f.q.submit,f.q,good) and f.writes==0)
    end
    f=fixture({record(1,good),record(2,good)},validator(module))
    assert(f.q:recover());f.q:poll();local ok,payload=f.q:poll()
    assert(ok and payload==good and f.q.saved==2)
    assert(f.q:submit(good)==3 and f.writes==1)
end
for _,answer in ipairs({false,1,'true',{},function() error('validator failed') end}) do
    local check=type(answer)=='function' and answer or function() return answer end
    local f=fixture({record(2,'pal|1|X\n')},check)
    assert(f.q:recover());f.q:poll()
    assert(f.q.state=='error' and f.writes==0)
end
assert(not pcall(Queue.new,{},'scope','boot',{validate_payload=true}))
-- Capture policy once; changing options cannot disable validation mid-recovery.
local frozen=fixture({record(2,'pal|1|X\n')},function() return false end)
frozen.options.validate_payload=nil
assert(frozen.q:recover());frozen.q:poll()
assert(frozen.q.state=='error' and frozen.writes==0,'policy mutated after construction')
print('semantic payload gate: real parsers, invalid submissions, both recovery orders, validator failures; no native claims')
