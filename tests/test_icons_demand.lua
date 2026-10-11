-- Real icon module; mock native return/lifetime contracts and clock only.
-- No filesystem writes, game interaction, or native timing claims.
local failures = {}
local original_clock, original_open = os.clock, io.open
local function upvalue(fn, wanted, seen)
    seen=seen or {}
    if seen[fn] then return end
    seen[fn]=true
    for i=1,100 do
        local name, value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value end
        if type(value)=='function' then
            local found=upvalue(value,wanted,seen)
            if found~=nil then return found end
        end
    end
end
local function fixture(names)
    local f = {now=0, cost=0, epoch=1, loads={}, scans=0, stale=0,
        available={}, resident={}, timers={}, pins={}, callbacks=0, serial=0,
        wrappers=setmetatable({}, {__mode='v'}), saved=''}
    os.clock = function() return f.now end
    io.open = function(_, mode)
        if mode == 'r' then return nil end
        assert(mode == 'wb')
        return {write=function(_, text) f.saved=f.saved..text end, close=function() end}
    end
    package.loaded.log = {say=function() end, debug=function() end, warn=function() end}
    package.loaded.clock = {
        every=function(name, ms, fn) assert(ms==100); f.timers[name]=fn end,
        cancel=function(name) f.timers[name]=nil end,
    }
    package.loaded.icondex = {NAMES=names or {}, PATHS={}, FOLDER='/Test/Icons/'}
    package.loaded.palapi = {}
    local function texture(name, valid)
        local epoch = f.epoch
        f.serial = f.serial + 1
        local function fresh()
            if f.epoch ~= epoch then f.stale=f.stale+1; error('stale wrapper member call') end
        end
        local t = {
            IsValid=function() fresh(); return valid end,
            GetFName=function() fresh(); return {ToString=function() fresh(); return 'T_itemicon_'..name end} end,
        }
        f.wrappers[f.serial] = t
        return t
    end
    LoadAsset = function(path)
        local name = assert(path:match('T_itemicon_([^%.]+)$'))
        assert(path == '/Test/Icons/T_itemicon_'..name..'.T_itemicon_'..name)
        f.loads[#f.loads+1] = name
        f.now = f.now + f.cost
        if f.available[name] == 'error' then error('load refused') end
        if f.available[name] == 'invalid' then return texture(name, false) end
        if f.available[name] then return texture(name, true) end
    end
    FindAllOf = function(class)
        assert(class=='Texture2D')
        f.scans=f.scans+1
        assert(not f.in_get, 'get performed global Texture2D discovery')
        local out={}
        for name in pairs(f.resident) do out[#out+1]=texture(name,true) end
        return out
    end
    StaticFindObject = function() error('demand path performed array lookup') end
    package.loaded.icons=nil
    f.icons=require('icons')
    function f.call(fn)
        local ok, result=pcall(fn)
        f.epoch=f.epoch+1
        assert(ok, result)
        assert(f.stale==0, 'pcall hid a stale wrapper access')
        return result
    end
    function f.get(id)
        f.in_get=true
        local ok, result=pcall(f.call, function() return f.icons.get(id) end)
        f.in_get=false
        assert(ok, result)
        return result
    end
    function f.beat()
        f.now=f.now+0.101
        f.call(assert(f.timers.icons_pump, 'pump timer missing'))
    end
    function f.drain()
        for _=1,100 do if not f.timers.icons_pump then return end; f.beat() end
        error('pump did not drain')
    end
    function f.pin()
        f.icons.on_sweep=function(found)
            local count=0
            for name, tex in pairs(found) do
                assert(tex:IsValid())
                f.pins[name]=true -- engine ownership simulated; no Lua wrapper kept
                count=count+1
            end
            assert(count==1, 'load callback must offer exactly its fresh texture')
            f.callbacks=f.callbacks+1
            f.now=f.now+(f.pin_cost or 0)
        end
    end
    return f
end
local function case(name, fn)
    local ok, err=pcall(fn)
    if not ok then failures[#failures+1]=name..': '..tostring(err) end
end

case('pump uses native return without rediscovery', function()
    local f=fixture()
    f.available.Material_Direct=true; f.pin()
    assert(upvalue(f.icons.get,'want'))('Material_Direct')
    f.beat()
    assert(f.callbacks==1 and f.pins.Material_Direct,
        'pump discarded LoadAsset return instead of immediate pin handoff')
    assert(f.scans==0 and #f.loads==1)
end)

case('cold handoff, singleton callback and no retained wrappers', function()
    local f=fixture({stone='Material_Stone', wood='Material_Wood'})
    f.available.Material_Stone=true; f.available.Material_Wood=true; f.pin()
    assert(f.get('Stone')==nil and f.get('Wood')==nil)
    assert(#f.loads==0 and f.scans==0, 'cold draw must only queue')
    f.beat()
    assert(f.callbacks==2 and f.pins.Material_Stone and f.pins.Material_Wood)
    assert(f.icons.name_for('Stone')=='Material_Stone')
    assert(f.loads[1]=='Material_Stone' and f.loads[2]=='Material_Wood')
    collectgarbage('collect')
    assert(next(f.wrappers)==nil, 'icon module retained a texture after callback')
    assert(not f.timers.icons_pump and f.scans==0)
end)

case('self-named suffix bypasses unknown discovery', function()
    local f=fixture({giga='PalSphere_Giga'})
    f.available.PalSphere_Giga=true; f.pin()
    f.get('PalSphere_Giga'); f.beat()
    assert(f.icons.name_for('PalSphere_Giga')=='PalSphere_Giga' and f.callbacks==1 and f.scans==0)
end)

case('pin unavailable, stale wrappers, collection, and late reload', function()
    local f=fixture({stone='Material_Stone'})
    f.available.Material_Stone=true
    f.get('Stone'); f.beat()
    assert(f.get('Stone')~=nil, 'no pin must still return a fresh texture')
    collectgarbage('collect')
    assert(next(f.wrappers)==nil)
    f.available.Material_Stone='invalid'
    assert(f.get('Stone')==nil, 'invalid fresh result handed to caller')
    local before=#f.loads
    for _=1,20 do assert(f.get('Stone')==nil) end
    assert(#f.loads==before, 'failed load retried without cooldown')
    f.now=f.now+0.501; f.available.Material_Stone=true
    assert(f.get('Stone')==nil); f.beat()
    assert(f.get('Stone')~=nil and not f.icons.gave_up('Stone') and f.scans==0)
end)

case('nil, invalid and throwing loads all permit late recovery', function()
    for _,result in ipairs({false, 'invalid', 'error'}) do
        local f=fixture({late='Material_Late'})
        f.available.Material_Late=result; f.pin()
        f.get('Late'); f.beat()
        assert(f.callbacks==0)
        for _=1,10 do assert(f.get('Late')==nil) end
        assert(#f.loads==1 and not f.icons.gave_up('Late'))
        f.now=f.now+0.501; f.available.Material_Late=true
        f.get('Late'); f.beat()
        assert(f.callbacks==1 and f.pins.Material_Late and f.scans==0)
    end
end)

case('callback cost, errors, FIFO and shared draw budget', function()
    local f=fixture({a='Material_A', b='Material_B', c='Material_C'})
    for _,n in ipairs({'Material_A','Material_B','Material_C'}) do f.available[n]=true end
    f.pin(); f.pin_cost=0.010
    f.get('A'); f.get('B'); f.get('C'); f.beat()
    assert(#f.loads==1 and f.timers.icons_pump, 'pin cost escaped soft budget')
    assert(f.get('A')==nil and #f.loads==1, 'draw bypassed budget/FIFO')
    f.icons.on_sweep=function() f.now=f.now+0.010; error('panel unavailable') end
    f.beat(); assert(#f.loads==2 and f.timers.icons_pump)
    f.beat(); assert(#f.loads==3 and not f.timers.icons_pump)
    assert(f.get('C')==nil, 'same-slice draw bypassed exhausted allowance')
    f.now=f.now+0.101
    assert(f.get('C')~=nil, 'callback error made loaded icon unrecoverable')
    assert(f.loads[1]=='Material_A' and f.loads[2]=='Material_B' and f.loads[3]=='Material_C')
    assert(f.scans==0)
end)

case('coarse clock count ceiling also bounds pinless draws', function()
    local f=fixture({a='Material_A'})
    f.available.Material_A=true; f.get('A'); f.beat()
    for _=1,11 do assert(f.get('A')~=nil) end
    assert(#f.loads==12)
    for _=1,160 do assert(f.get('A')==nil) end
    assert(#f.loads==12 and not f.icons.gave_up('A'))
    f.now=f.now+0.101; assert(f.get('A')~=nil)
end)

case('unknown category guesses resolve directly and persist names', function()
    local f=fixture()
    f.available.Material_Mystery=true; f.pin()
    f.get('Mystery'); f.drain()
    assert(f.icons.name_for('Mystery')=='Material_Mystery' and f.pins.Material_Mystery)
    assert(f.saved:find('mystery|Material_Mystery',1,true) and f.scans==0)
end)

case('wrong index category recovers without array discovery', function()
    local f=fixture({thing='food_Thing'})
    f.available.Material_Thing=true; f.pin()
    f.get('Thing'); f.beat()
    for _=1,151 do f.get('Thing') end
    f.drain()
    assert(f.icons.name_for('Thing')=='Material_Thing' and f.pins.Material_Thing)
    assert(not f.icons.gave_up('Thing') and f.scans==0)
    f.icons.reset(); f.get('Thing'); f.drain()
    assert(f.icons.name_for('Thing')=='Material_Thing', 'reset preferred known-wrong index over correction')
    f.icons.reset(); f.available.Material_Thing=nil; f.available.food_Thing=true
    f.get('Thing'); f.beat()
    for _=1,151 do f.get('Thing') end
    f.drain()
    assert(f.icons.name_for('Thing')=='food_Thing')
    f.icons.reset(); f.get('Thing')
    assert(f.icons.name_for('Thing')=='food_Thing', 'correction back to index left stale learned override')
end)

case('nonstandard resident name fallback is deferred and throttled', function()
    local f=fixture()
    f.resident.FutureCategory_Odd=true; f.available.FutureCategory_Odd=true; f.pin()
    f.get('Odd'); f.drain()
    assert(f.scans==0)
    f.get('Odd'); assert(f.scans==0, 'missing-name discovery ran in draw')
    f.beat()
    assert(f.scans==1 and f.pins.FutureCategory_Odd and f.icons.name_for('Odd')=='FutureCategory_Odd')
    f.get('Missing'); f.drain(); f.get('Missing')
    assert(f.scans==1 and f.icons.gave_up('Missing'), 'true miss or scan throttle lost')
    f.icons.reset(); f.get('Missing'); f.drain(); f.get('Missing')
    f.resident.FutureCategory_Missing=true; f.available.FutureCategory_Missing=true
    f.beat()
    assert(f.icons.name_for('Missing')=='FutureCategory_Missing', 'world reset prevented late recovery')
end)

case('speculation keeps session cap and waits behind demand', function()
    local f=fixture({known='Material_Known'})
    f.available.Material_Known=true
    f.get('Known')
    for _=1,151 do f.get('Unknown') end
    f.beat()
    assert(#f.loads==1 and f.loads[1]=='Material_Known')
    f.get('Unknown'); f.drain()
    assert(#f.loads==25, 'unknown id was condemned while real work was queued')
    for i=2,81 do f.get('Unknown'..i); f.drain() end
    assert(#f.loads==1+80*24, 'speculative load budget changed')
    f.icons.shutdown(); assert(not f.timers.icons_pump)
end)

os.clock, io.open=original_clock, original_open
assert(#failures==0, table.concat(failures,'\n'))
