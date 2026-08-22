-- The work rules panel.
--
-- A rule is "work this job until the base holds N of an item, then move on".
-- No rule means unlimited, which is what every work type starts as.
--
-- This is a separate surface from the grid on the Monitoring Stand. The grid
-- answers "who does what first", the panel answers "how much is enough", and
-- the two need different shapes: a rule names an item, and there is nowhere
-- in a per-pal-per-work grid for an item to live.
--
-- Styled after the Creative Menu mod: a dark slab, one row per entry, a cyan
-- accent on whatever the mouse is over. That mod ships as a pak of
-- blueprints, so none of its widgets can be reused, only the look.
--
-- Widgets are constructed against the WidgetTree, never against the canvas
-- they are parented into. A UMG widget belongs to a tree; giving one a canvas
-- as its outer leaves it owned by something that does not keep widgets alive,
-- and the renderer then walks a freed object and takes the game with it.

local log = require("log")
local api = require("palapi")
local caps = require("caps")
local items = require("items")
local workdefs = require("workdefs")
local icons = require("icons")
local overlay = require("overlay")
local trace = require("trace")
local scheduler = require("scheduler")

local M = {}

M.open = false
M.wants_pass = false

-- "list"  the rules themselves
-- "item"  choosing what a new rule is about
local mode = "list"
local page = 0
local show_all = false          -- the picker starts on what the base holds

local root = nil                -- the canvas we hang off
local root_owner = nil          -- the layout it belongs to, to spot a swap
local root_tree = nil           -- that layout's WidgetTree, our outer
local backdrop = nil
local blocks = {}               -- key -> TextBlock
local drawn = {}                -- key -> last token drawn
local hits = {}                 -- key -> what clicking it means
local order = {}                -- the same keys in draw order, for the arrows
local used = {}                 -- keys touched this frame, so the rest blank
local hover_key = nil

-- Last frame's answers. A row is registered as clickable AFTER it is drawn,
-- so asking about this frame during the draw always returns nothing. One
-- frame of lag on a marker is invisible; reordering every call site and
-- trusting nobody ever adds one in the wrong order is not.
local was_hit = {}
local was_sel = nil

local placed = {}               -- key -> where it was last put, to skip no-op moves
local stripes = {}              -- key -> Border drawn behind a row
local images = {}               -- key -> Image showing an item icon
local item_of = {}              -- key -> which item that Image is for

-- Where the tiles sit inside "order", so up and down can cross a row of them
-- instead of stepping to the neighbour.
local grid_from, grid_count = 0, 0
local search_box = nil          -- EditableTextBox, only possible in a widget we own
-- Typing an exact ceiling.
--
-- The ladder that left and right step through is quick for a nudge and
-- useless for "I want exactly 4200", which was the whole complaint. Left
-- click on the number opens a box over it; right click and the arrow keys
-- keep stepping, so the fast path is not lost to the precise one.
local amount_box = nil
local editing = nil             -- { work, item, row } while a box is open

-- Switched on with "pwp clicks", or here, since this module hot reloads and
-- main.lua does not: turning it on in the file is the only way to get it into
-- a session that started before the command existed.
M.debug_clicks = true
local edit_focus = false        -- focus is taken once, not fought for
local search_text = ""
local want_focus = false
local sel = 1                   -- which row the keyboard is on
local tab_hits = 0              -- how many order entries the tab bar owns

-- A Remove waiting for its second click, and when it started.
local pending_drop = nil
local pending_at = 0
local perf_worst, perf_at = 0, 0
local perf_hover, perf_draw, perf_hits = 0, 0, 0
local perf_stock, perf_blank = 0, 0

local ftext_mode = nil
local warned = {}

-- LINE has to clear the font, which is about 20 tall at 1440p. At 22 the
-- rows drew through each other.
-- Laid out like Creative Menu: a dark slab, a row of tabs, one boxed row per
-- entry, a cyan accent on whatever is current. Those are the parts that make
-- it read as a menu rather than as text over a game.
-- Every slot is anchored to the middle of the screen, so these are offsets
-- from centre rather than from the top left corner. That keeps the panel
-- centred at any resolution without ever asking how big the viewport is,
-- which is a question with an awkward answer in UE4SS.
local CENTRE = { Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } }
local W = 1050
-- Derived, never typed. X was left at -410 when W grew from 820 to 1010, so
-- the panel stopped being centred and its right edge slid under the game's
-- own Base Info panel. A width and a left edge that have to be kept in step
-- by hand will drift apart again the next time either changes.
local X = -(W / 2)

-- Vertical offset, recomputed from the drawn height so the panel sits in the
-- middle of the screen whichever screen it is showing. Fixed before, which
-- was fine for one screen and wrong for the other.
local Y = -300
local LINE = 34
local ROW_H = 30
local PAD = 18
-- Rule row columns.
--
-- These were 18 / 190 / 470 / 690 and two pairs collided on screen: a long
-- work label ran into the item beside it, so "Lumbering" and "Wood" read as
-- "LumberingWood", and the amount text reached the delete column, printing
-- "done" and "remove" on top of each other.
--
-- The font is nearer 20px per character than the 8 the old numbers assumed,
-- measured off a screenshot rather than guessed at again. "done" also gets a
-- column of its own instead of being glued onto the end of the amount string,
-- because a marker whose position depends on how many digits precede it will
-- collide again the moment a base gets richer.
-- Budgeted, not eyeballed. The row is W - PAD*2 wide and every column must
-- fit its widest possible text before the next one starts, at ROW_PT: the
-- work label, an item id trimmed to ITEM_CHARS, "16299 / 15000", "done" and
-- "remove". The previous version put remove at 890, where its text ran past
-- the stripe drawn behind the row.
local ROW_PT     = 17
local ITEM_CHARS = 16
local COL_ITEM = 210
local COL2     = 480      -- what storage holds
local COL_CAP  = 650      -- the limit it stops at
local COL_DONE = 810      -- working or paused
local COL3     = 920
local TAB_H = 34
-- The picker is a grid, and these are what make it one. Eight across is
-- Creative Menu's shape and it is a good one: wide enough that a page is
-- worth paging to, narrow enough that a tile stays big enough to recognise.
-- Ten across rather than eight, because the grid was 664px wide inside a
-- 1014px panel and the 350px to its right was doing nothing.
--
-- A tile is taller than it is wide now: the icon keeps its square and the
-- name goes underneath. Icon-only tiles were unusable. Two of them read "2k"
-- and could not be told apart, two spheres differed only in hue, and the
-- filter searched by a name the grid never showed, so it only worked for
-- somebody who already knew every item id by heart.
local COLS = 10
local TILE = 76          -- width, and the icon's square
local ICON = 48          -- the picture, in the tile's top band
local TILE_H = 112       -- icon, then the count, then two lines of name
local GAP = 8
local GRID_ROWS = 4

local PER_PAGE = COLS * GRID_ROWS

local COLOUR = {
    title  = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    dim    = { R = 0.52, G = 0.57, B = 0.64, A = 1.00 },
    item   = { R = 0.86, G = 0.89, B = 0.95, A = 1.00 },
    met    = { R = 0.35, G = 0.92, B = 0.48, A = 1.00 },
    unmet  = { R = 1.00, G = 0.70, B = 0.24, A = 1.00 },
    action = { R = 0.42, G = 0.80, B = 1.00, A = 1.00 },
    hover  = { R = 0.60, G = 1.00, B = 1.00, A = 1.00 },
    tab_on = { R = 0.55, G = 0.95, B = 1.00, A = 1.00 },
    -- Readable on a pale field rather than on the panel, which is the one
    -- place in here that is not dark.
    hint   = { R = 0.38, G = 0.42, B = 0.48, A = 1.00 },
    -- Column headings, quieter than the data under them.
    faint  = { R = 0.46, G = 0.51, B = 0.58, A = 1.00 },
    -- The limit, so it never reads as the same kind of number as storage.
    limit  = { R = 0.72, G = 0.78, B = 0.88, A = 1.00 },
    -- Amber for stopped, which is a warning colour rather than a success one,
    -- and readable as different from Working without relying on hue alone
    -- since the words differ too.
    atlimit = { R = 0.56, G = 0.85, B = 0.63, A = 1.00 },
    -- Destructive, and only ever used for that.
    danger = { R = 1.00, G = 0.45, B = 0.40, A = 1.00 },
    -- Quieter than the data it sits beside, so it does not compete, but its
    -- own colour rather than the one five harmless things share.
    quiet  = { R = 0.62, G = 0.58, B = 0.60, A = 1.00 },
    working = { R = 0.55, G = 0.62, B = 0.70, A = 1.00 },
}

-- Nearly opaque on purpose. At 0.94 a bright afternoon base read straight
-- through the panel and the text had to compete with grass; a rules window is
-- something to read, not a HUD element to see past. The rows sit a shade
-- lighter than the backdrop so a list reads as rows without needing borders.
local BACKDROP  = { R = 0.035, G = 0.050, B = 0.075, A = 0.985 }
local ROW_BG    = { R = 0.080, G = 0.105, B = 0.140, A = 1.00 }
local ROW_HOVER = { R = 0.130, G = 0.240, B = 0.310, A = 1.00 }
-- Where the keyboard is, quieter than where the mouse is.
local ROW_SEL   = { R = 0.105, G = 0.170, B = 0.230, A = 1.00 }
-- Inset, darker than the row it sits in, which is how every text field in
-- every dark interface says "type here".
local FIELD_WELL = { R = 0.040, G = 0.055, B = 0.075, A = 1.00 }
local TAB_BAR   = { R = 0.020, G = 0.030, B = 0.048, A = 1.00 }
local CLEAR     = { R = 0.00, G = 0.00, B = 0.00, A = 0.00 }

-- Text fields.
--
-- A pale field with dark text, which is the opposite of the rest of the panel
-- and is deliberate. The dark version was tried first and the background took
-- while none of the four foreground colours did, so the field went dark and
-- the text stayed dark with it: a ceiling box that read as empty while a
-- probe showed it holding "8000" the whole time. Whatever governs that text
-- on this build is not reachable from here.
--
-- So the one thing that is reachable, the background, is set to suit the text
-- rather than the other way about. A pale input on a dark panel is a normal
-- enough thing to look at, and it is unambiguously readable, which is what
-- was actually being complained about.
-- Muted, not white.
--
-- At 0.86 this was the highest-contrast, largest-area element on the panel,
-- brighter than the title and every icon: a spotlight aimed at the least
-- important control. It still has to carry the dark text this build will not
-- let us recolour, so it stays light enough to read against, and no lighter.
local FIELD_BG    = { R = 0.66, G = 0.70, B = 0.75, A = 1.00 }
local FIELD_HINT  = { R = 0.38, G = 0.42, B = 0.48, A = 1.00 }


-- Registers a row as clickable and, in the same breath, as reachable by the
-- arrow keys. Two lists that could disagree would be a bug waiting.
local function hit(key, what)
    hits[key] = what
    order[#order + 1] = key
end

local function warn_once(key, message)
    if warned[key] then return end
    warned[key] = true
    log.warn(message)
end

local function alive(o)
    if o == nil then return false end
    local ok, res = pcall(function() return o:IsValid() end)
    return ok and res == true
end

local function class_name(o)
    local n
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function make_ftext(str)
    if ftext_mode == "direct" or ftext_mode == nil then
        local ft
        if pcall(function() ft = FText(str) end) and ft then
            ftext_mode = "direct"
            return ft
        end
    end

    local ft
    local ok = pcall(function()
        local kismet = api.cdo("/Script/Engine.Default__KismetTextLibrary")
        if kismet then ft = kismet:Conv_StringToText(str) end
    end)
    if ok and ft then
        ftext_mode = "kismet"
        return ft
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Attaching to the game's UI
-- ---------------------------------------------------------------------------

-- The panel draws into the overlay, a widget the mod constructs and owns.
--
-- It used to live in the Monitoring Stand's menu, and before that in the HUD.
-- Both belong to the game, which is the root of everything that went wrong:
-- the HUD rebuilt itself and freed our widgets mid-frame, twice, and the stand
-- menu turned out to be hidden rather than destroyed, so closing it orphaned
-- our rows and reopening drew a second set over them.
--
-- Nothing in Palworld holds a reference to the overlay, so nothing can free it
-- or hide it behind our back. It also means the panel is no longer tied to a
-- Monitoring Stand, which was a real loss when it was hosted there.
-- Validated once per frame, not once per widget.
--
-- Every drawing helper began by calling this, and this costs six engine calls:
-- three inside overlay.host and three of its own. A picker frame builds about
-- thirty five widgets, so a single refresh spent over two hundred round trips
-- re-asking whether the same canvas was still there, and measured at 110ms on
-- a loop that runs ten times a second. That is what "the ADD tab is super
-- laggy" actually was.
--
-- The answer cannot change midway through a frame: nothing between the first
-- widget and the last destroys the canvas they are all going onto. So it is
-- asked once and remembered for the frame, and refresh bumps the counter.
local frame_id = 0
local root_checked = -1

local function ensure_root()
    if root_checked == frame_id and root ~= nil then return root end

    local host, host_tree = overlay.host()

    if not alive(host) or not alive(host_tree) then
        root, root_owner, root_tree, backdrop = nil, nil, nil, nil
        blocks, drawn, stripes, placed = {}, {}, {}, {}
        search_box = nil
        root_checked = -1
        return nil
    end

    if root == host and alive(root_tree) then
        root_checked = frame_id
        return root
    end

    -- A different canvas than last time means the overlay was rebuilt, and
    -- everything we made belonged to the old one and went with it. References
    -- are dropped rather than unparented: asking a freed widget anything is
    -- the crash, not the check for it.
    root, root_owner, root_tree = host, host, host_tree
    backdrop = nil
    blocks, drawn, stripes, placed = {}, {}, {}, {}
    search_box = nil
    root_checked = frame_id
    return root
end

-- A dark slab behind the text. Without one the panel is white words floating
-- over grass, which is exactly what the first version looked like.
local function ensure_backdrop(rows)
    if not ensure_root() then return end

    if not alive(backdrop) then
        local cls = api.cdo("/Script/UMG.Border")
        if not cls or not alive(root_tree) then return end

        pcall(function() backdrop = StaticConstructObject(cls, root_tree) end)
        if not alive(backdrop) then return end

        local slot
        local ok = pcall(function() slot = root:AddChildToCanvas(backdrop) end)
        if not ok or not alive(slot) then
            backdrop = nil
            return
        end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        -- Under the text, over the world.
        pcall(function() slot:SetZOrder(8990) end)
        -- Hit test invisible, so the slab cannot swallow a click meant for a
        -- row sitting on top of it.
        pcall(function() backdrop:SetVisibility(3) end)
    end

    -- Both, because the brush colour alone did not do it. A Border with an
    -- alpha of 0.985 still showed grass through itself, so the widget's own
    -- render opacity was multiplying against it. A window to read has to
    -- stop the world behind it.
    pcall(function() backdrop:SetBrushColor(BACKDROP) end)
    pcall(function() backdrop:SetRenderOpacity(1.0) end)

    local slot
    pcall(function() slot = backdrop.Slot end)
    if alive(slot) then
        -- Placed every frame, not once at construction. Y moves when the
        -- panel is recentred, and a backdrop that was positioned only when it
        -- was built stayed where the first screen put it while everything
        -- drawn on it moved away.
        pcall(function() slot:SetPosition({ X = X - PAD, Y = Y - PAD }) end)
        pcall(function()
            slot:SetSize({ X = W + PAD * 2, Y = rows * LINE + PAD * 2 })
        end)
    end
end

-- The box behind a row. Creative Menu draws every entry as a bordered slab
-- that lights up under the pointer, and that alone is most of the difference
-- between a menu and a wall of text.
local function slab(key, px, py, w, h, colour)
    local host = ensure_root()
    if not host then return end

    used["s:" .. key] = true

    local border = stripes[key]
    if not alive(border) then
        local cls = api.cdo("/Script/UMG.Border")
        if not cls or not alive(root_tree) then return end

        pcall(function() border = StaticConstructObject(cls, root_tree) end)
        if not alive(border) then return end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(border) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(8995) end)
        -- Hit test invisible: the row's text is what reports hover, and a
        -- border on top of it would swallow that.
        pcall(function() border:SetVisibility(3) end)
        stripes[key] = border
    end

    local at = px .. ":" .. py .. ":" .. w .. ":" .. h
    if placed["s:" .. key] ~= at then
        local slot
        pcall(function() slot = border.Slot end)
        if alive(slot) then
            pcall(function() slot:SetPosition({ X = X + px, Y = Y + py }) end)
            pcall(function() slot:SetSize({ X = w, Y = h }) end)
            placed["s:" .. key] = at
        end
    end

    -- Three states. The mouse and the keyboard were sharing one highlight, so
    -- there was no way to see where the keyboard was while the mouse was over
    -- something else.
    local want = (key == hover_key and "hot")
        or (key == was_sel and "sel")
        or "cold"

    -- The token written has to be the token compared. It was writing `want`
    -- and comparing `want .. colour`, so every slab failed its own cache check
    -- and repainted on every frame.
    local token = want .. tostring(colour)
    if drawn["s:" .. key] ~= token then
        pcall(function()
            border:SetBrushColor(colour
                or (want == "hot" and ROW_HOVER)
                or (want == "sel" and ROW_SEL)
                or ROW_BG)
        end)
        drawn["s:" .. key] = token
    end
end

-- A full width row, which is what the rules list is made of.
local function stripe(key, row, from, width)
    slab(key, from - 6, row * LINE - 3, width, ROW_H)
end

-- Font size, which is what makes a heading read as a heading.
--
-- Font is a struct property, so it is read out, changed and written back
-- rather than poked in place. If this build will not take it the panel simply
-- stays one size, which is what it looked like before, so there is nothing to
-- lose by trying.
-- Two ways to say it, because writing the struct back was not taking.
--
-- Tile text came out the same size as a heading, which is what gave the grid
-- overlapping names. SetFont is the function the engine offers and is tried
-- first; assigning the property is what this did before and stays as the
-- fallback.
--
-- Reported once per size asked for, with the size before as well as after.
-- The first version logged only the size afterwards, which proved nothing:
-- it asked for 20, read back 20, and could not tell a font it had just
-- changed from one that was 20 all along.
local sized = {}

local function set_size(tb, points)
    local before
    pcall(function() before = tb.Font.Size end)

    pcall(function()
        local font = tb.Font
        if font == nil then return end
        font.Size = points
        tb:SetFont(font)
    end)

    local after
    pcall(function() after = tb.Font.Size end)

    if after ~= points then
        pcall(function()
            local font = tb.Font
            if font == nil then return end
            font.Size = points
            tb.Font = font
        end)
        pcall(function() after = tb.Font.Size end)
    end

    if not sized[points] then
        sized[points] = true
        log.say(string.format("text sizing: asked %s, was %s, now %s",
            tostring(points), tostring(before), tostring(after)))
    end
end

-- passthrough makes the text ignore the pointer, which a tile's label has to
-- do. A row reports hover through its own text, but a tile reports it through
-- its picture, and a label sitting on top of that picture at a higher ZOrder
-- swallows the hover before it gets there. That is why nothing in the picker
-- could be clicked: the tiles were listening, and their own labels were in
-- the way.
local function text_at(key, px, py, text, colour_key, points, passthrough)
    local canvas = ensure_root()
    if not canvas then return end

    used[key] = true

    local tb = blocks[key]
    if not alive(tb) then
        local cls = api.cdo("/Script/UMG.TextBlock")
        if not cls or not alive(root_tree) then return end

        pcall(function() tb = StaticConstructObject(cls, root_tree) end)
        if not alive(tb) then return end

        local slot
        local ok = pcall(function() slot = canvas:AddChildToCanvas(tb) end)
        if not ok or not alive(slot) then return end

        -- Auto sized, because that is what demonstrably renders here.
        -- Sizing the slot explicitly, which is what this did, produced widgets
        -- that were positioned correctly and drew nothing at all, while the
        -- identically constructed text in overlay.lua's probe showed fine. The
        -- only difference between them was this call.
        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetZOrder(9000) end)
        pcall(function() tb:SetVisibility(passthrough and 3 or 0) end)
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
        if points then set_size(tb, points) end

        blocks[key] = tb
        drawn[key] = nil
    end

    -- Position every frame, not only at construction: a row moves when the
    -- screen above it changes length.
    -- Ten times a second, so a move that changes nothing is worth skipping.
    local at = px .. ":" .. py
    if placed[key] ~= at then
        local slot
        pcall(function() slot = tb.Slot end)
        if alive(slot) then
            pcall(function() slot:SetPosition({ X = X + px, Y = Y + py }) end)
            placed[key] = at
        end
    end

    -- Exactly one row is current. The pointer wins when it is over
    -- something, otherwise the keyboard position stands. Treating both as
    -- selected marked two rows at once, which the video shows plainly.
    local current = hover_key or was_sel
    local selected = (key == current)
    local shown = selected and "hover" or colour_key

    -- A marker as well as a colour. Colour alone was not enough to see where
    -- the selection was, least of all on a row that is already blue.
    -- Not on tabs. The underline says which screen you are on; a second
    -- marker on a different tab said something else, and the two contradicted
    -- each other on every screen change.
    if was_hit[key] and not key:match("^tab_") then
        text = (selected and "> " or "  ") .. text
    end

    local token = text .. "|" .. shown
    if drawn[key] ~= token then
        local ft = make_ftext(text)
        if ft then
            pcall(function() tb:SetText(ft) end)
            pcall(function()
                tb:SetColorAndOpacity({
                    SpecifiedColor = COLOUR[shown],
                    ColorUseRule = 0,
                })
            end)
            drawn[key] = token
        end
    end
end

-- Text on one of the list's rows.
-- Text centred in its stripe, not merely placed on the same row.
--
-- stripe() puts its slab's top at row*LINE - 3 and stands ROW_H tall, while
-- this put the text's top at row*LINE. Two different tops, so nothing was
-- centred and the error grew with the font: barely visible on a 17pt rule
-- row, plainly wrong on the 20pt header and on "+ add a rule".
--
-- A text block stands about 1.35 times its point size, so centring is the
-- stripe's middle less half of that. DEFAULT_PT has to match text_at's own
-- default or headings drift again.
local DEFAULT_PT = 20

local function line(key, row, col, text, colour_key, points)
    -- pt is passed on, never the caller's nil. text_at reads nil as "leave
    -- the size alone", so an unsized line kept whatever the recycled widget
    -- last had, usually UMG's 24, while this centred it as though it were 20.
    -- Centring cannot be right while the size is a guess.
    local pt = points or DEFAULT_PT
    -- Centred on the glyphs, not on the block.
    --
    -- A text block reserves room for descenders whether the text has any or
    -- not, so centring the block leaves capitals sitting low: RULES and ADD
    -- and CLOSE have no descender between them and every one of them looked
    -- like it had sunk. The nudge is the difference between the block's
    -- middle and the middle of the capitals, which is about an eighth of the
    -- point size.
    local y = (row * LINE - 3) + (ROW_H - pt * 1.35) / 2 - pt * 0.13
    text_at(key, col, y, text, colour_key, pt)
end

-- ---------------------------------------------------------------------------
-- Tiles
-- ---------------------------------------------------------------------------

-- The icon itself.
--
-- Visible rather than hit test invisible, unlike the slab behind it, because
-- this is the widget that reports whether the pointer is over the tile.
-- Put a texture on an image.
--
-- One call, deliberately. The previous version tried four ways in turn and
-- checked each by reading the brush back, which was worse than useless: the
-- read back is unreliable on this class, so on a run where it failed to
-- confirm a call that had in fact worked, the chain carried on and the last
-- way in it wrote a brush by hand and wrecked it. That is what the white
-- squares were. Not a missing icon, damage done by the code meant to cope
-- with a missing icon.
--
-- Matching the size is the part that matters, and it took getting wrong twice
-- to see why. Without it the brush keeps an image size of nothing, so the
-- Image has nothing to draw even with a perfectly good texture on it, and the
-- tile comes out empty rather than obviously broken.
--
-- The run where icons actually appeared was the one that matched sizes; the
-- log said so plainly and I read it as evidence for the opposite call.
local function apply_texture(img, texture, size)
    -- bMatchSize true, then the size corrected.
    --
    -- Matching is what makes the brush draw at all, per the note in
    -- overlay.lua: a brush with no size reports success and paints nothing.
    -- But matching sets the brush to the texture's own dimensions, and the
    -- art in this pak is not one size, so roughly half the picker's icons
    -- spilled past their tiles onto the panel and read as a rendering fault.
    --
    -- The slot decides the box; the brush is then told to agree with it. The
    -- style struct write is the same shape that worked for the text fields,
    -- read out and assigned rather than built.
    pcall(function() img:SetBrushFromTexture(texture, true) end)

    if size then
        pcall(function()
            local brush = img.Brush
            if brush then brush.ImageSize = { X = size, Y = size } end
        end)
    end
end

-- Run from here rather than from a keybind. UE4SS never sees Ctrl+F7 while
-- the panel holds the input mode, which is exactly when these questions
-- matter, so the diagnostics fire themselves the first time a tile is drawn.
local probed = false

local function picture(key, px, py, size, item_id, token)
    if not probed then
        probed = true
        -- Only the lookup. The image probe reported that UMG.Image has no
        -- brush functions at all, which is plainly false given one of them
        -- works, so it is not worth reading and not worth running.
        -- The load test is answered and stays out of the way. It issued
        -- loads of its own, which is the exact thing now being rationed.
        pcall(function() icons.probe() end)
    end

    local host = ensure_root()
    if not host then return end

    used["i:" .. key] = true

    local img = images[key]
    if not alive(img) then
        local cls = api.cdo("/Script/UMG.Image")
        if not cls or not alive(root_tree) then return end

        pcall(function() img = StaticConstructObject(cls, root_tree) end)
        if not alive(img) then return end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(img) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(8998) end)
        pcall(function() img:SetVisibility(0) end)
        images[key] = img
    end

    local at = px .. ":" .. py .. ":" .. size
    if placed["i:" .. key] ~= at then
        local slot
        pcall(function() slot = img.Slot end)
        if alive(slot) then
            pcall(function() slot:SetPosition({ X = X + px, Y = Y + py }) end)
            pcall(function() slot:SetSize({ X = size, Y = size }) end)
            placed["i:" .. key] = at
        end
    end

    if drawn["i:" .. key] ~= token then
        -- The game's own loader first. It takes the item id and does the
        -- rest: finds the icon, streams it, puts it on the Image. When that
        -- works there is nothing here for the table, the queue or the
        -- rationing to do.
        --
        local texture = item_id and icons.get(item_id) or nil
        if texture then
            apply_texture(img, texture, size)
            pcall(function() img:SetOpacity(1.0) end)
        else
            -- Kept, not hidden. A hidden widget reports no hover, and the
            -- tile still has to be clickable when its picture is missing.
            pcall(function() img:SetOpacity(0.0) end)
        end
        drawn["i:" .. key] = token
    end
end

-- A readable label for an item with no icon.
--
-- The old one took the first nine characters, which is how two tiles both came
-- to read "PalSphere": everything that tells PalSphere from PalSphere_Gold
-- lives past the ninth character. Item ids are CamelCase and sometimes carry
-- an underscore, so they split into words cleanly.
--
-- When it still will not fit, the last line is kept rather than the next one
-- along. What distinguishes these names is nearly always the tail: Gold, Mega,
-- Seed. Dropping the tail to keep the middle would rebuild the bug.
local NAME_COLS = 11
local NAME_LINES = 3

local function name_lines(item)
    local words = {}
    for chunk in tostring(item):gmatch("[^_%s]+") do
        -- BerrySeed becomes Berry Seed. The second pattern keeps runs of
        -- capitals together, so HPMedicine breaks as HP Medicine rather than
        -- into single letters.
        chunk = chunk:gsub("(%l)(%u)", "%1%2"):gsub("(%u)(%u%l)", "%1%2")
        for w in chunk:gmatch("[^]+") do
            while #w > NAME_COLS do
                words[#words + 1] = w:sub(1, NAME_COLS)
                w = w:sub(NAME_COLS + 1)
            end
            if #w > 0 then words[#words + 1] = w end
        end
    end

    local lines = {}
    for _, w in ipairs(words) do
        local last = lines[#lines]
        if last and (#last + 1 + #w) <= NAME_COLS then
            lines[#lines] = last .. " " .. w
        else
            lines[#lines + 1] = w
        end
    end

    if #lines > NAME_LINES then
        local kept = {}
        for n = 1, NAME_LINES - 1 do kept[n] = lines[n] end
        kept[NAME_LINES] = lines[#lines]
        lines = kept
    end

    if #lines == 0 then lines[1] = tostring(item) end
    return lines
end

-- One item: a slab, its icon, how many are in storage, and a name when there
-- is no icon to be had.
local function tile(key, at, item, have, top, limited)
    local col = at % COLS
    local row = math.floor(at / COLS)
    local px = PAD + col * (TILE + GAP)
    local py = top + row * (TILE_H + GAP)

    slab(key, px, py, TILE, TILE_H)

    item_of[key] = item

    -- The icon keeps the top square of the tile; the name sits under it.
    -- The icon gets the top band only. Sized to leave room below rather than
    -- filling the tile, because the count and the name were being drawn over
    -- the bottom of the picture.
    local has_icon = icons.ready(item)
    picture(key, px + 14, py + 4, ICON, item,
        item .. (has_icon and "+" or "-"))

    -- The name, always, not only when the icon is missing.
    --
    -- This is the fix the review was most insistent about: a grid of pictures
    -- with no words cannot be read, cannot be searched, and cannot be learned.
    -- Two tiles showed a brown log and a blue crystal, both labelled 2k, and
    -- nothing on screen could tell you which was which.
    local lines = name_lines(item)
    local first = py + ICON + 20
    for n = 1, math.min(#lines, 2) do
        text_at("n" .. n .. ":" .. key, px + 5, first + (n - 1) * 12,
            lines[n], "item", 10, true)
    end

    -- The count, exact. The picker said 8k where the rules list said 8299, so
    -- the two screens disagreed about the number you were about to set a limit
    -- against, and two different piles both read 2k.
    if have > 0 then
        text_at("q:" .. key, px + 5, py + ICON + 6,
            tostring(math.floor(have)), "title", 11, true)
    end

    -- Already has a rule. Without this the picker offers items that are
    -- already limited, identically to ones that are not, and clicking one
    -- silently resets its limit to the bottom of the ladder.
    if limited then
        text_at("lim:" .. key, px + TILE - 20, py + 4, "•", "atlimit", 16, true)
    end
end


-- Anything not drawn this frame is emptied rather than destroyed. A destroyed
-- widget leaves a dead wrapper behind; an empty one costs nothing. The first
-- version cleared only keys matching one prefix, which is how an item name
-- was left stranded across the rules list.
local function blank_unused()
    for key, tb in pairs(blocks) do
        if not used[key] and drawn[key] ~= "" and alive(tb) then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = ""
            end
        end
    end

    -- A stripe with nothing on it is a floating box, so anything not drawn
    -- this frame goes transparent rather than staying behind.
    --
    -- Recorded in the cache, not merely done. The cache exists to skip
    -- redundant work by remembering what is on screen, so anything that
    -- changes the screen behind its back makes it lie. Clearing without
    -- recording is exactly how rows came back invisible: the stripe was
    -- transparent, the cache still said "off", and the recolour that would
    -- have fixed it was skipped as redundant. Switching tabs reuses these
    -- keys, which is why it took a couple of presses to show up.
    for key, border in pairs(stripes) do
        if not used["s:" .. key] and alive(border)
            and drawn["s:" .. key] ~= "clear" then
            pcall(function() border:SetBrushColor(CLEAR) end)
            drawn["s:" .. key] = "clear"
        end
    end

    for key, img in pairs(images) do
        if not used["i:" .. key] and alive(img)
            and drawn["i:" .. key] ~= "clear" then
            pcall(function() img:SetOpacity(0.0) end)
            drawn["i:" .. key] = "clear"
        end
    end
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- An EditableTextBox the player can actually type into.
--
-- This is the thing that was impossible before. A text box injected into a
-- widget the game owns never receives keystrokes, because focus follows
-- ownership; that is why the picker paged through items instead of filtering
-- them. In a widget we construct ourselves the engine will hand it the
-- keyboard.
-- Make a text field belong to this panel rather than to UMG's defaults.
--
-- An EditableTextBox ships light: a near-white background with grey text on
-- it. Dropped into a dark panel that reads as a blank white bar, and the hint
-- inside it is grey on near-white, which is the "very difficult to read" of
-- it. The rest of the panel is light text on dark, so the field should be too.
--
-- The style struct is read out, changed and written back, never built. This
-- codebase has a scar from hand-building a struct off a header, and the same
-- read-modify-write shape is already used for fonts a few hundred lines up.
--
-- If the write does not take, the fallback makes the text dark instead, which
-- is at least readable on the pale default. Reported once either way, so a
-- session says which of the two it got rather than leaving it to a screenshot.
local styled_boxes = {}

local function style_box(box, which)
    if not alive(box) or styled_boxes[which] then return end
    styled_boxes[which] = true

    -- The struct write lands even when SetStyle refuses.
    --
    -- First attempt read SetStyle throwing as "the style would not take" and
    -- fell back to dark text, which is right for the pale default it assumed
    -- was still there. It was not: assigning the field had already darkened
    -- the background, so the fallback put dark text on a dark field and made
    -- it worse than before. UE4SS hands out the style struct by reference,
    -- so the assignment is the part that works and SetStyle is the optional
    -- half.
    pcall(function()
        local st = box.WidgetStyle
        if st == nil then return end
        st.BackgroundColor = { SpecifiedColor = FIELD_BG, ColorUseRule = 0 }

        -- Only the background. The four foreground colours an
        -- EditableTextBox carries were all set and none of them moved the
        -- text, so they are not pretended at here.
        -- Offered, not required. It refuses on this build and the field is
        -- already dark by the time it does.
        pcall(function() box:SetStyle(st) end)
    end)

    log.say("text field " .. which .. ": pale field, so its own text shows")
end

local function ensure_search(row)
    local host = ensure_root()
    if not host then return nil end

    used["search"] = true

    if not alive(search_box) then
        local cls = api.cdo("/Script/UMG.EditableTextBox")
        if not cls or not alive(root_tree) then return nil end

        pcall(function() search_box = StaticConstructObject(cls, root_tree) end)
        if not alive(search_box) then
            warn_once("nosearch", "no EditableTextBox on this build, " ..
                "so the picker pages instead of filtering")
            return nil
        end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(search_box) end)
        if not ok or not alive(slot) then
            search_box = nil
            return nil
        end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(9010) end)
        pcall(function() search_box:SetVisibility(0) end)
        -- No hint text. SetForegroundColor governs what is typed, not the
        -- hint, which keeps its own colour somewhere in the style struct, so
        -- darkening the field left "Type to filter" dark on dark. Drawn below
        -- as an ordinary TextBlock instead, in a colour this panel already
        -- owns, which is one fewer thing to negotiate with UMG over.
        style_box(search_box, "filter")
    end

    local slot
    pcall(function() slot = search_box.Slot end)
    if alive(slot) then
        pcall(function() slot:SetPosition({ X = X + PAD, Y = Y + row * LINE }) end)
        -- 30 cut the descenders off its own hint text. A field that clips the
        -- word "type" is not a field anybody trusts to hold what they typed.
        -- As wide as the grid it filters. It ran the full panel width while
        -- the tiles stopped well short, so it overhung the thing it acts on.
        pcall(function()
            slot:SetSize({ X = COLS * (TILE + GAP) - GAP, Y = 36 })
        end)
    end
    pcall(function() search_box:SetVisibility(0) end)

    -- Focus is taken once on entering the picker, not every frame: stealing it
    -- each tick would fight anything else that wants it and make typing feel
    -- like it is being interrupted, which it would be.
    -- Focus is taken on request, never on arrival.
    --
    -- Opening the picker used to put the keyboard in this box, which is the
    -- one place arrow keys must not go on a panel driven by arrow keys: they
    -- moved a text caret instead of the selection, and the grid could not be
    -- navigated at all until the box was clicked away from.
    if want_focus then
        want_focus = false
        pcall(function() search_box:SetKeyboardFocus() end)
    end

    local text
    pcall(function()
        local ft = search_box:GetText()
        if ft then text = ft:ToString() end
    end)
    if type(text) == "string" then search_text = text end

    return search_box
end

-- The box that edits a ceiling, drawn over the amount column of its row.
local function ensure_amount_box()
    if editing == nil then return nil end

    local host = ensure_root()
    if not host then return nil end

    used["amount"] = true

    if not alive(amount_box) then
        local cls = api.cdo("/Script/UMG.EditableTextBox")
        if not cls or not alive(root_tree) then return nil end

        pcall(function() amount_box = StaticConstructObject(cls, root_tree) end)
        if not alive(amount_box) then
            warn_once("noamount", "no EditableTextBox on this build, " ..
                "so ceilings step through the ladder instead of being typed")
            editing = nil
            return nil
        end

        local slot
        local ok = pcall(function() slot = host:AddChildToCanvas(amount_box) end)
        if not ok or not alive(slot) then
            amount_box = nil
            editing = nil
            return nil
        end

        pcall(function() slot:SetAnchors(CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        -- Above the rows it covers.
        pcall(function() slot:SetZOrder(9020) end)
    end

    -- Styled here rather than at construction. The first version styled on
    -- creation only, and the ceiling box is built the first time somebody
    -- clicks a number, which is after the log line that says what happened,
    -- so it went out pale while the filter went out dark.
    style_box(amount_box, "ceiling")

    local slot
    pcall(function() slot = amount_box.Slot end)
    if alive(slot) then
        pcall(function()
            slot:SetPosition({ X = X + COL_CAP - 6, Y = Y + editing.row * LINE - 4 })
        end)
        pcall(function() slot:SetSize({ X = 210, Y = 30 }) end)
    end
    pcall(function() amount_box:SetVisibility(0) end)

    if editing.seed then
        local seed = editing.seed
        editing.seed = nil
        pcall(function() amount_box:SetText(make_ftext(seed)) end)
        pcall(function() amount_box:SetHintText(make_ftext("new ceiling")) end)
    end

    if edit_focus then
        edit_focus = false
        pcall(function() amount_box:SetKeyboardFocus() end)
    end

    return amount_box
end

-- Reads what was typed and stores it. Called every refresh while a box is
-- open, the same way the picker's filter is read: polling costs one call and
-- needs no delegate, and delegates taking a Lua function is exactly what this
-- build refuses elsewhere.
local function poll_amount(cfg)
    if editing == nil or not alive(amount_box) then return end

    local text
    pcall(function()
        local ft = amount_box:GetText()
        if ft then text = ft:ToString() end
    end)
    if type(text) ~= "string" then return end

    -- Committed when the box stops holding the keyboard, which covers both
    -- pressing enter and clicking away, without binding either.
    local focused = true
    pcall(function() focused = amount_box:HasKeyboardFocus() end)
    if focused then return end

    local want = tonumber((text:gsub("[^%d]", "")))
    local job, item = editing.work, editing.item
    editing = nil
    pcall(function() amount_box:SetVisibility(1) end)

    if want == nil then
        log.say("no number typed, ceiling left alone")
        return
    end
    if want <= 0 then
        caps.clear(job, item)
        log.say("rule removed: " .. workdefs.label(job) .. " " .. item)
    else
        caps.set(job, item, want)
        log.say(string.format("%s %s ceiling set to %d",
            workdefs.label(job), item, want))
    end
    M.wants_pass = true
end

local function begin_edit(rule, row)
    -- The starting value travels with the request rather than being written
    -- here. On the first edit of a session the box does not exist yet, so the
    -- SetText that used to sit here went nowhere and the field opened empty
    -- over the top of the old number, which read as a broken overlay rather
    -- than something to type in.
    editing = {
        work = rule.work,
        item = rule.item,
        row = row,
        seed = tostring(rule.amount or ""),
    }
    edit_focus = true
end

local function hide_search()
    if alive(search_box) then
        -- Collapsed rather than destroyed, so the same box comes back with
        -- whatever was typed in it.
        pcall(function() search_box:SetVisibility(1) end)
    end
end

-- ---------------------------------------------------------------------------
-- Stock
-- ---------------------------------------------------------------------------

-- What the bases hold, taken from the last scheduler pass.
--
-- The panel used to work this out itself, scanning every container on every
-- loaded camp. That is the most expensive thing this mod does and it was
-- happening every three seconds on the game thread for as long as the panel
-- was open, which is what made it lag.
--
-- The pass already computes these numbers every ten seconds. Reading them
-- costs nothing, and being up to ten seconds stale is invisible for a stock
-- count that moves by a handful at a time.
--
-- The scan below is a fallback for the first seconds after a world loads,
-- before any pass has published, and it is throttled hard.
local scanned_once = nil
local scanned_at = 0

local function stock_totals(cfg)
    if next(scheduler.last_totals or {}) ~= nil then
        return scheduler.last_totals
    end

    local now = os.clock()
    if scanned_once and (now - scanned_at) < 15.0 then
        return scanned_once
    end

    local opts = {
        include = cfg.counted_containers,
        exclude = cfg.uncounted_containers,
    }

    local totals
    if cfg.storage_scope == "global" then
        totals = (api.all_chest_totals(opts))
    else
        totals = {}
        for _, camp in ipairs(api.base_camps()) do
            local camp_id = api.camp_id(camp)
            if camp_id then
                local part = api.camp_item_totals(api.guid_key(camp_id), opts)
                for id, n in pairs(part or {}) do
                    totals[id] = (totals[id] or 0) + n
                end
            end
        end
    end

    scanned_once, scanned_at = totals, now
    return totals
end

-- ---------------------------------------------------------------------------
-- Screens
-- ---------------------------------------------------------------------------

-- A tab bar, the first thing Creative Menu shows and the clearest way to say
-- what screen you are on and what else there is.
local function draw_tabs(active)
    -- Flush with the backdrop, which sits at X - PAD and is W + PAD*2 wide.
    -- Three different insets were in play here: the backdrop bled to the
    -- panel edge, this bar stopped one pad short of it, and the row stripes
    -- stopped another pad short of that, so nothing lined up with anything.
    -- A header bar reads as a title bar when it runs the full width and as a
    -- mistake when it runs almost the full width.
    -- Placed with slab, not stripe. stripe() subtracts 6 from its x for the
    -- row insets, which put the header band six pixels left of the panel it
    -- sits in, so a strip of chrome hung over the edge onto the 3D world.
    -- Measured off a screenshot: band at 431, panel at 437.
    slab("tabbar", -PAD, -3, W + PAD * 2, ROW_H)

    local tabs = {
        { key = "tab_rules", label = "RULES", mode = "list" },
        { key = "tab_new",   label = "ADD",   mode = "item" },
    }

    local x = PAD
    for _, tab in ipairs(tabs) do
        local on = (active == tab.mode)
        hit(tab.key, { kind = "tab", mode = tab.mode })

        -- The active tab is filled, not merely tinted. Two words in slightly
        -- different colours is not a tab bar: which screen you are on should
        -- be readable at a glance and from the corner of the eye, which is
        -- what Creative Menu gets right and this did not.
        -- An underline inside the bar, not a slab over it. The filled box
        -- stood taller than the header it sat in and read as a stray
        -- rectangle rather than a selected tab. A rule under the active word
        -- is the quieter convention and cannot overhang anything.
        -- Drawn in the accent colour. The first attempt used slab's default,
        -- which is the row background: a dark rule on a dark bar, invisible.
        -- Sized and placed from the word itself. Capitals at 20pt run about
        -- 0.62 of the point size each, so the rule is as wide as the label
        -- and starts where the label starts, rather than the constant plus
        -- fudge that left it hanging off to one side.
        -- Measured off a screenshot rather than assumed: RULES rendered 83
        -- pixels across for five capitals at 20pt, so a capital is about 0.83
        -- of the point size, not the 0.62 an em-width guess gives. The rule
        -- was coming out a fifth short and left aligned under the word, which
        -- is what read as off centre.
        if on then
            local w = #tab.label * 20 * 0.83
            slab("tabsel:" .. tab.key, x, TAB_H - 6, w, 3, COLOUR.tab_on)
        end

        line(tab.key, 0, x, tab.label, on and "tab_on" or "dim", 20)
        x = x + 130
    end

    hit("tab_close", { kind = "close" })
    line("tab_close", 0, W - 90, "CLOSE", "dim", 20)

    -- What this is and what it does, which the panel never said. Opening it
    -- cold gave you two tabs, a caption about clicking things, and numbers
    -- with no stated meaning.
    -- Not "Pal Work Priority". Palworld already has work suitability and
    -- priority, which is about which job a Pal picks; nothing on this screen
    -- ranks anything. The mod keeps its name, the screen says what it does.
    line("title", 1, PAD, "Production Limits", "title", 22)
    line("why", 2, PAD,
        "Your Pals stop a job once base storage reaches the limit you set.",
        "dim", 14)

    -- Counted rather than assumed. The keyboard cursor starts at order[1],
    -- which is whatever the tab bar registered first, so switching screens
    -- left the marker sitting on RULES while the ADD screen was showing. The
    -- two disagreed about where you were.
    tab_hits = #order
end

local function rule_list(cfg)
    local out = {}
    for work, by_item in pairs(caps.all(cfg)) do
        for item, amount in pairs(by_item) do
            out[#out + 1] = { work = work, item = item, amount = amount }
        end
    end
    table.sort(out, function(a, b)
        if a.work ~= b.work then return a.work < b.work end
        return a.item < b.item
    end)
    return out
end

-- Six figures in a column sized for four is how "done" ended up printed on
-- top of the amount: the text grows rightwards with the stock and eventually
-- reaches whatever sits beside it. Anything past five digits loses the units,
-- which nobody reads on a ceiling of fifteen thousand anyway, and the string
-- can then never outgrow its column.
-- An id like AncientCivilizationParts is twenty four characters and would
-- cross two columns. Trimmed so the row keeps its shape; the picker shows
-- the full name, and this list is read by its job and its number rather
-- than by matching an id letter for letter.
local function short_item(id)
    id = tostring(id or "")
    if #id <= ITEM_CHARS then return id end
    return id:sub(1, ITEM_CHARS - 2) .. ".."
end

local function short_amount(n)
    n = tonumber(n) or 0
    if n >= 100000 then
        return string.format("%.0fk", n / 1000)
    end
    return tostring(math.floor(n))
end

local function draw_list(cfg, totals)
    local rules = rule_list(cfg)

    draw_tabs("list")
    local row = 3

    -- The instruction line doubles as the editor's label. A text field that
    -- appears over a number with no caption leaves you guessing which of the
    -- two numbers it replaces, and "click a job to change it" is not the
    -- sentence you need while typing.
    if editing ~= nil then
        line("sub", row, PAD,
            "Setting the " .. workdefs.label(editing.work) .. " ceiling for " ..
            editing.item .. "  |  Type a number, then click anywhere to save",
            "action", 13)
    else
        -- Nothing here any more. The limit sits in a well, the job is the
        -- only coloured word in its row, and Remove asks before it acts, so
        -- the three things this line used to explain now explain themselves.
        -- The panel is a line shorter and says more.
        line("sub", row, PAD, "", "dim", 13)
    end
    row = row + 1

    -- Names both numbers. Without this the pair reads as progress towards a
    -- goal, which is the opposite of what it means.
    if #rules > 0 then
        -- The two leading spaces match the marker slot every hit row
        -- carries, so JOB sits over Lumbering instead of thirteen pixels
        -- left of it.
        line("h_job",  row, PAD,      "  JOB",      "faint", 12)
        line("h_item", row, COL_ITEM, "ITEM",       "faint", 12)
        line("h_have", row, COL2,     "IN STORAGE", "faint", 12)
        line("h_cap",  row, COL_CAP,  "LIMIT",      "faint", 12)
        line("h_st",   row, COL_DONE, "STATUS",     "faint", 12)
        row = row + 1
    end

    if #rules == 0 then
        line("empty", row, PAD, "No rules yet. Every job runs unlimited", "dim")
        row = row + 2
    else
        for i, rule in ipairs(rules) do
            local have = totals[rule.item] or 0
            local met = have >= rule.amount
            local key = "rule" .. i

            stripe(key, row, PAD, W - PAD * 2)
            line(key, row, PAD, workdefs.label(rule.work), "action", ROW_PT)
            line("itm" .. i, row, COL_ITEM, short_item(rule.item), "item", ROW_PT)
            -- Blank while its box is open. The box does not fully cover the
            -- text beneath it, so both were drawing at once and the reading
            -- was "8155 | 8000" over "8155 / 8000": a field that looks like
            -- it already contains nonsense before anything is typed.
            local editing_this = editing ~= nil
                and editing.work == rule.work and editing.item == rule.item

            -- Two named columns, not "8212 / 8000".
            --
            -- That pair, in green, beside the word Done, is exactly how a
            -- game writes quest progress, so it read as "8212 of 8000
            -- gathered, complete" when it means "you are 212 over the limit
            -- and Lumbering has stopped". The panel was teaching the opposite
            -- of what it does. Storage is neutral, the limit is its own
            -- column under its own heading, and the status says which of the
            -- two states you are in rather than congratulating you.
            -- Storage is telemetry, the limit is the thing being set, so the
            -- limit is the brighter of the two. It was the other way round,
            -- which put the one number the panel exists to change second in
            -- the reading order.
            line("amt" .. i, row, COL2,
                short_amount(have), "limit", ROW_PT)

            -- A well behind the number, so it looks like something you can
            -- type into.
            --
            -- The limit was styled as plain text, indistinguishable from the
            -- storage figure beside it that cannot be changed, which is why
            -- the panel needed a line of prose telling you to click it. An
            -- instruction line explaining where to click is the design
            -- admitting its controls do not look like controls.
            if not editing_this then
                slab("capbox" .. i, COL_CAP - 12, row * LINE - 1,
                    118, ROW_H - 4, FIELD_WELL)
            end

            line("cap" .. i, row, COL_CAP,
                editing_this and "" or short_amount(rule.amount),
                "title", ROW_PT)

            -- AT LIMIT, not PAUSED, and not amber.
            --
            -- PAUSED reads as "this rule is switched off" when it means "this
            -- rule fired". The most likely misreading was the exact opposite
            -- of the truth. Amber made it worse: it is the caution colour
            -- everywhere else in games, so two working rules looked like two
            -- warnings.
            line("done" .. i, row, COL_DONE,
                met and "AT LIMIT" or "Working",
                met and "atlimit" or "working", ROW_PT)

            -- The job is clickable separately from the amount. Rules no
            -- longer ask which job makes a thing, they guess, so there has to
            -- be somewhere to correct the guess.
            -- Asks before it deletes, and looks like it might.
            --
            -- Remove shared its exact colour with the inactive tab, CLOSE,
            -- the purpose line and the tile counts: six unrelated things, one
            -- of which destroys a rule. It had no confirm step either, so a
            -- misclick was silent and final.
            local asking = pending_drop ~= nil
                and pending_drop.work == rule.work
                and pending_drop.item == rule.item
            line("del" .. i, row, COL3,
                asking and "Sure?" or "Remove",
                asking and "danger" or "quiet", ROW_PT)

            hit(key, { kind = "job", rule = rule })
            hit("amt" .. i, { kind = "rule", rule = rule, row = row })
            hit("del" .. i, { kind = "drop", rule = rule })
            row = row + 1
        end
        row = row + 1
    end

    hit("new", { kind = "new" })
    stripe("new", row, PAD, W - PAD * 2)
    line("new", row, PAD, "+   Add a rule", "action")

    -- One row of breathing space, not two. The panel is sized from what it
    -- draws, so a spare row is 34 pixels of empty backdrop; with the top
    -- padding at 15 that left the bottom nearly four times deeper than the
    -- top and the whole thing looked bottom-heavy.
    return row + 1
end

-- A rule caps what a base produces, so an item the base cannot produce has
-- nothing to cap and does not belong in the picker at all. FireOrgan is the
-- case that showed it: a pal drop, sitting in storage, and picking it led to
-- a screen asking which job makes it, a question with no honest answer.
--
-- Producible is defined as "we can name the job that makes it", which is the
-- same question a rule has to answer anyway. That is what removes the job
-- screen rather than merely hiding it: everything reaching the picker already
-- knows its job, so there is nothing left to ask.
-- Item ids the game keeps for its own use, which no base can make.
--
-- "Show every item with a job" listed 598 items and among them were
-- Assault Rifle NPC Grass Boss, Assault Rifle Default2 through 5, Beam
-- Launcher 2 through 5 and Berries2. Those are the variants the game hands to
-- NPCs and bosses, and internal duplicates. Claiming a base can make them is
-- simply untrue, and a picker whose first page is rifles nobody can craft is
-- worse than one that shows less.
local INTERNAL = {
    "npc", "boss", "otomo", "default", "debug", "test_", "_test",
    "enemy", "raid", "invader", "dummy",
    -- Schematics, not products. A base does not make a blueprint, it consumes
    -- one, and the picker was showing four pages of them.
    "blueprint", "schematic", "recipe",
}

local function looks_internal(id)
    local hay = tostring(id):lower()
    for _, mark in ipairs(INTERNAL) do
        if hay:find(mark, 1, true) then return true end
    end
    return false
end

-- Berries2 next to Berries, PalSphere_Giga next to PalSphere. A trailing
-- digit on a name whose stem is also in the list is a variant of it, and only
-- the stem is worth capping. Checked against the list rather than assumed,
-- because PalUpgradeStone2 is a real and separate item with no PalUpgradeStone
-- beside it.
-- Rarity tiers, which Palworld numbers from 2 upwards: Beam Launcher 2
-- through 5, Charge 2 through 5, Berries2. A base making the tier-4 version of
-- a weapon is not a production line anybody caps, and thirteen pages of them
-- buried the fifty items that are.
--
-- Anything ending in a digit from 2 to 9 goes; the plain item stays, and an id
-- ending in 1 or 0 is a name rather than a tier.
local function drop_numbered_variants(list)
    local out = {}
    for _, id in ipairs(list) do
        if not tostring(id):match("[2-9]$") then
            out[#out + 1] = id
        end
    end
    return out
end

local function producible(id)
    if looks_internal(id) then return false end
    return workdefs.work_for_item(id) ~= nil
end

local function only_producible(list)
    local out = {}
    for _, id in ipairs(list or {}) do
        if producible(id) then out[#out + 1] = id end
    end
    return drop_numbered_variants(out)
end

local function picker_source(totals)
    -- Searching casts wider than the base holds, but still only over things
    -- the base could make. Asked for more rows than before, because the
    -- filter takes most of them away again.
    if search_text ~= "" then
        return only_producible(items.search(search_text, 400)), true
    end

    if show_all then
        return only_producible(items.load()), true
    end

    -- What the base holds, minus what it cannot make. Sorted by quantity, so
    -- the things worth capping are at the top.
    local out = {}
    for id in pairs(totals) do
        if producible(id) then out[#out + 1] = id end
    end
    table.sort(out, function(a, b)
        if totals[a] ~= totals[b] then return totals[a] > totals[b] end
        return a < b
    end)
    return out, false
end

local function draw_item_picker(cfg, totals)
    icons.new_frame()

    local source, everything = picker_source(totals)
    local pages = math.max(1, math.ceil(#source / PER_PAGE))
    if page >= pages then page = pages - 1 end
    if page < 0 then page = 0 end

    draw_tabs("item")

    -- The name of whatever the pointer is on, spelled out above the grid.
    -- A grid of pictures is quick to scan and useless for telling Ore from
    -- Ore, so the name has to be somewhere, and Creative Menu puts it here.
    local current = hover_key or was_sel
    local under = current and was_hit[current]
    line("naming", 3, PAD,
        (under and under.kind == "item") and under.item or "", "title", 18)

    ensure_search(4)

    -- The placeholder, ours rather than UMG's. Cleared the moment anything is
    -- typed, which is what a hint is supposed to do.
    -- No in-field placeholder. The field sits at a higher Z order than any
    -- text this panel draws, so a label placed inside it renders behind it and
    -- what shows through is the field. The prompt moved to the caption below,
    -- where it is this panel's own text in this panel's own colour.

    -- One space after a comma, and no page counter on a single page. The
    -- double spaces were a join artefact and read as broken kerning.
    local caption = string.format("%s, %d %s",
        search_text ~= "" and ("Matching " .. search_text)
            or (everything and "Every item with a job"
                or "What your storage holds"),
        #source, #source == 1 and "item" or "items")
    if pages > 1 then
        caption = caption .. string.format(", page %d of %d", page + 1, pages)
    end
    if search_text == "" then
        caption = caption ..
            "   |   Click the box to search, or click an item to limit it"
    end
    line("sub", 5, PAD, caption, "dim", 13)

    local top = 6 * LINE
    local from = page * PER_PAGE + 1

    grid_from, grid_count = #order + 1, 0

    -- Which items already have a rule, so the grid can say so.
    local has_rule = {}
    for _, r in ipairs(rule_list(cfg)) do has_rule[r.item] = true end

    for i = from, math.min(from + PER_PAGE - 1, #source) do
        local id = source[i]
        local key = "pick" .. (i - from)

        tile(key, i - from, id, totals[id] or 0, top, has_rule[id])
        hit(key, { kind = "item", item = id })
        grid_count = grid_count + 1
    end

    -- Where the grid ends, measured from the tiles actually drawn rather than
    -- from the page size. Reserving all five rows for ten items left the
    -- panel with an empty half and everything below it stranded at the
    -- bottom of a box nothing filled.
    local tall = math.max(1, math.ceil(grid_count / COLS))
    local row = 6 + math.ceil((tall * (TILE_H + GAP)) / LINE) + 1

    if pages > 1 then
        line("prev", row, PAD + 10, "<   Previous",
            page > 0 and "action" or "dim", ROW_PT)
        line("next", row, 220, "Next   >",
            page < pages - 1 and "action" or "dim", ROW_PT)
        if page > 0 then hit("prev", { kind = "page", by = -1 }) end
        if page < pages - 1 then hit("next", { kind = "page", by = 1 }) end
        row = row + 1
    end

    -- Rows, like every other action in this panel. These were 20pt text
    -- floating in dead space below the grid, which made the two most
    -- important controls on the screen look like a caption. "+ add a rule"
    -- across in the rules list is the same kind of thing and reads as a
    -- control because it sits on a stripe.
    hit("all", { kind = "toggle_all" })
    stripe("all", row, PAD, W - PAD * 2)
    line("all", row, PAD + 10,
        everything and "Show only what I have"
            or "Show every item with a job",
        "action", ROW_PT)
    row = row + 1

    hit("back", { kind = "back" })
    stripe("back", row, PAD, W - PAD * 2)
    line("back", row, PAD + 10, "<   Back", "action", ROW_PT)

    return row + 1
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

-- One pass of whichever screen is up, returning how many rows tall it came
-- out. Separated so the frame that changes height can run it twice.
local function redraw(cfg, totals)
    if mode == "item" then
        return draw_item_picker(cfg, totals)
    end
    hide_search()
    return draw_list(cfg, totals)
end

function M.refresh(cfg)
    -- Timed, because "laggy" has three plausible causes here and guessing
    -- between them has already cost a round. Reports the worst refresh seen
    -- in each five second window, once, with where the time went.
    local t0 = os.clock()
    frame_id = frame_id + 1

    -- The typed-ceiling box, when one is open: placed, then read.
    if editing ~= nil then
        ensure_amount_box()
        poll_amount(cfg)
    elseif alive(amount_box) then
        pcall(function() amount_box:SetVisibility(1) end)
    end

    if not M.open then return end
    if not ensure_root() then return end

    -- Which row the mouse is on, decided from last frame's map before it is
    -- rebuilt. One frame of lag on a highlight is invisible; drawing the whole
    -- screen twice to avoid it is not.
    local th = os.clock()
    local hn = 0
    hover_key = nil
    for key in pairs(hits) do
        -- A row reports through its text, a tile through its picture.
        local w = blocks[key] or images[key]
        local over = false
        hn = hn + 1
        pcall(function()
            if alive(w) then over = w:IsHovered() end
        end)
        if over == true then
            hover_key = key
            break
        end
    end
    perf_hover, perf_hits = os.clock() - th, hn

    was_hit, was_sel = hits, order[sel]
    hits, order, used = {}, {}, {}

    local ts = os.clock()
    local totals = stock_totals(cfg)
    perf_stock = os.clock() - ts

    local td = os.clock()
    local rows = redraw(cfg, totals)
    perf_draw = os.clock() - td

    -- Clamped after the draw, since the row count is only known then.
    if sel > #order then sel = #order end
    if sel < 1 then sel = 1 end

    -- Centred vertically from what was actually drawn.
    --
    -- The height is only known once the screen has been drawn, so a screen
    -- that changed height was drawn at the old offset while its backdrop was
    -- sized for the new one. That is the gap between the panel and its
    -- contents in the switch from ADD back to RULES. Drawing it again is
    -- cheaper than living with it, and only happens on the frame the height
    -- actually changes rather than every frame.
    local want = -math.floor((rows * LINE) / 2)
    if want ~= Y then
        Y = want
        -- Every remembered position was measured against the old offset.
        placed = {}
        hits, order, used = {}, {}, {}
        rows = redraw(cfg, totals)
    end

    ensure_backdrop(rows)
    local tb = os.clock()
    blank_unused()
    perf_blank = os.clock() - tb

    local ms = (os.clock() - t0) * 1000
    perf_worst = math.max(perf_worst, ms)
    if (os.clock() - perf_at) > 5.0 then
        perf_at = os.clock()
        if perf_worst > 4.0 then
            log.say(string.format(
                "panel refresh worst %.1fms  (hover %.1f/%d, stock %.1f, draw %.1f, blank %.1f)",
                perf_worst, perf_hover * 1000, perf_hits,
                perf_stock * 1000, perf_draw * 1000, perf_blank * 1000))
        end
        perf_worst = 0
    end
end

local function blank_everything()
    for key, tb in pairs(blocks) do
        if alive(tb) then
            local ft = make_ftext("")
            if ft then
                pcall(function() tb:SetText(ft) end)
                drawn[key] = ""
            end
        end
    end
    if alive(backdrop) then
        pcall(function() backdrop:SetBrushColor(CLEAR) end)
    end
    for key, border in pairs(stripes) do
        if alive(border) then
            pcall(function() border:SetBrushColor(CLEAR) end)
            drawn["s:" .. key] = "clear"
        end
    end
    for key, img in pairs(images) do
        if alive(img) then
            pcall(function() img:SetOpacity(0.0) end)
            drawn["i:" .. key] = "clear"
        end
    end
    hide_search()
    hits, hover_key = {}, nil
end

-- Switch screens without clicking, for driving the panel from outside while
-- it holds the input mode and no key press reaches us.
function M.set_screen(name)
    -- The cursor moves with the screen here too. Clicking a tab does this
    -- already; this is the same change arriving through the command channel,
    -- and the two paths disagreeing is how the marker ended up on RULES while
    -- ADD was the screen being shown.
    sel = tab_hits + 1
    if name ~= "item" and name ~= "list" then return false end
    mode, page, sel = name, 0, 1
    -- Same rule through the command channel as through a click: the picker
    -- does not take the keyboard just because it opened.
    want_focus = false
    return true
end

function M.toggle()
    M.open = not M.open

    if not M.open then
        blank_everything()
        overlay.hide()
        mode, page, show_all = "list", 0, false
        return
    end

    trace.at("panel: opening")
    if not overlay.show() then
        trace.done()
        M.open = false
        log.say("could not put the overlay on screen, see priority.log")
        return
    end
    trace.done()

    -- Chest counts are held for half a minute so the pass is not sweeping
    -- every base object every ten seconds. Opening this window is the one
    -- moment the numbers are being read by somebody, so they get measured
    -- now instead of being served up to thirty seconds stale.
    pcall(function() scheduler.forget_stock() end)

    log.say("work rules open, Ctrl+F9 again to close")
end

function M.reset()
    M.open = false
    scanned_once, scanned_at = nil, 0
    root, root_owner, root_tree, backdrop = nil, nil, nil, nil
    blocks, drawn, hits, used = {}, {}, {}, {}
    stripes, placed, search_box, search_text, want_focus = {}, {}, nil, "", false
    amount_box, editing, edit_focus = nil, nil, false
    styled_boxes = {}
    images, item_of, grid_from, grid_count = {}, {}, 0, 0
    icons.reset()
    was_hit, was_sel, hover_key = {}, nil, nil
    mode, page, show_all = "list", 0, false
    ftext_mode = nil
    warned = {}
end

-- ---------------------------------------------------------------------------
-- Clicking
-- ---------------------------------------------------------------------------

local function step(current, dir)
    if dir < 0 then
        if current == nil then return caps.LADDER[1] end
        for _, n in ipairs(caps.LADDER) do
            if n > current then return n end
        end
        return caps.LADDER[#caps.LADDER]
    end

    if current == nil then return nil end
    local below = nil
    for _, n in ipairs(caps.LADDER) do
        if n < current then below = n end
    end
    return below
end

local function hovered()
    for key, what in pairs(hits) do
        local w = blocks[key] or images[key]
        local over = false
        pcall(function()
            if alive(w) then over = w:IsHovered() end
        end)
        if over == true then
            -- Moving the mouse moves the keyboard position with it, so the
            -- two never disagree about which row is current.
            for i, k in ipairs(order) do
                if k == key then sel = i break end
            end
            return what
        end
    end
    return nil
end

-- Arrow keys. The mouse works, but the cursor sits over a live game world and
-- the rows are thin, so this is the reliable way in.
function M.move(delta)
    if not M.open or #order == 0 then return false end

    sel = sel + delta
    if sel > #order then sel = 1 end
    if sel < 1 then sel = #order end
    return true
end

-- What an arrow key means depends on which screen is up, so the meaning is
-- decided here rather than at the keybind. On the rules list up and down walk
-- the rules while left and right raise and lower the ceiling. In the picker
-- every arrow moves, because a grid has two dimensions and there is nothing
-- to raise, and Enter is what picks.
function M.nav(cfg, what)
    if not M.open then return false end

    if what == "enter" then return M.activate(cfg, -1) end

    if mode == "item" then
        if what == "left" then return M.move(-1) end
        if what == "right" then return M.move(1) end

        -- Up and down cross a whole row of tiles. Only while the selection is
        -- among them: on the buttons underneath, a row is one step.
        local at = sel - grid_from
        if grid_count > 0 and at >= 0 and at < grid_count then
            local to = at + (what == "up" and -COLS or COLS)
            if to >= 0 and to < grid_count then
                sel = grid_from + to
                return true
            end
        end
        return M.move(what == "up" and -1 or 1)
    end

    if what == "up" then return M.move(-1) end
    if what == "down" then return M.move(1) end
    if what == "right" then return M.activate(cfg, -1) end
    if what == "left" then return M.activate(cfg, 1) end
    return false
end

-- Enter and backspace stand in for left and right click on the selected row.
function M.activate(cfg, dir)
    if not M.open then return false end

    local what = hits[order[sel] or ""]
    if what == nil then return false end
    return M.apply(cfg, what, dir)
end

-- Returns true when the click was ours, so the caller leaves the grid alone.
-- One way in for every test action, so new ones cost no restart.
--
-- main.lua cannot be hot swapped, so each command added there costs a game
-- restart to try. This module can, so a single generic command over there and
-- a dispatcher here means every future panel action is reachable by editing
-- one hot-reloadable file. That is the difference between testing a change in
-- ten seconds and testing it in two minutes with somebody else's hands.
--
--   pwp panel click item Wood     click a picker tile
--   pwp panel click rule 1        the first rule's ceiling
--   pwp panel click job 1         its work type
--   pwp panel click drop 1        its remove
--   pwp panel click tab add       a tab: add, list
--   pwp panel click close|new|back|toggle_all
--   pwp panel nav up|down|left|right
--   pwp panel filter <text>       type into the picker's filter
--   pwp panel type <number>       type into an open ceiling box and commit
--   pwp panel state               what is on screen right now
function M.command(cfg, args)
    local verb, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
    rest = (rest ~= "" and rest) or nil

    if verb == "click" then
        local kind, arg = tostring(rest or ""):match("^(%S*)%s*(.-)$")
        return M.click_named(cfg, kind, (arg ~= "" and arg) or nil, -1)
    end

    if verb == "nav" then
        if not M.open then return "the panel is shut" end
        if rest == "up" then M.move(-1) return "moved up"
        elseif rest == "down" then M.move(1) return "moved down"
        elseif rest == "left" or rest == "right" then
            local what = hits[order[sel]]
            if what == nil then return "nothing selected" end
            local ok, r = pcall(M.apply, cfg, what, rest == "left" and -1 or 1)
            if not ok then return "failed: " .. tostring(r) end
            return "applied " .. rest .. " to " .. tostring(what.kind)
        end
        return "use nav up|down|left|right"
    end

    if verb == "focus" then
        if not alive(search_box) then return "no filter box on this screen" end
        want_focus = true
        return "keyboard moved to the filter box"
    end

    if verb == "filter" then
        if not alive(search_box) then return "no filter box on this screen" end
        search_text = rest or ""
        pcall(function() search_box:SetText(make_ftext(search_text)) end)
        return "filter is now '" .. search_text .. "'"
    end

    if verb == "type" then
        if editing == nil then return "no ceiling box is open" end
        local n = tonumber(tostring(rest or ""):match("%d+"))
        if n == nil then return "give a number" end
        -- Straight down the same road the box takes when focus leaves it.
        local job, item = editing.work, editing.item
        editing = nil
        pcall(function() amount_box:SetVisibility(1) end)
        if n <= 0 then
            caps.clear(job, item)
        else
            caps.set(job, item, n)
        end
        M.wants_pass = true
        return string.format("%s %s set to %d", workdefs.label(job), item, n)
    end

    -- Reads only, and only off a widget that already exists and is parented.
    -- Constructing a throwaway one to probe is what crashed the game earlier
    -- today: a UMG widget with no WidgetTree outer and no slot faults when a
    -- brush call walks up to a parent that is not there.
    if verb == "probe" then
        local w = (rest == "amount") and amount_box or search_box
        if not alive(w) then return "that box does not exist right now" end

        local out = {}
        local cls
        pcall(function() cls = w:GetClass():GetFName():ToString() end)
        out[#out + 1] = "class=" .. tostring(cls)

        -- What it actually holds, which is the difference between a field
        -- that is empty and one whose text is the same colour as its own
        -- background.
        local txt
        pcall(function()
            local ft = w:GetText()
            if ft then txt = ft:ToString() end
        end)
        out[#out + 1] = "text='" .. tostring(txt) .. "'"

        for _, name in ipairs({
            "SetForegroundColor", "SetStyle", "SetTextStyle",
            "SetJustification", "SetHintText", "SetIsReadOnly",
            "WidgetStyle", "Style", "Font", "ForegroundColor",
        }) do
            local got
            pcall(function() got = w[name] end)
            out[#out + 1] = name .. "=" .. type(got)
        end

        -- What the style struct actually carries, if it can be read at all.
        local st
        pcall(function() st = w.WidgetStyle end)
        if st ~= nil then
            for _, f in ipairs({ "BackgroundImageNormal", "ForegroundColor",
                                 "BackgroundColor", "Padding", "Font",
                                 "TextStyle", "HintTextColor", "ReadOnlyForegroundColor",
                                 "FocusedForegroundColor" }) do
                local v
                pcall(function() v = st[f] end)
                out[#out + 1] = "  WidgetStyle." .. f .. "=" .. type(v)
            end
        end

        return table.concat(out, "  ")
    end

    if verb == "state" then
        local kinds = {}
        for _, key in ipairs(order) do
            local h = hits[key]
            if h then
                kinds[#kinds + 1] = h.kind ..
                    (h.item and (":" .. h.item) or "") ..
                    (h.mode and (":" .. h.mode) or "")
            end
        end
        return string.format("screen=%s open=%s rows=%d sel=%d editing=%s | %s",
            tostring(mode), tostring(M.open), #order, sel,
            editing and (editing.item or "yes") or "no",
            table.concat(kinds, ", "))
    end

    return "use: click | nav | filter | type | state"
end

-- Click something by name, without a mouse.
--
-- The panel holds the input mode while it is open, so a real click is the one
-- thing that cannot be driven from outside, and every interaction has had to
-- be tested by asking a person to click and then reading a log. This walks the
-- same hit map the pointer walks and calls the same handler, so it exercises
-- the real path rather than a shortcut around it.
--
-- "pwp click item Wood"   the picker tile for an item
-- "pwp click rule 1"      the ceiling on the first rule
-- "pwp click job 1"       that rule's work type
-- "pwp click tab add"     a tab, or close, or new, or back
function M.click_named(cfg, kind, what_arg, dir)
    if not M.open then return "the panel is shut" end
    dir = dir or -1

    local wanted = nil
    for _, key in ipairs(order) do
        local h = hits[key]
        if h and h.kind == kind then
            if kind == "item" and h.item == what_arg then
                wanted = h
            elseif (kind == "rule" or kind == "job" or kind == "drop")
                and tostring(what_arg) == "1" then
                wanted = h
            elseif kind == "tab" and h.mode == what_arg then
                wanted = h
            elseif what_arg == nil then
                wanted = h
            end
            if wanted then break end
        end
    end

    if wanted == nil then
        return "nothing on this screen matches " .. tostring(kind) ..
            " " .. tostring(what_arg)
    end

    local ok, result = pcall(M.apply, cfg, wanted, dir, true)
    if not ok then return "failed: " .. tostring(result) end
    return "clicked " .. kind .. " " .. tostring(what_arg) ..
        " -> " .. tostring(result)
end

function M.handle_click(cfg, dir)
    if not M.open then return false end

    local what = hovered()

    -- Says which of two very different failures is happening when a click
    -- does nothing. Reaching here at all means UE4SS saw the button, so the
    -- input mode is not eating it and the hit test is at fault. Never
    -- reaching here means the opposite, and no amount of work on hit testing
    -- would have helped.
    if M.debug_clicks then
        log.say(string.format("click: dir=%s screen=%s hovered=%s",
            tostring(dir), tostring(mode),
            what and tostring(what.kind) or "nothing"))
    end

    if what == nil then
        -- A click on nothing still ends an edit, which is how "click away to
        -- set it" is honoured when the click lands on empty panel.
        return false
    end

    -- Reported, not swallowed. ui.bind_mouse wraps this whole call in a bare
    -- pcall and throws the message away, so a click that hit its target and
    -- then failed looked exactly like a click that never landed: the hit test
    -- said "item", and nothing happened, and nothing said why.
    local ok, result = pcall(M.apply, cfg, what, dir, true)
    if not ok then
        log.warn("click on " .. tostring(what.kind) .. " failed: " ..
            tostring(result))
        return false
    end
    return result
end

-- What a row does, whichever way it was reached.
function M.apply(cfg, what, dir, from_mouse)
    if what.kind == "close" then
        M.toggle()
        return true
    end

    if what.kind == "new" then
        mode, page, show_all = "item", 0, false
        want_focus = false
        sel = 1
        log.say("picking an item, type to filter or click one")
        return true
    end

    if what.kind == "tab" then
        mode, page = what.mode, 0
        want_focus = false
        sel = tab_hits + 1
        return true
    end

    if what.kind == "page" then
        page = page + what.by
        return true
    end

    if what.kind == "toggle_all" then
        show_all = not show_all
        page = 0
        return true
    end

    if what.kind == "back" then
        mode, page = "list", 0
        sel = tab_hits + 1
        return true
    end

    if what.kind == "item" then
        -- The job is never asked for. Only items with a known job reach the
        -- picker, so this fallback is for an id the filter let through rather
        -- than a real choice, and it lands on a rule that can be corrected in
        -- place instead of on a dead end.
        local work = workdefs.work_for_item(what.item) or workdefs.DEFAULT_WORK

        caps.set(work, what.item, caps.LADDER[1])
        log.say(string.format("rule added: %s until %d %s",
            workdefs.label(work), caps.LADDER[1], what.item))
        M.wants_pass = true
        mode, sel = "list", 1
        return true
    end

    -- Correcting a guess. Walks the work types in order rather than opening
    -- another screen for it.
    if what.kind == "job" then
        local rule = what.rule
        local at = 1
        for i, name in ipairs(workdefs.ORDER) do
            if name == rule.work then at = i break end
        end

        local step = (dir < 0) and 1 or -1
        for _ = 1, #workdefs.ORDER do
            at = at + step
            if at > #workdefs.ORDER then at = 1 end
            if at < 1 then at = #workdefs.ORDER end
            if workdefs.ORDER[at] ~= workdefs.ANYONE then break end
        end

        local moved = workdefs.ORDER[at]
        caps.clear(rule.work, rule.item)
        caps.set(moved, rule.item, rule.amount)
        log.say(rule.item .. " is now made by " .. workdefs.label(moved))
        M.wants_pass = true
        return true
    end

    if what.kind == "drop" then
        local rule = what.rule

        -- First click asks, second click inside four seconds does it.
        if pending_drop == nil
            or pending_drop.work ~= rule.work
            or pending_drop.item ~= rule.item
            or (os.clock() - pending_at) > 4.0
        then
            pending_drop = { work = rule.work, item = rule.item }
            pending_at = os.clock()
            log.say("Click Remove again to delete the " ..
                workdefs.label(rule.work) .. " limit on " .. rule.item)
            return true
        end

        pending_drop = nil
        caps.clear(what.rule.work, what.rule.item)
        log.say("rule removed: " .. workdefs.label(what.rule.work) ..
            " " .. what.rule.item)
        M.wants_pass = true
        return true
    end

    if what.kind == "rule" then
        local rule = what.rule

        -- Left click types, right click and the arrows step. Both are worth
        -- having: the ladder is faster for a nudge, typing is the only way to
        -- land on a number that is not on it.
        if from_mouse and dir < 0 then
            begin_edit(rule, what.row or 3)
            log.say("type a ceiling, then click away to set it")
            return true
        end

        local next_amount = step(rule.amount, dir)

        if next_amount == nil then
            caps.clear(rule.work, rule.item)
            log.say("rule removed: " .. workdefs.label(rule.work) ..
                " " .. rule.item)
        else
            caps.set(rule.work, rule.item, next_amount)
        end
        M.wants_pass = true
        return true
    end

    return false
end

return M
