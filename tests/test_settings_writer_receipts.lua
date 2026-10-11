-- Real writer with controllable asynchronous session completion; no native IO.
local f=assert(io.open(TEST_ROOT..'/tests/test_settings_writer.lua','r'))
local source=f:read('*a');f:close()
local cut=assert(source:find('\ndo\n'))
local fixture=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@receipt-writer-fixture'))()
local function clone(t)local r={};for k,v in pairs(t)do r[k]=v end;return r end
local function pending()
    local f=fixture();local r=f.writer:submit('first')
    assert(r.state=='pending');return f,r.receipt
end
local function saved(f)f.state='saved';f.durable=f.revision end
local a,r=pending()
assert(type(a.writer.receipt_status)=='function','attachment-bound receipt query missing')
assert(a.writer:receipt_status(r).state=='saving','memory acceptance announced durable')
saved(a)
local v=a.writer:receipt_status(clone(r))
assert(v.state=='saved' and v.body=='first' and v.request_revision==1 and v.revision==1)
-- An older request can be covered by a newer durable snapshot, but that exact
-- current body must be returned rather than pretending the older value survived.
local second=a.writer:submit('second');assert(second.state=='pending')
assert(a.writer:receipt_status(r).state=='saving')
saved(a);v=a.writer:receipt_status(r)
assert(v.state=='saved' and v.body=='second' and v.request_revision==1 and v.revision==2)
-- Reloading the module must not restart attachment allocation while receipts
-- from older instances remain alive in this same Lua VM.
local original=package.loaded.settings_writer
package.loaded.settings_writer=dofile(TEST_ROOT..'/Scripts/settings_writer.lua')
local second_fixture=assert(load(source:sub(1,cut-1)..'\nreturn fixture','@reloaded-writer-fixture'))()
local replacement=second_fixture();local replacement_receipt=replacement.writer:submit('first').receipt
replacement.state='saved';replacement.durable=1
assert(replacement_receipt.attachment~=r.attachment)
assert(replacement.writer:receipt_status(r).state=='invalid_receipt','module reload reused receipt identity')
package.loaded.settings_writer=original
local b,other=pending();saved(b)
assert(b.writer:receipt_status(r).state=='invalid_receipt','replacement attachment accepted old receipt')
assert(a.writer:receipt_status(other).state=='invalid_receipt')
for _,key in ipairs({'scope','session','incarnation','epoch','revision','attachment'})do
    local bad=clone(r);bad[key]=nil
    assert(a.writer:receipt_status(bad).state=='invalid_receipt',key)
end
local bad=clone(r);bad.revision=0;assert(a.writer:receipt_status(bad).state=='invalid_receipt')
bad.revision=999;assert(a.writer:receipt_status(bad).state=='invalid_receipt')
assert(a.writer:receipt_status(setmetatable(clone(r),{})).state=='invalid_receipt')
-- Invalid requests must not poll or invoke an authority provider.
a.on_poll=function()error('invalid request crossed session boundary')end
assert(a.writer:receipt_status(bad).state=='invalid_receipt');a.on_poll=nil
for _,mode in ipairs({'close','reentry','throw','mutation','failure','uncertain'})do
    local x,t=pending();saved(x)
    if mode=='failure' then x.state='error'
    elseif mode=='uncertain' then x.state='uncertain'
    else x.on_poll=function()
        if mode=='close' then x.writer:close()
        elseif mode=='reentry' then assert(x.writer:receipt_status(t).state=='uncertain')
        elseif mode=='throw' then error('lost session result')
        elseif mode=='mutation' then t.revision=99 end
    end end
    assert(x.writer:receipt_status(t).state~='saved',mode..' returned durable success')
end
assert(a.writer:close());assert(a.writer:receipt_status(r).state=='stale')
local wh=assert(io.open(TEST_ROOT..'/Scripts/settings_writer.lua','r'))
local writer_source=wh:read('*a');wh:close()
for _,debug_api in ipairs({false,{}, {getregistry=function()error('unavailable')end}})do
    local isolated=assert(load(writer_source,'@no-registry','t',setmetatable({debug=debug_api},{__index=_G})))()
    local no,why=isolated.new(fixture().options)
    assert(no==nil and why=='attachment_identity_unavailable','missing registry did not refuse cleanly')
end
local registry=debug.getregistry();local counter_key='PalWorkPriority.settings_writer.attachment_serial.v1'
local original_counter=registry[counter_key]
for _,value in ipairs({2147483646,-1,1.5,'bad'})do
    registry[counter_key]=value
    local ok,err=pcall(fixture)
    registry[counter_key]=original_counter
    assert(not ok and tostring(err):find('attachment_limit',1,true),'invalid allocator state admitted writer')
end

print('PASS writer receipt: pending vs durable, original attachment, coalescing, reentry and revocation')
