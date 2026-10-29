-- Geometry contract for the real renderer; font extents use its existing
-- 1.35 line-height estimate, not a claim about native Slate glyph rasterization.
-- Round 2 (2026-10-29): the job cell is ONE line at the row's size. The two
-- line version (job 12pt over an 11pt "Group limit" / "Item limit, rocks",
-- 0 px between them) was too cramped to read in game (retest r03/r06). A
-- group row shows its job; a per-item Mining row "Mining (rocks)".
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a');f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
function Widget:SetShadowOffset(v) self.shadow=v end
rules(2);panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local function near(a,b) assert(math.abs(a-b)<0.000001, tostring(a)..' ~= '..tostring(b)) end
local function job_cells(text)
 local jobs=0
 for _,w in ipairs(registry) do
  if not w.dead and w.text==text then
   jobs=jobs+1
   near(w.parent.parent.height,34)
   -- One line, at the row's 17pt, on the same baseline as the item name.
   near(w.Font.Size,17);near(w.Slot.position.X,38);near(w.Slot.position.Y,3.315)
   -- Ends before ITEM (x 210) with room to spare. 0.59 per point is the
   -- mixed-case width measured off r03 (Lumbering, 12pt, 85 px).
   assert(38+#text*17*0.59<=210-8, text..' runs into the item column')
   for _,other in ipairs(w.parent.children) do
    assert(other.dead or (other.text~='Group limit' and other.text~='Item limit, rocks'),
     'the two-line sub-label is still drawn')
   end
  end
 end
 return jobs
end
local function check_geometry()
 assert(job_cells('Mining')==2, 'group rows do not show just the job')
 -- Baseline coordinates from the pre-fix two-rule renderer. The Job change
 -- must not move the header, other columns, row hosts or amount editor.
 near(overlay.width,1110)
 local expected={Stone01={210,3.315},Stone02={210,3.315},
  ['37']={595.52,3.315},['0']={607.76,3.315},
  ['101']={725.28,3.315},['102']={725.28,3.315},
  ['No count yet']={810,3.315},Remove={1002.67,3.315},
  -- Headings at 13pt since round 3 (accessibility P3-4), right-aligned LIMIT
  -- moves left with its width.
  JOB={38,3.535},ITEM={210,3.535},LIMIT={724.6,3.535},
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
-- Per-item Mining rows: the same cell, "Mining (rocks)".
cfg.item_limits_on_rocks=nil
panel.refresh(cfg)
assert(job_cells('Mining (rocks)')==2 and job_cells('Mining')==0, 'per-item rows do not say rocks')
cfg.item_limits_on_rocks=false
panel.refresh(cfg)
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
