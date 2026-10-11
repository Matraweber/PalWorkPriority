package.loaded.log={warn=function()end,error=function()end}
local Coverage=dofile(TEST_ROOT..'/experiments/settings_priority_coverage.lua')
local Store=require('store')
local function fixture()
    local s=assert(Store.decode_snapshot(assert(Store.serialize_snapshot({pal={[1]=false,[2]=5}},true))))
    local r={complete=true,pals={{key='pal',capable={[1]=true,[2]=true}}}}
    return s,r
end
do local s,r=fixture();assert(Coverage.check(s,r) and s.data.pal[1]==false)end
for _,edit in ipairs({
    function(s)s.data.pal[2]=nil;s.count=1 end,
    function(s)s.data={};s.count=0 end,
    function(s)s.count=99 end,
    function(s)s.baseline='true'end,
    function(s)s.data.pal[1]=0 end,
    function(s)s.data.pal[1]='X'end,
    function(s)s.transient=1 end,
    function(s)setmetatable(s.data.pal,{})end,
    function(_,r)r.complete=false end,
    function(_,r)r.complete='true'end,
    function(_,r)r.pals[1].capable=nil end,
    function(_,r)r.pals[1].capable[3]=false end,
    function(_,r)r.pals[1].key='slot1'end,
    function(_,r)r.pals[2]=r.pals[1]end,
    function(_,r)r.pals[2]=r.pals[1];r.pals[1]=nil end,
    function(_,r)r.pals.extra={}end,
})do local s,r=fixture();edit(s,r);assert(not Coverage.check(s,r))end
do
    local s,r=fixture();s.baseline=false;s.data={};s.count=0
    assert(Coverage.check(s,r)) -- legacy config fallback, not fresh-install baseline
    r.pals[1].capable=nil;assert(not Coverage.check(s,r)) -- still needs complete census
end
do local s,r=fixture();r.pals={};assert(Coverage.check(s,r))end
print('priority coverage: complete roster, explicit X, absent baseline and malformed/duplicate census checks passed')
