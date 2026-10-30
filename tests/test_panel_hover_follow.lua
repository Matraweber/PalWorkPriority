-- The highlight follows the pointer between draws (perf, 2026-10-29).
--
-- User report: the picker list was "super laggy with the mouse". The tile
-- under the pointer was only worked out inside a full refresh, which runs
-- four or five times a second, so the highlight trailed by up to ~200ms.
-- The fast 16ms loop may not ask a widget anything (no fresh tree there),
-- so it reads the cursor and looks it up in the last draw's map of plain
-- numbers, and asks for one draw when the answer changes.
--
-- The first map read row geometry from the engine. Through UE4SS that is an
-- empty struct copy, so in game the map was never built while this test,
-- with geometry it made up, passed. Now GetCachedGeometry answers an empty
-- table here too, and the screen is decided by a small Slate model of the
-- real shell (unreal/PalWidgetGen, BuildWorkRulesWidgetCommandlet.cpp) that
-- reads only the widget tree: Root, a centred Backdrop at its slot size,
-- Body padded 18, the row SizeBoxes at their height overrides, the two
-- ScrollBoxes stacking their children, Foot 76; collapsed widgets take no
-- space. IsHovered is true for a visible, hit-testable Border under the
-- cursor, as Slate does. The viewport is ultrawide (3440x1440 at scale
-- 4/3, so 2580x1080 in viewport units) to prove the centring.
local f=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=f:read('*a'); f:close()
local start=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
assert(load(source:sub(1,start-1)..'\n'..[=[
local now=100
os.clock=function() return now end
for _,meta in pairs(scheduler.last_storage_by_camp) do meta.sampled_at=now end
local function up(fn,name)
    for i=1,200 do
        local n,v=debug.getupvalue(fn,i)
        if n==nil then break end
        if n==name then return v end
    end
end
local rb=assert(up(panel.refresh,'RB'))
rb.SLICE=math.huge
-- The notes that say why a map is or is not there: debug, and INFO only
-- for the map switching itself off (performance round 4, P3-4).
local notes, info_notes={}, {}
package.loaded.log.info=function(m) notes[#notes+1]=m; info_notes[#info_notes+1]=m end
package.loaded.log.debug=function(m) notes[#notes+1]=m end
local function noted(pat)
    for _,m in ipairs(notes) do if m:find(pat) then return m end end
end
local cat={}
for i=0,59 do cat[#cat+1]='Stone'..string.char(65+i//26)..string.char(65+i%26) end
local items=package.loaded.items
items.catalogue_ids=function() return cat, 'ready' end
items.prepare_picker=function() return {}, 'ready' end
items.search_picker=function() return {} end

-- The shell's tree, as the commandlet builds it.
local HEAD = { {'Tabs',34}, {'Title',34}, {'Sub',26}, {'Notice',22}, {'Search',40},
    {'Caption',24}, {'Head',28} }
local function shape()
    local P = overlay.parts
    P.Root:AddChild(P.Backdrop)
    P.Backdrop:AddChild(P.Body)
    for _, row in ipairs(HEAD) do
        P[row[1]..'Row'].height = row[2]
        P.Body:AddChild(P[row[1]..'Row']); P[row[1]..'Row']:AddChild(P[row[1]])
    end
    P.Body:AddChild(P.RuleList); P.Body:AddChild(P.ItemList)
    P.FootRow.height = 76
    P.Body:AddChild(P.FootRow); P.FootRow:AddChild(P.Foot)
    P.Backdrop.Slot.size = { X = 1086, Y = 700 }
end
local show = overlay.show
overlay.show = function(...)
    local fresh = overlay.parts.Root == nil or overlay.parts.Root.dead
    local ok = show(...)
    if fresh then shape() end
    return ok
end
local fitted
function overlay.fit_width()
    -- 716, not 700, since the 42 px tile pitch (accessibility round 4,
    -- P2-3): at 700 the viewport centre fell in the gap between two tiles,
    -- and the parked-pointer case below needs a tile there.
    local h = math.max(220, math.min(716, math.floor(overlay.height or 716)))
    overlay.parts.Backdrop.Slot.size = { X = overlay.width + 36, Y = h }
    fitted = { overlay.width + 36, h }
end
function overlay.backdrop_size() if fitted then return fitted[1], fitted[2] end end

-- Slate, small. Positions in viewport units.
local VW, VH, SCALE = 2580, 1080, 4 / 3
local scrolled = 0 -- a list the wheel has scrolled: the map does not know
-- What the map cannot know (in game, 2026-10-29, the tiles sat a little
-- below the map): extra height in the column headings row, and list rows
-- of another pitch than the panel asked for.
local head_extra, row_extra = 0, 0
local function collapsed(w) return w.visibility == 1 end
local layout
local function height(w)
    if collapsed(w) then return 0 end
    local P = overlay.parts
    if w == P.ItemList or w == P.RuleList then
        local h = (w.Slot and w.Slot.padding and w.Slot.padding.Top) or 0
        for _, c in ipairs(w.children) do h = h + height(c) end
        return h
    end
    local extra = 0
    if w == P.HeadRow then extra = head_extra end
    if w.kind == 'SizeBox' and (w.parent == P.ItemList or w.parent == P.RuleList) then extra = row_extra end
    return (w.height or 0) + extra
end
function layout(w)
    local P, p = overlay.parts, w.parent
    if p == nil then return 0, 0 end
    if w == P.Backdrop then
        local s, at = w.Slot.size, w.Slot.position or { X = 0, Y = 0 }
        return VW / 2 + at.X - s.X / 2, VH / 2 + at.Y - s.Y / 2
    end
    local x, y = layout(p)
    if w == P.Body then return x + 18, y + 18 end
    if p == P.Body or p == P.ItemList or p == P.RuleList then
        if p ~= P.Body then
            y = y + ((p.Slot and p.Slot.padding and p.Slot.padding.Top) or 0)
            if p == P.ItemList then y = y - scrolled end
        end
        for _, c in ipairs(p.children) do
            if c == w then break end
            y = y + height(c)
        end
        return x, y
    end
    local at = w.Slot and w.Slot.position
    if at and p.kind ~= 'SizeBox' and not tostring(p.kind):match('Row$') then return x + at.X, y + at.Y end
    return x, y
end
local function shown(w)
    while w do
        if w.dead or w.visibility == 1 or w.visibility == 2 then return false end
        w = w.parent
    end
    return true
end
local cursor = { X = 0, Y = 0 }
-- The pointer the engine reports is parked at the viewport's centre and no
-- widget is hovered, as in game for the first seconds after opening.
local parked = false
-- Where Slate still thinks the pointer is, one draw behind (nil: caught up).
local slate = nil
function Widget:IsHovered()
    if parked then return false end
    local cursor = slate or cursor
    if self.kind ~= 'Border' or self.visibility ~= 0 or not shown(self) then return false end
    if self.parent == overlay.parts.Root then return false end
    local size = self.Slot and self.Slot.size
    if not size then return false end
    local x, y = layout(self)
    return cursor.X >= x and cursor.X < x + size.X and cursor.Y >= y and cursor.Y < y + size.Y
end
-- What UE4SS hands back for FGeometry: a struct copy with nothing in it.
function Widget:GetCachedGeometry() check(self) return {} end

local native_calls = 0
local PC = { pc = true }
local controller = PC
package.loaded.palapi.local_player_controller = function() return controller end
local layout_lib = {
    GetMousePositionOnViewport = function(_, pc)
        assert(pc == PC, 'cursor read without the local controller')
        native_calls = native_calls + 1
        return { X = cursor.X, Y = cursor.Y }
    end,
    GetViewportSize = function(_, pc) assert(pc == PC); native_calls = native_calls + 1
        return { X = VW * SCALE, Y = VH * SCALE } end,
    GetViewportScale = function(_, pc) assert(pc == PC); native_calls = native_calls + 1 return SCALE end,
}
local cdo = package.loaded.palapi.cdo
package.loaded.palapi.cdo = function(path)
    if path == '/Script/UMG.Default__WidgetLayoutLibrary' then return layout_lib end
    return cdo(path)
end

local function surface(key) return up(rb.clear_widgets, 'stripes')[key] end
local ROW_HOVER = assert(rb.TOKENS.ROW_HOVER)
local function hovered() return up(rb.current_key, 'hover_key') end
local function lit(key) local b = surface(key) return b and b.colour == ROW_HOVER end
-- The cursor on the middle of a surface, from the Slate model.
-- fy: how far down the surface, 0.5 by default.
local function point(key, fy)
    local b = assert(surface(key), 'no surface '..key)
    local x, y = layout(b)
    cursor = { X = x + b.Slot.size.X / 2, Y = y + b.Slot.size.Y * (fy or 0.5) }
end
local function tick() now = now + 0.016; panel.hover_tick(); return panel.fill_tick() end
-- The pointer moved to a surface and left there for three beats, so the
-- draw spacing is not what is being tested. Answers the draws it cost.
local function reach(key, fy)
    if key then point(key, fy) else cursor = { X = 5, Y = 5 } end
    local n = 0
    for _ = 1, 3 do if tick() then n = n + 1 end end
    return n
end
local function draw() panel.refresh(cfg); panel.refresh(cfg) end

rules(3)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open and overlay.parts.Body.parent == overlay.parts.Backdrop, 'fixture: no shell tree')
panel.set_screen('item'); draw()
-- The model and the panel agree on where row 0 is before any test of it.
point('pick0')
local bx, by = layout(overlay.parts.Backdrop)
assert(cursor.Y > by + 18 and cursor.X > bx + 18, 'fixture: tile outside the backdrop')

-- A tile the pointer reaches is lit on the next beat, by one draw.
assert(tick(), 'the pointer reached a tile and no draw was asked for')
assert(hovered() == 'pick0' and lit('pick0'), 'pick0 not lit: '..tostring(hovered()))
assert(not tick(), 'a second draw for the same tile')
assert(rb.hmap and #rb.hmap >= 27, 'the map does not hold the page')
local built=assert(noted('^panel: hover map built: '), 'no note for a built map')
assert(built:find('viewport 2580x1080',1,true) and built:find('first ',1,true), built)
-- Standing still, or moving inside the tile, costs no draw.
for _ = 1, 30 do cursor.X = cursor.X + 1; assert(not tick(), 'moving inside a tile drew') end
for _ = 1, 30 do assert(not tick(), 'a still pointer drew') end
-- The first draw after the pointer moved maps it again; the next one, with
-- the pointer where it was, only reads the cursor.
native_calls = 0; panel.refresh(cfg); local per_map = native_calls
native_calls = 0; panel.refresh(cfg)
assert(rb.hmap_calls == 0 and native_calls == 1, 'a still pointer rebuilt the map: '..native_calls..' calls')
-- One draw per tile reached, and the old one goes dark.
local draws = 0
for _, key in ipairs({ 'pick1', 'pick2', 'pick5', 'pick4', 'pick7', 'pick26' }) do
    draws = draws + reach(key)
    assert(hovered() == key and lit(key), key..' not lit: '..tostring(hovered()))
end
assert(draws == 6, 'six tiles cost '..draws..' draws')
assert(not lit('pick0') and not lit('pick4'), 'an old tile stayed lit')
-- A pointer crossing a new tile on every beat: at most one draw per
-- HOVER_GAP, and the last tile reached is the one lit.
local swept, beats = 0, 0
for i = 0, 26 do point('pick'..i); beats = beats + 1; if tick() then swept = swept + 1 end end
for _ = 1, 3 do if tick() then swept = swept + 1 end end
assert(swept <= math.ceil(beats * 0.016 / rb.HOVER_GAP) + 1, swept..' draws for '..beats..' beats')
assert(hovered() == 'pick26' and lit('pick26'), 'the sweep ended on '..tostring(hovered()))
-- The pager and the footer bars are targets too.
assert(reach('nextbox') == 1 and hovered() == 'next', 'Next: '..tostring(hovered()))
assert(reach('all') == 1 and hovered() == 'all', 'Show all: '..tostring(hovered()))
assert(reach('back') == 1 and hovered() == 'back', 'Back: '..tostring(hovered()))
-- Off every target: one draw puts the highlight out.
assert(reach(nil) == 1 and hovered() == nil, 'highlight stayed off the panel')
assert(rb.hover_bad == 0 and not rb.hover_off, 'the map disagreed with the widgets')

-- An instant jump from pick0 to pick1 with Slate's hover one draw behind:
-- the draw right after the jump still names pick0. Nothing is learned from
-- it or counted, and the next draw agrees.
assert(reach('pick0') == 1 and hovered() == 'pick0')
local function same_cal() local c = rb.hover_cal.item return c == nil or (c.dx == 0 and c.dy == 0) end
assert(same_cal(), 'fixture: an offset before the jump')
slate = { X = cursor.X, Y = cursor.Y }
point('pick1')
assert(tick() and hovered() == 'pick0', 'fixture: the lagging draw did not name pick0')
assert(same_cal() and rb.hover_resets == 0 and rb.hover_bad == 0,
    'learned from a lagging draw: '..tostring(rb.hover_cal.item and rb.hover_cal.item.dx))
slate = nil
local looked = 0
for _ = 1, 4 do if tick() then looked = looked + 1 end end
assert(looked >= 1 and hovered() == 'pick1', 'the next draw did not agree: '..tostring(hovered()))
panel.refresh(cfg); panel.refresh(cfg)
assert(same_cal() and rb.hover_resets == 0 and rb.hover_bad == 0 and not rb.hover_off,
    'the jump left an offset or a count behind')

-- Show all: a longer list, the same grid.
assert(panel.apply(cfg, { kind = 'toggle_all' }, -1, true)); draw()
assert(reach('pick13') == 1 and hovered() == 'pick13', 'Show all tile: '..tostring(hovered()))

-- The Limits tab uses the same path, on a shorter backdrop.
panel.set_screen('list'); draw()
assert(reach('capbox1') == 1 and hovered() == 'cap1', 'limit well: '..tostring(hovered()))
assert(reach('delbox2') == 1 and hovered() == 'del2', 'Remove: '..tostring(hovered()))
assert(reach('tabhit:tab_new') == 1 and hovered() == 'tab_new', 'a tab: '..tostring(hovered()))
assert(rb.hover_bad == 0 and not rb.hover_off, 'the map disagreed on the Limits tab')

-- No engine object outlives the draw that recorded it.
assert(#rb.hrect == 0, 'the draw kept '..#rb.hrect..' widget rects')
for _, r in ipairs(rb.hmap) do
    for i = 2, 5 do assert(type(r[i]) == 'number') end
    assert(type(r[1]) == 'string')
end

-- The in-game case: everything under the headings sits lower than the map
-- says. The first draw that disagrees teaches the offset, and the map then
-- agrees, standing still and moving.
head_extra = 14
panel.close(); panel.toggle(); panel.set_screen('item'); draw()
-- Low in pick7, where the unlearned map already has pick10, as in game.
point('pick7', 0.9)
assert(rb.hover_lookup(cursor.X, cursor.Y) == 'pick10', 'fixture: not the in-game shape')
for _ = 1, 3 do tick() end
assert(hovered() == 'pick7', 'pick7: '..tostring(hovered()))
for _ = 1, 20 do panel.refresh(cfg) end
assert(not rb.hover_off, 'a constant offset turned the map off: '..tostring(rb.hover_off_why))
local cal = assert(rb.hover_cal.item, 'no offset learned')
assert(cal.dx == 0 and cal.dy > 0 and cal.dy <= 38, 'offset '..cal.dx..','..cal.dy)
assert(noted('^panel: hover map offset on item: '), 'the offset was not said')
local learned = 0
for i, key in ipairs({ 'pick10', 'pick0', 'pick25', 'pick13', 'all', 'back' }) do
    learned = learned + reach(key, i % 2 == 0 and 0.95 or 0.05)
    assert(hovered() == key, key..' after learning: '..tostring(hovered()))
end
assert(learned == 6 and rb.hover_bad == 0, learned..' draws for six targets after learning')
-- A wheel-scrolled list is an offset of the same kind.
scrolled = 25
for _, key in ipairs({ 'pick4', 'pick19', 'pick8' }) do reach(key, 0.9); assert(hovered() == key) end
assert(not rb.hover_off, 'a scrolled list turned the map off')
head_extra, scrolled = 0, 0

-- A map that is not one offset away (rows of another pitch) contradicts
-- itself, is switched off, and hover rides the draw.
panel.close(); panel.toggle(); panel.set_screen('item'); draw()
row_extra = 6
local extra = 0
-- Rows far apart, so the offsets they imply cannot be one; a maintenance
-- draw after each move gives the steady sample that is judged.
for i = 1, 60 do
    point('pick'..(i % 2 == 0 and (i % 3) or (24 + i % 3)), i % 2 == 0 and 0.05 or 0.95)
    for _ = 1, 3 do if tick() then extra = extra + 1 end end
    panel.refresh(cfg)
end
assert(rb.hover_off, 'a wrong map stayed on')
local after = 0
for i = 1, 30 do point('pick'..(i % 27)); if tick() then after = after + 1 end end
assert(after == 0, 'a map switched off still asked for '..after..' draws')
assert(noted('^panel: hover map off: disagreed with the widgets %(map said '), 'no measurable off note')
assert(noted('cursor [%d.]+,[%d.]+, offset '), 'the off note has no cursor or offset')
-- Reopening trusts the map again.
row_extra = 0
panel.close(); panel.toggle(); panel.set_screen('item'); draw()
assert(not rb.hover_off and rb.hmap, 'reopening left the map off')
assert(reach('pick8') == 1 and hovered() == 'pick8', 'after reopening: '..tostring(hovered()))

-- Parked at the centre over a tile while the widgets say nothing: no draw
-- asked for, nothing counted or learned, and a real move then works.
panel.close(); panel.toggle(); panel.set_screen('item')
parked = true; cursor = { X = VW / 2, Y = VH / 2 }
draw()
assert(rb.hover_lookup(cursor.X, cursor.Y) ~= nil, 'fixture: the centre is over no target')
local asked = 0
for _ = 1, 20 do
    if tick() then asked = asked + 1 end
    panel.refresh(cfg)
end
assert(not rb.hover_off, 'a parked pointer turned the map off: '..tostring(rb.hover_off_why))
assert(asked == 0 and rb.hover_bad == 0, asked..' draws asked for by a parked pointer')
assert(rb.hover_cal.item == nil, 'an offset was learned from a parked pointer')
parked = false
assert(reach('pick5') == 1 and hovered() == 'pick5', 'after parking: '..tostring(hovered()))
-- Silence over a target is never held against the map either.
parked = true; point('pick11')
for _ = 1, 20 do tick(); panel.refresh(cfg) end
assert(not rb.hover_off and rb.hover_bad == 0, 'widget silence counted against the map')
parked = false

-- No local controller: off at once, never retried.
controller = nil
point('pick6'); tick()
assert(rb.hover_off, 'hover follow ran without a controller')
assert(noted('^panel: hover map off: cursor unreadable'), 'no note for the missing controller')
controller = PC
panel.close(); panel.toggle(); panel.set_screen('item'); draw()
-- A build where the cursor cannot be read: off at once, never retried.
layout_lib.GetMousePositionOnViewport = function() error('no such function') end
point('pick6'); tick()
assert(rb.hover_off, 'an unreadable cursor kept being polled')

assert(stale == 0)
print(string.format('hover map: %d native calls per map, %d draws for a %d beat sweep, '
    .. '%d extra draws while a wrong map was on', per_map, swept, beats, extra))
]=], '@panel-hover-follow-fixture'))()
print('PASS panel hover follow: map from layout numbers, one draw per target, none when still, Show all, Limits tab, wrong map off')
