local p = require('producers')
local calls = 0
assert(p.register('stone', {
    supports=function(work,item) return work=='Mining' and item=='Stone' end,
    admit=function() calls=calls+1; return true end,
    evidence='offline mock only', max_inflight=2,
}))
local scope={guild='G',camp='C'}
local function admit(work,item,started)
    return p.admit('stone',{},item,0,10,scope,started,work)
end
assert(admit('Mining','Ore',false)==nil, 'unsupported output reached control')
assert(admit('Logging','Stone',false)==nil, 'wrong work reached control')
assert(admit(nil,'Stone',false)==nil, 'unknown work reached control')
assert(admit('Mining','',false)==nil)
assert(admit('Mining',nil,false)==nil)
assert(admit('Mining','Ore',true)==nil, 'started bypassed output binding')
assert(admit('Logging','Stone',true)==nil, 'started bypassed work binding')
assert(calls==0, 'invalid binding invoked admission callback')
assert(admit('Mining','Stone',false)==true and calls==1)
local ok,bound=admit('Mining','Stone',true)
assert(ok==true and bound==2 and calls==1, 'started work was interrupted')
local denied_supports={
    {'false', function() return false end},
    {'nil', function() return nil end},
    {'string', function() return 'true' end},
    {'number', function() return 1 end},
    {'table', function() return {} end},
    {'throw', function() error('unavailable') end},
}
for _,case in ipairs(denied_supports) do
    -- Isolate each registry so another adapter cannot mask a false result.
    local isolated=dofile(TEST_ROOT..'/Scripts/producers.lua')
    local control_calls, support_calls=0,0
    assert(isolated.register('denied', {
        supports=function(work,item)
            support_calls=support_calls+1
            assert(work=='Mining' and item=='Stone')
            return case[2]()
        end,
        -- Return a rejected result so the public return alone cannot catch an
        -- accidental call. A throwing sentinel is swallowed by admit's pcall.
        admit=function() control_calls=control_calls+1; return false end,
        evidence='mock',max_inflight=0,
    }))
    assert(isolated.admit('denied',{},'Stone',0,10,scope,false,'Mining')==nil)
    assert(control_calls==0, case[1]..' support reached admission callback')
    assert(support_calls==1, case[1]..' admission skipped support check')
    assert(isolated.support('Mining','Stone')==false,
        case[1]..' support advertised capability')
    assert(support_calls==2, case[1]..' capability skipped support check')
    assert(control_calls==0, case[1]..' capability invoked admission callback')
end
local supported,id=p.support('Mining','Stone')
assert(supported==true and id=='stone', 'exact true support was rejected')
for _,fn in ipairs({function() return false end, function() error('failed') end}) do
    assert(p.register('failed', {supports=function() return true end,
        admit=fn,evidence='mock',max_inflight=0}))
    assert(p.admit('failed',{},'Stone',0,10,scope,false,'Mining')==nil)
end
