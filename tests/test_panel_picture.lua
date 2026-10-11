-- Exercise the real picture function with the existing panel/UMG fixture.
-- No native timing/lifetime claims and no game or filesystem writes.
dofile(TEST_ROOT .. '/tests/test_panel_render.lua')
local panel, icons = require('panel'), require('icons')
local function upvalue(fn, wanted, seen)
    seen=seen or {}
    if seen[fn] then return end
    seen[fn]=true
    for i=1,100 do
        local name,value=debug.getupvalue(fn,i)
        if not name then break end
        if name==wanted then return value,fn,i end
        if type(value)=='function' then
            local found,owner,index=upvalue(value,wanted,seen)
            if found~=nil then return found,owner,index end
        end
    end
end
local picture=assert(upvalue(panel.refresh,'picture'))
local rb=assert(upvalue(picture,'RB'))
local drawn=assert(upvalue(picture,'drawn'))
local images=assert(upvalue(picture,'images'))
local retry=assert(upvalue(picture,'icon_retry'))
local _,budget_owner,budget_index=upvalue(picture,'icon_budget')
-- The old implementation had a one-time diagnostic latch; reset it so this
-- regression also detects the unwanted first-picture call on the old source.
local _,probe_owner,probe_index=upvalue(picture,'probed')
if probe_owner then debug.setupvalue(probe_owner,probe_index,false) end
local probes,gets=0,{}
icons.probe=function() probes=probes+1 end
icons.name_for=function() return nil end -- isolate visible brush from pinning
local available={A={id='A'},B={id='B'}}
icons.get=function(id) gets[#gets+1]=id; return available[id] end
local old_clock=os.clock
local now=100
os.clock=function() return now end
rb.prof, rb.slot, rb.base = {}, nil, 0
local key,cache_key='picture_regression','i:picture_regression'
local function draw(token,budget)
    debug.setupvalue(budget_owner,budget_index,budget or 3)
    picture(key,0,0,32,token,token)
end
draw('A')
assert(probes==0, 'first picture invoked the unrelated four-icon probe')
assert(#gets==1 and gets[1]=='A', 'first picture requested unrelated icons')
local img=assert(images[key])
assert(drawn[cache_key]=='A' and img.opacity==1 and img.Brush.ResourceObject==available.A)
assert(img.visibility==0 and img.parent, 'picture lost its visible hit surface')

local writes, applications=0,0
local opacity_failure,apply_failure
img.SetOpacity=function(self,value)
    writes=writes+1
    if opacity_failure=='throw' then error('opacity refused') end
    if opacity_failure==value then return false end
    self.opacity=value
end
img.SetBrushFromTexture=function(self,texture)
    applications=applications+1
    if apply_failure=='throw' then error('brush refused') end
    if apply_failure then return false end
    self.Brush.ResourceObject=texture
end

-- Hide BEFORE both early returns, without repeating writes while pending.
retry[key]=now+1
local before_gets=#gets
draw('B',0)
assert(img.opacity==0 and drawn[cache_key]==nil and writes==1)
assert(#gets==before_gets and img.Brush.ResourceObject==available.A)
for _=1,5 do draw('B',0) end
assert(writes==1, 'pending retry rewrote opacity')
retry[key]=nil
draw('B',0)
assert(writes==1 and #gets==before_gets, 'budget wait retried work')
assert(img.visibility==0 and img.parent, 'pending picture stopped being a hit surface')

-- Switching back while pending must not mistake the old drawn token for a
-- still-visible picture. Successful application precedes opacity restoration.
draw('A')
assert(img.opacity==1 and drawn[cache_key]=='A' and writes==2)
draw('A')
assert(writes==2, 'unchanged successful picture rewrote opacity')

available.B=nil
draw('B')
local hidden_writes=writes
assert(img.opacity==0 and drawn[cache_key]==nil)
for _=1,5 do draw('B') end
assert(writes==hidden_writes, 'missing icon rewrote pending opacity')
now=now+2; available.B={id='B'}
draw('B')
assert(img.opacity==1 and drawn[cache_key]=='B' and img.Brush.ResourceObject==available.B)

-- False/throwing hide setters cannot commit a cache or proceed to lookup.
for _,failure in ipairs({0,'throw'}) do
    opacity_failure=failure
    before_gets=#gets
    local before_apply=applications
    draw('A',0)
    assert(rb.vis[cache_key]==nil and drawn[cache_key]=='B')
    assert(#gets==before_gets and applications==before_apply)
    local before_retry=writes
    draw('A',0)
    assert(writes==before_retry+1, 'failed hide was cached as successful')
end
opacity_failure=nil
draw('A',0)
assert(img.opacity==0 and rb.vis[cache_key]==0 and drawn[cache_key]==nil)

-- Brush failures must not reveal the previous image or commit the new token.
for _,failure in ipairs({true,'throw'}) do
    apply_failure=failure
    local before=writes
    draw('A')
    assert(img.opacity==0 and drawn[cache_key]==nil and writes==before)
end
apply_failure=nil
opacity_failure=1
draw('A')
assert(img.opacity==0 and drawn[cache_key]==nil and rb.vis[cache_key]==nil,
    'failed restore committed the displayed token/opacity')
opacity_failure=nil
draw('A')
assert(img.opacity==1 and drawn[cache_key]=='A' and rb.vis[cache_key]==1)

-- blank_unused owns a separate drawn="clear" write. Its opacity change
-- cannot leave a successful opacity memo suppressing the next restoration.
local blank=assert(upvalue(panel.refresh,'blank_unused'))
local used=assert(upvalue(blank,'used'))
used[cache_key]=nil
blank()
assert(img.opacity==0 and drawn[cache_key]=='clear')
draw('A')
assert(img.opacity==1 and drawn[cache_key]=='A')
assert(probes==0)
os.clock=old_clock
