-- Geometry contract for the real renderer; font extents use its existing
-- 1.35 line-height estimate, not a claim about native Slate glyph rasterization.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
function Widget:SetShadowOffset(v) self.shadow=v end
rules(2);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local function near(a,b) assert(math.abs(a-b)<0.000001, tostring(a)..' ~= '..tostring(b)) end
local function check_geometry()
 local jobs,labels=0,0
 for _,w in ipairs(registry) do
  if not w.dead and w.text=='Whole work type' then
   labels=labels+1
   local job
   for _,other in ipairs(w.parent.children) do if other.text=='Mining' then job=other end end
   assert(job,'subtitle has no matching Job line')
   jobs=jobs+1
   local height=w.parent.parent.height
   near(height,34)
   -- Both lines, including the actual requested shadow offset, fit and do
   -- not overlap. The one-pixel shadow is part of the geometry budget.
   local first_bottom=job.Slot.position.Y+job.Font.Size*1.35+job.shadow.Y
   local second_bottom=w.Slot.position.Y+w.Font.Size*1.35+w.shadow.Y
   assert(job.Slot.position.Y>=0 and first_bottom<=w.Slot.position.Y,
    'Job line including shadow overlaps subtitle')
   assert(second_bottom<=height,'Whole work type including shadow overflows row')
   near(job.Slot.position.Y,1);near(job.Font.Size,13)
   near(w.Slot.position.Y,20);near(w.Font.Size,9)
   near(job.Slot.position.X,38);near(w.Slot.position.X,38)
  end
 end
 assert(jobs==2 and labels==2)
 -- Baseline coordinates from the pre-fix two-rule renderer. The Job change
 -- must not move the header, other columns, row hosts or amount editor.
 near(overlay.width,1110)
 local expected={Stone01={210,3.315},Stone02={210,3.315},
  ['37']={595.52,3.315},['0']={607.76,3.315},
  ['101']={725.28,3.315},['102']={725.28,3.315},
  ['No count yet']={810,3.315},Remove={1002.67,3.315},
  JOB={38,4.34},ITEM={210,4.34},LIMIT={728.4,4.34},
  ['Production Limits']={18,4.29}}
 for text,xy in pairs(expected) do
  local w=rendered(text)
  if text~='101' or not bound_editor then
   assert(w,'missing baseline text: '..text)
   near(w.Slot.position.X,xy[1]);near(w.Slot.position.Y,xy[2])
  end
 end
end
check_geometry()
panel.apply(cfg,{kind='rule',rule={work='Mining',item='Stone01',amount=101},row=4},-1,true)
panel.refresh(cfg)
local editor=assert(bound_editor)
near(editor.Slot.position.X,638);near(editor.Slot.position.Y,2)
near(editor.Slot.size.X,136);near(editor.Slot.size.Y,30)
check_geometry()
panel.cancel_edit();panel.refresh(cfg);check_geometry()
assert(writes==0 and stale==0)
]=], '@legacy-geometry'))()
