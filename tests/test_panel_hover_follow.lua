-- The highlight follows the pointer between draws (perf, 2026-10-29).
--
-- User report: the picker list was "super laggy with the mouse". The tile
-- under the pointer was only worked out inside a full refresh, which runs
-- four or five times a second, so the highlight trailed by up to ~200ms.
-- The fast 16ms loop may not ask a widget anything (no fresh tree there),
-- so it reads the cursor and looks it up in the last draw's map of plain
-- numbers, and asks for one draw when the answer changes.
--
-- The model: a small layout engine over test_panel_render.lua's widgets.
-- Rows stack in their list, widgets sit at their slot positions, the screen
-- is the panel at DPI scale 1.5 in a window at (200, 100), and IsHovered is
-- true for a visible, hit-testable Border under the cursor, as Slate does.
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

local SCALE, OX, OY = 1.5, 200, 100
local told_scale = SCALE -- what the geometry reports; a liar later
local cursor = { X = 0, Y = 0 }
local PART_Y = { Tabs=0, Title=34, Sub=68, Notice=94, Search=116, Caption=156,
    Head=180, ItemList=208, RuleList=208, Foot=640 }
local function origin(w)
    local p = w.parent
    if p == nil then return 0, 0 end
    local px, py = origin(p)
    if p.parent == nil then return 0, PART_Y[w.kind] or 0 end
    if w.kind == 'SizeBox' then
        local y = 0
        for _, c in ipairs(p.children) do
            if c == w then break end
            if c.visibility ~= 1 then y = y + (c.height or 0) end
        end
        return px, py + y
    end
    local at = w.Slot and w.Slot.position
    if at then return px + at.X, py + at.Y end
    return px, py
end
local function shown(w)
    while w do
        if w.dead or w.visibility == 1 or w.visibility == 2 then return false end
        w = w.parent
    end
    return true
end
function Widget:IsHovered()
    if self.kind ~= 'Border' or self.visibility ~= 0 or not shown(self) then return false end
    local size = self.Slot and self.Slot.size
    if not size then return false end
    local x, y = origin(self)
    local lx, ly = (cursor.X - OX) / SCALE, (cursor.Y - OY) / SCALE
    return lx >= x and lx < x + size.X and ly >= y and ly < y + size.Y
end
function Widget:GetCachedGeometry() check(self) return { w = self } end
local native_calls = 0
local slate = {
    LocalToAbsolute = function(_, g, at)
        native_calls = native_calls + 1
        local x, y = origin(g.w)
        return { X = OX + (x + at.X) * told_scale, Y = OY + (y + at.Y) * told_scale }
    end,
    GetLocalSize = function(_, g)
        native_calls = native_calls + 1
        if g.w.unpainted then return { X = 0, Y = 0 } end
        return { X = 600, Y = 40 }
    end,
}
local layout = {
    GetMousePositionOnPlatform = function() native_calls = native_calls + 1 return { X = cursor.X, Y = cursor.Y } end,
}
local cdo = package.loaded.palapi.cdo
package.loaded.palapi.cdo = function(path)
    if path == '/Script/UMG.Default__SlateBlueprintLibrary' then return slate end
    if path == '/Script/UMG.Default__WidgetLayoutLibrary' then return layout end
    return cdo(path)
end

-- Looked up each time: clear_widgets replaces the cache table.
local function surface(key) return up(rb.retint, 'stripes')[key] end
local ROW_HOVER = assert(up(rb.retint, 'ROW_HOVER'))
local function hovered() return up(rb.retint, 'hover_key') end
local function lit(key) local b = surface(key) return b and b.colour == ROW_HOVER end
-- The cursor on the middle of a surface, in screen pixels.
local function point(key)
    local b = assert(surface(key), 'no surface '..key)
    local x, y = origin(b)
    cursor = { X = OX + (x + b.Slot.size.X / 2) * SCALE, Y = OY + (y + b.Slot.size.Y / 2) * SCALE }
end
local function tick() now = now + 0.016; panel.hover_tick(); return panel.fill_tick() end
-- The pointer moved to a surface and left there for three beats, so the
-- draw spacing is not what is being tested. Answers the draws it cost.
local function reach(key)
    if key then point(key) else cursor = { X = OX - 40, Y = OY - 40 } end
    local n = 0
    for _ = 1, 3 do if tick() then n = n + 1 end end
    return n
end
local function draw() panel.refresh(cfg); panel.refresh(cfg) end

rules(3)
panel.refresh(cfg); panel.toggle(); draw()
assert(panel.open)
panel.set_screen('item'); draw()

-- A tile the pointer reaches is lit on the next beat, by one draw.
point('pick0')
assert(tick(), 'the pointer reached a tile and no draw was asked for')
assert(hovered() == 'pick0' and lit('pick0'), 'pick0 not lit: '..tostring(hovered()))
assert(not tick(), 'a second draw for the same tile')
assert(rb.hmap and #rb.hmap >= 27, 'the map does not hold the page')
-- Standing still, or moving inside the tile, costs no draw.
for _ = 1, 30 do cursor.X = cursor.X + 1; assert(not tick(), 'moving inside a tile drew') end
for _ = 1, 30 do assert(not tick(), 'a still pointer drew') end
-- And a draw with the pointer still keeps the map it has: no native calls.
-- The first draw after the pointer moved maps it again; the next one, with
-- the pointer where it was, only reads the cursor.
panel.refresh(cfg); local per_draw = rb.hmap_calls
native_calls = 0; panel.refresh(cfg)
assert(rb.hmap_calls == 0 and native_calls == 1, 'a still pointer rebuilt the map: '..native_calls..' calls')
-- One draw per tile reached, and the old one goes dark.
local draws = 0
for _, key in ipairs({ 'pick1', 'pick2', 'pick5', 'pick4', 'pick7' }) do
    point(key)
    for _ = 1, 4 do if tick() then draws = draws + 1 end end
    assert(hovered() == key and lit(key), key..' not lit: '..tostring(hovered()))
end
assert(draws == 5, 'five tiles cost '..draws..' draws')
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
-- Off every target: one draw puts the highlight out.
assert(reach(nil) == 1 and hovered() == nil, 'highlight stayed off the panel')

-- The Limits tab uses the same path: the limit well and Remove.
panel.set_screen('list'); draw()
assert(reach('capbox1') == 1 and hovered() == 'cap1', 'limit well: '..tostring(hovered()))
assert(reach('delbox2') == 1 and hovered() == 'del2', 'Remove: '..tostring(hovered()))

-- A row Slate has not painted yet has no place on the map, so it costs no
-- draw by mistake; the next draw maps it.
panel.set_screen('item'); draw()
local box = rb.runtime.objects[rb.hosts['ItemList:3'].canvas]
box.unpainted = true; cursor.X = cursor.X + 1; draw()
for _, r in ipairs(rb.hmap) do assert(r[1] ~= 'pick9', 'an unpainted row was mapped') end
box.unpainted = nil

-- No engine object outlives the draw that recorded it.
assert(#rb.hrect == 0, 'the draw kept '..#rb.hrect..' widget rects')
for _, r in ipairs(rb.hmap) do
    for i = 2, 5 do assert(type(r[i]) == 'number') end
    assert(type(r[1]) == 'string')
end

-- A map that disagrees with the widgets (here the geometry reports the
-- wrong scale) is switched off, and hover rides the draw as before.
told_scale = 1.0; cursor.X = cursor.X + 1; draw()
local extra = 0
for i = 1, 60 do
    point('pick'..(i % 27))
    for _ = 1, 3 do if tick() then extra = extra + 1 end end
    if i % 4 == 0 then panel.refresh(cfg) end
end
assert(rb.hover_off, 'a wrong map stayed on')
local after = 0
for i = 1, 30 do point('pick'..(i % 27)); if tick() then after = after + 1 end end
assert(after == 0, 'a map switched off still asked for '..after..' draws')
-- Reopening trusts the map again.
told_scale = SCALE
panel.close(); panel.toggle(); panel.set_screen('item'); draw()
assert(not rb.hover_off and rb.hmap, 'reopening left the map off')
assert(reach('pick8') == 1 and hovered() == 'pick8', 'after reopening: '..tostring(hovered()))

-- A build where the cursor cannot be read: off at once, never retried.
layout.GetMousePositionOnPlatform = function() error('no such function') end
point('pick6'); tick()
assert(rb.hover_off, 'an unreadable cursor kept being polled')

assert(stale == 0)
print(string.format('hover map: %d native calls per picker draw, %d draws for a %d beat sweep, '
    .. '%d extra draws while a wrong map was on', per_draw, swept, beats, extra))
]=], '@panel-hover-follow-fixture'))()
print('PASS panel hover follow: one draw per target reached, none when still, Limits tab, unpainted rows, wrong map off')
