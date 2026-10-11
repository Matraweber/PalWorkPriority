-- Physical append order in the real renderer; this does not model Slate cost.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
local fixture=source:sub(1,start-1)
local failures={}
for _,scenario in ipairs({'partial','growth','rules_growth','rules_short_page','collapse_false','collapse_throw'}) do
    package.loaded.panel=nil
    HOST_ORDER_SCENARIO=scenario
    local ok,why=pcall(assert(load(fixture..'\n'..[=[
local scenario=HOST_ORDER_SCENARIO
local now=100
os.clock=function() return now end
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
local rb
for i=1,100 do
    local name,value=debug.getupvalue(panel.refresh,i)
    if name=='RB' then rb=value break end
end
assert(rb)
local attaches,collapse_writes=0,0
local constructed={}
local construct=StaticConstructObject
StaticConstructObject=function(cls,...)
    constructed[cls.kind]=(constructed[cls.kind] or 0)+1
    return construct(cls,...)
end
local refuse_collapse=false
local add,visibility=Widget.AddChild,Widget.SetVisibility
function Widget:AddChild(child)
    if self==overlay.parts.ItemList or self==overlay.parts.RuleList then
        if child.kind=='SizeBox' and #child.children[1].children==0 then
            -- A populated host may be made visible later; reservations must
            -- already be collapsed at the moment they enter native flow.
            local is_pager=(self==overlay.parts.ItemList and #self.children==9)
                or (self==overlay.parts.RuleList and #self.children==13)
            if not is_pager then assert(child.visibility==1, 'visible reservation attached') end
        end
        attaches=attaches+1
    end
    return add(self,child)
end
function Widget:SetVisibility(value)
    if self.kind=='SizeBox' and value==1 then collapse_writes=collapse_writes+1 end
    if refuse_collapse and self.kind=='SizeBox' and value==1 then
        refuse_collapse=false
        if scenario=='collapse_throw' then error('native collapse failed') end
        return false
    end
    return visibility(self,value)
end
local function stock(n)
    local out={}
    for i=1,n do out['Stone'..string.char(64+math.ceil(i/26))..string.char(65+i%26)]=n+1-i end
    scheduler.last_totals_by_camp.base1=out
end
local function ordered(which,first,pager,visible)
    local prev=first-1
    local seen={}
    for _,box in ipairs(overlay.parts[which].children) do
        local index
        for key,saved in pairs(rb.hosts) do
            if saved.box==box.name then index=tonumber(key:match('^'..which..':(%d+)$')) end
        end
        assert(index, 'untracked list child')
        assert(index>prev, which..' pager/row append order: '..prev..' then '..index)
        prev=index; seen[index]=box
        if index~=pager and index>=first+visible then
            assert(box.visibility==1, 'unused host occupies list height')
        end
    end
    return seen
end
local function settle()
    for i=1,40 do
        now=now+.02; panel.refresh(cfg)
        if not rb.pending then return end
    end
    error('fill did not finish')
end
if scenario=='partial' or scenario=='growth' or scenario:match('^collapse_') then
    stock(scenario=='partial' and 14 or 3)
    local seen={}
    caps.support=function(_,item)
        if scenario=='partial' and not seen[item] then now=now+.002; seen[item]=true end
        return false
    end
    panel.refresh(cfg); panel.toggle(); panel.refresh(cfg)
    rb.SLICE=.007
    panel.set_screen('item')
    refuse_collapse=scenario:match('^collapse_')~=nil
    panel.refresh(cfg)
    if scenario:match('^collapse_') then
        assert(rb.pending and #overlay.parts.ItemList.children==0,
            'failed collapse attached a visible reservation or skipped retry')
        assert(rb.hosts['ItemList:0']==nil, 'failed collapse cached success')
        panel.refresh(cfg)
    end
    if scenario=='partial' then assert(rb.pending, 'fixture missed interrupted first fill') end
    local hosts=ordered('ItemList',0,9,scenario=='partial' and 2 or 1)
    for i=5,8 do if hosts[i] then assert(#hosts[i].children[1].children==0, 'reservation built tile widgets') end end
    settle()
    if scenario=='growth' then stock(54); panel.refresh(cfg); settle() end
    ordered('ItemList',0,9,scenario=='partial' and 5 or (scenario=='growth' and 9 or 1))
    assert(#overlay.parts.ItemList.children==10, 'picker host count is not bounded')
    if scenario=='growth' then
        panel.apply(cfg,{kind='page',by=1},-1,true); panel.refresh(cfg); settle()
        assert(rendered('page 2 of 2'), 'growth lost picker navigation')
    end
    for i=0,8 do assert(rb.runtime.objects[rb.hosts['ItemList:'..i].box]==hosts[i], 'host replaced') end
else
    rules(scenario=='rules_short_page' and 14 or 1)
    panel.refresh(cfg)
    if scenario=='rules_short_page' then rb.rule_page=1 end
    panel.toggle(); panel.refresh(cfg)
    local hosts=ordered('RuleList',1,14,1)
    for i=2,13 do if hosts[i] then assert(#hosts[i].children[1].children==0, 'reservation built rule widgets') end end
    if scenario=='rules_short_page' then
        panel.apply(cfg,{kind='rpage',by=-1},-1,true)
    else rules(14) end
    panel.refresh(cfg)
    ordered('RuleList',1,14,13)
    assert(#overlay.parts.RuleList.children==14, 'rules host count is not bounded')
    assert(rendered('page 1 of 2, 14 limits'), 'rules pager lost navigation')
    for i=1,13 do assert(rb.runtime.objects[rb.hosts['RuleList:'..i].box]==hosts[i], 'rule host replaced') end
end
local before,attached=count,attaches
for i=1,3 do now=now+1; panel.refresh(cfg) end
assert(count==before and attaches==attached, 'settled draw constructed or reparented hosts/widgets')
assert(stale==0 and writes==0, 'stale wrapper access or settings write')
local expected=scenario:match('^rules_') and 14 or (scenario:match('^collapse_') and 11 or 10)
assert(constructed.SizeBox==expected and constructed.CanvasPanel==expected,
    'unexpected cold host construction count')
print('PASS host order '..scenario..': host pairs constructed='..expected..', list attachments='..attaches)
]=], '@panel-host-order-'..scenario)))
    if not ok then failures[#failures+1]=scenario..': '..tostring(why) end
end
assert(#failures==0, table.concat(failures,'\n'))
print('PASS ordered collapsed hosts: partial fill, growth, short rules page, reuse and bounds')
