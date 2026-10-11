-- Real main maintenance, real stand refresh and real store; native boundaries
-- and file IO reuse the main integration fixture. No installed/game files.
local function read(path)
    local f=assert(io.open(TEST_ROOT..path,'r'));local s=f:read('*a');f:close();return s
end
local ui_source=read('/Scripts/ui.lua')
local main_fixture=read('/tests/test_main_integration.lua')
local cut=assert(main_fixture:find('\ntest%("unsupported network'))
local checks=[=[
local s=boot(true);s.timers.role.fn();s.viewport=true
local ui=assert(load(real_ui_source,'@real-ui'))()
s.ui.refresh=ui.refresh
local flush=s.store.flush
local calls=0
s.store.flush=function(...)calls=calls+1;return flush(...)end
for _=1,10 do s.now=s.now+.1;s:ui_beat()end
assert(calls==1,'main plus real ui.refresh polled priorities twice: '..calls)
ui.refresh(s.cfg)
assert(calls==2,'standalone refresh must still flush')
-- Real remote processing occurs between the two sites. A new dirty edit must
-- invalidate the receipt, even in the same maintenance callback.
local changed=false
package.loaded.remote.poll=function()
    if not changed then changed=true;assert(s.store.apply_set('PAL-A',1,2))end
end
calls=0
for _=1,10 do s.now=s.now+.1;s:ui_beat()end
assert(calls==2 and changed,'intervening edit skipped the stand flush')
-- Session invalidation is independently checked by main, even before a store
-- role update propagates. No older callback receipt is valid in the new epoch.
assert(s.store.flush(nil,true))
package.loaded.remote.poll=function()s.session.epoch=s.session.epoch+1 end
calls=0
for _=1,10 do s.now=s.now+.1;s:ui_beat()end
assert(calls==2,'session reentry reused the previous flush receipt')
]=]
assert(load('local real_ui_source=...\n'..main_fixture:sub(1,cut-1)..'\n'..checks,'@ui-flush-receipt'))(ui_source)
