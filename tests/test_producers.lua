local p = require('producers')
local calls, allowed = 0, nil
local function adapter(bound)
    return { supports = function(work,item) return work=='Mining' and item=='Stone' end,
        evidence='mock control only; not a native adapter', max_inflight=bound,
        admit=function(_,_,allow) calls=calls+1; allowed=allow; return true end }
end
assert(not p.register('bad',adapter(0/0)))
assert(not p.register('bad',adapter(math.huge)))
assert(p.register('mock',adapter(2)))
local scope={guild='G',camp='C'}
local function admit(stock,ceiling,s,started)
    return p.admit('mock',{},'Stone',stock,ceiling,s,started,'Mining')
end
assert(admit(9,10,scope,false)==true and allowed==true)
assert(admit(10,10,scope,false)==false and allowed==false)
local before=calls
assert(admit(10,10,scope,true)==true and calls==before)
for _,n in ipairs({0/0,math.huge,-math.huge,-1}) do
    assert(admit(n,10,scope,false)==nil)
    assert(admit(9,n,scope,false)==nil)
end
assert(admit(9,10,{guild=true,camp='C'},false)==nil)
assert(admit(9,10,{guild='G',camp=''},false)==nil)
assert(admit(9,10,scope,nil)==nil, 'unknown started state was treated as ready')
assert(calls==before, 'invalid evidence reached producer controls')
