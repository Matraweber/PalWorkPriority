local now, scans, action=0,0,nil
os.clock=function() return now end
local api={latch_authority=function() return true end}
package.loaded.palapi=api
local p=require('storage_prefetch')
local cfg={enabled=true,storage_scope='global',interval_seconds=10,uncounted_containers={}}
local function sample()
    return {a={Stone=7}},{a=1},{complete=true,deduplicated=true,unknown_scope=0,reasons={}}
end
api.chest_totals_by_camp=function(opts)
    scans=scans+1
    if action then return action(opts) end
    return sample()
end
local function prepared()
    p.reset(); now=0; action=nil
    p.observe(cfg,'scope',0,true,30)
    now=20; p.observe(cfg,'scope',0,true,30)
    now=28
    assert(p.due(cfg,30))
end
prepared(); assert(p.refresh(cfg,30)); assert(not p.refresh(cfg,30)); now=29
local got=p.take(cfg,'scope',30)
assert(got.at==28 and got.by.a.Stone==7 and not p.take(cfg,'scope',30))
prepared(); p.refresh(cfg,30); now=58
assert(not p.take(cfg,'scope',30),'expired candidate adopted')
prepared(); p.refresh(cfg,30); now=27
assert(not p.take(cfg,'scope',30),'clock rollback adopted future data')
prepared(); action=function() p.reset(); return sample() end
assert(not p.refresh(cfg,30) and not p.take(cfg,'scope',30),'reset inside scan published old session')
prepared(); action=function() cfg.uncounted_containers[1]='changed'; return sample() end
assert(not p.refresh(cfg,30)); assert(not p.take(cfg,'scope',30))
cfg.uncounted_containers={}
prepared(); action=function() return {a=setmetatable({}, {})},{a=1},{complete=true} end
assert(p.refresh(cfg,30)); got=p.take(cfg,'scope',30)
assert(not got.evidence.complete and got.evidence.reasons.prefetch_read==1,'native-like table retained')
prepared(); action=function() error('native failure') end
assert(p.refresh(cfg,30)); got=p.take(cfg,'scope',30)
assert(not got.evidence.complete and next(got.by)==nil,'failed scan reused prior values')
prepared(); api.latch_authority=function() return false end
local before=scans; assert(not p.refresh(cfg,30) and scans==before,'client scanned authority stock')
api.latch_authority=function() return true end
prepared(); p.observe(cfg,'scope',0,false,30)
assert(not p.due(cfg,30),'incomplete inline read enabled eager prefetch')
prepared(); now=46
assert(not p.due(cfg,30),'interest lease never expired')
local clone={storage_scope='global',counted_containers={'B','A'},uncounted_containers={}}
local signature=p.filters(clone)
clone.counted_containers={'A','B'}
assert(p.filters(clone)==signature,'filter order changed scope')
clone.counted_containers={'A;1:B'}
assert(p.filters(clone)~=signature,'filter signature collided')

prepared(); now=21; p.request_refresh()
assert(p.due(cfg,30),'explicit refresh waited for TTL')
assert(p.refresh(cfg,30)); p.request_refresh()
assert(not p.take(cfg,'scope',30),'panel reopen kept an older candidate')
assert(p.refresh(cfg,30)); got=p.take(cfg,'scope',30); assert(got.at==21)
p.observe(cfg,'scope',21,true,30)
assert(not p.due(cfg,30),'completed inline/adopted scan did not clear the request')
prepared(); action=function() p.request_refresh(); return sample() end
assert(not p.refresh(cfg,30),'invalidation during scan published old candidate')
prepared(); p.request_refresh(); p.reset(); assert(not p.due(cfg,30))
