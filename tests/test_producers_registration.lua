local p=require('producers')
local calls=0
local a={supports=function(w,i) return w=='Mining' and i=='Stone' end,
    admit=function() calls=calls+1;return true end,
    evidence='offline mock only',max_inflight=2}
assert(p.register('mock',a))
a.max_inflight=math.huge
a.evidence=''
a.supports=function() return true end
a.admit=function() error('mutated callback must not run') end
local ok,bound=p.admit('mock',{},'Stone',0,10,{guild='G',camp='C'},false,'Mining')
assert(ok==true and bound==2 and calls==1, 'registration retained mutable caller fields')
assert(p.support('Mining','Ore')==false, 'mutation broadened supported items')
assert(not p.register('mock',a), 'invalid replacement was accepted')
ok,bound=p.admit('mock',{},'Stone',0,10,{guild='G',camp='C'},true,'Mining')
assert(ok==true and bound==2 and calls==1, 'invalid replacement damaged registration')
