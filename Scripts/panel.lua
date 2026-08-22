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
local root_tree = nil           -- that layout's WidgetTree, our outer
local backdrop = nil
local blocks = {}               -- key -> TextBlock
local drawn = {}                -- key -> last token drawn
local hits = {}                 -- key -> what clicking it means
local order = {}                -- the same keys in draw order, for the arrows

-- A tile's whole face, for hit testing.
--
-- Hover tested the icon, which is 48 square inside a tile 76 by 118, so about
-- a fifth of what looks like a button actually answered the pointer and the
-- highlight came and went as the mouse crossed the name. Only tiles go in
-- here: a rules row's stripe spans the full width, and letting that answer
-- would put it in competition with the limit and the Remove drawn on top of
-- it, decided by whichever pairs() reached first.
local tile_face = {}
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

-- Forward declarations. Their bodies live next to the code that uses them,
-- far below, but ensure_root has to clear them when the overlay is rebuilt -
-- and a name assigned above its own `local` writes a global and leaves the
-- real local nil forever.
local styled_boxes = {}         -- which fields have had their style applied
local picker_key = nil          -- { search_text, show_all, totals }
local picker_hit = nil          -- { list, everything }

-- Forward declaration. Its body is far below, next to the scan it wraps, but
-- poll_amount calls it when a typed limit is committed. Without this the name
-- resolved to a nil global there, so committing a number threw AFTER the
-- limit had already been stored: the value took, the "this is below the %d in
-- storage, so %s stops now" warning never printed, and refresh aborted for
-- that frame. Silent, and the warning it swallowed is the important one.
local stock_totals

-- Switched on with "pwp clicks", or here, since this module hot reloads and
-- main.lua does not: turning it on in the file is the only way to get it into
-- a session that started before the command existed.
-- Off by default. Every click wrote a formatted line to priority.log, and
-- log writes are an open/write/close each; "pwp clicks" turns it on for a
-- session that needs it.
M.debug_clicks = false
local edit_focus = false        -- focus is taken once, not fought for
local search_text = ""
local want_focus = false
local sel = 1                   -- which row the keyboard is on
-- "put the cursor on the first real row once you know where that is".
--
-- Opening the panel or switching screens wants the cursor past the tab strip,
-- because both the selection tint and the caret are suppressed on tabs on
-- purpose - so a cursor parked there is a cursor nobody can see. It cannot be
-- set at the time of asking: tab_hits is counted while drawing, and after a
-- reload or a fresh open it is still zero, so tab_hits + 1 is the first tab
-- again. Resolved after the draw instead, where the number is real.
local want_first_row = false
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
-- Where the panel's top edge lives, always. Chosen so the tallest screen
-- still clears the bottom of a 1080 viewport.
local TOP_Y = -300
local Y = TOP_Y
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
local COL_DONE = 810      -- what the pals are doing
-- Remove, pushed right into the inset the rows were not using. Its surface
-- used to end 16 pixels after the status word, so the two read as a pair and
-- the only control in the row that destroys something sat shoulder to
-- shoulder with a label.
local COL3     = 952
local TAB_H = 34

-- The limit's well, and the two numeric right edges derived from it.
--
-- The well's inset used to be a bare 12 written at the call site while the
-- row stripe subtracted 6 and the column headers subtracted nothing, so one
-- row carried three different ideas of where its left edge was and the well
-- sat 13 pixels left of the heading above it. One number now, used by both.
--
-- Numbers are placed from a right edge rather than a left origin. Left
-- aligned, "8879" and "16562" shared a left edge and differed by 14 pixels on
-- the right, so the digit places did not line up in a column whose entire
-- purpose is telling which of two numbers is bigger.
-- The row band's own inset, six pixels outside the text inset, so a stripe
-- reads as a band behind a whole row rather than a box around its words.
-- Everything that has to finish flush with a row edge is derived from it:
-- the band ended at 1026 while Remove's surface ended at 1032, so the one
-- control that destroys something hung six pixels off the end of its row.
local ROW_INSET = PAD - 6
local ROW_W     = W - ROW_INSET * 2

-- How far a control set inside a row band stops short of the band's own edge.
-- Remove used to finish exactly where the band did, so it read as sitting ON
-- the end of the row rather than IN it. A band has to be visibly longer than
-- anything it contains or it is not a band.
local ROW_PAD   = 10

-- The filter field is taller than a row on purpose: it is the one thing on
-- the picker you type into, and it reads as a field rather than a band.
local SEARCH_H  = 36

local WELL_INSET = 12
-- Room for six grouped digits and a caret at 17pt. At 118 a four digit
-- number plus its cursor already filled the box edge to edge.
local WELL_W     = 136
local COL2_R     = COL_CAP - WELL_INSET - 18                  -- storage, clear of the well
local COL_CAP_R  = COL_CAP - WELL_INSET + WELL_W - WELL_INSET -- inside the well

-- The picker as a list of named rows, not a grid of pictures.
--
-- The grid was the right shape for a shelf you already know and the wrong one
-- for finding something. Eleven unlabelled 40px icons mean hover, read the
-- name 877 pixels away at the top of the panel, move, repeat - and the two
-- most common targets, Stone and Wood, are both grey-brown lumps at that
-- size. Tick "show every item" and it becomes 233 items over five pages of
-- the same. A name column answers it: three across so a page still holds
-- eighteen, names read in parallel instead of one per hover, and the search
-- field above finally filters something a reader can see.
--
-- The objection to names on TILES was that they clipped, wrapped and broke
-- words across lines in a 76 pixel square. That objection is about the square,
-- not about names: here a name gets 210 pixels of its own column.
local LIST_COLS    = 3
local LIST_GUTTER  = 12
local LIST_W       = math.floor((W - PAD * 2 - LIST_GUTTER * (LIST_COLS - 1))
                                / LIST_COLS)
local LIST_H       = 36
local LIST_PITCH   = LIST_H + 4
local LIST_ROWS    = 6
local LIST_PER_PAGE = LIST_COLS * LIST_ROWS
local LIST_ICON    = 28
local LIST_NAME_X  = 44
local LIST_COUNT_R = LIST_W - 10
-- The name's budget is worked out per row from what the count leaves, so
-- there is no fixed character count here any more.

-- No minimum height, deliberately. Padding the list up to the picker's height
-- was tried to stop the panel resizing on a tab switch, and it is the wrong
-- trade: the picker is itself variable - one grid row for eleven items, four
-- for a full page - so the floor has to be the tallest case, which left both
-- screens sitting in several hundred pixels of empty backdrop. A panel that
-- fits its contents is normal. The tab strip is top-anchored and does not
-- move, which was the part that actually cost anything.

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
    -- Past the limit, which is a normal resting state rather than a fault,
    -- so it is amber and not red.
    over   = { R = 0.94, G = 0.74, B = 0.36, A = 1.00 },
    -- Quieter than the data it sits beside, so it does not compete, but its
    -- own colour rather than the one five harmless things share.
    -- Warm and clearly readable. This was the lowest contrast text anywhere
    -- in the panel, on the one control that destroys something, which is
    -- exactly backwards.
    quiet  = { R = 0.94, G = 0.64, B = 0.60, A = 1.00 },
    working = { R = 0.55, G = 0.62, B = 0.70, A = 1.00 },
    -- On the filled primary button, where cyan-on-tint measured 3.94 and was
    -- the lowest contrast text in the panel while being its main action.
    primary = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    -- The filter placeholder, on the filter well. Light enough to clear 4.5
    -- there, quiet enough not to be mistaken for something already typed.
    hint_on_field = { R = 0.31, G = 0.35, B = 0.41, A = 1.00 },
    -- A control that exists but has nothing left to do. Quieter than an
    -- active one and darker than the prose, so "no more pages" cannot be
    -- mistaken for a sentence.
    spent  = { R = 0.34, G = 0.38, B = 0.44, A = 1.00 },
}

-- Nearly opaque on purpose. At 0.94 a bright afternoon base read straight
-- through the panel and the text had to compete with grass; a rules window is
-- something to read, not a HUD element to see past. The rows sit a shade
-- lighter than the backdrop so a list reads as rows without needing borders.
local BACKDROP  = { R = 0.035, G = 0.050, B = 0.075, A = 0.985 }
-- Three surfaces, not one.
--
-- The header band, the data rows, the tiles and every button were the same
-- fill, so a static title bar and a pressable control were indistinguishable
-- and nothing in the panel looked like it could be touched. Chrome sits below
-- the body, data sits on it, and things you press sit above it.
-- Chrome was 0.045/0.060/0.082, which is LIGHTER than the backdrop on all
-- three channels: the comment above said chrome sits below the body and the
-- numbers did the opposite. Measured off a screenshot it came out at
-- (60,69,81) against a body of (55,65,79) - a contrast ratio of 1.064, which
-- is not a tone, it is a rounding error. Now genuinely darker, at 1.40.
local CHROME_BG = { R = 0.014, G = 0.021, B = 0.035, A = 1.00 }
local ROW_BG    = { R = 0.080, G = 0.105, B = 0.140, A = 1.00 }
local BUTTON_BG = { R = 0.120, G = 0.152, B = 0.196, A = 1.00 }
-- Tiles are pressable, so they wear the pressable tone rather than the
-- read-only one. They used to fall through to ROW_BG, which made a tile in
-- the picker byte-identical to a data row on the rules list: the surface was
-- encoding "inside the panel" instead of "you can click this", which is
-- exactly backwards from what three tones were introduced to do.
-- List rows use the DATA tone, not the button tone.
--
-- They wore BUTTON_BG so a pressable row would not look like a read-only one,
-- and it cost three contrast failures: at (97,109,122) the count measured
-- 4.16, the green has-rule name 4.12 and a cyan label 3.94, all under 4.5.
-- The rules table has always used ROW_BG and every token on it passes, so the
-- fix is to stop having two greys for the same job. Pressability is carried
-- by the rail and the hover lift instead, which is where it belongs: a fill
-- that has to be light enough to read as a control is a fill that is too
-- light to read text on.
local TILE_BG   = ROW_BG
-- Filled, for the single action on a screen that creates something. A
-- secondary control is a tinted bar with a cyan label; the primary one is a
-- solid field with a white label, so the two stop being the same object.
local PRIMARY_BG = { R = 0.034, G = 0.188, B = 0.305, A = 1.00 }
-- Behind Remove, so it reads as a control rather than as a second status
-- word, and towards red so it reads as the destructive one. The brighter of
-- the two is the armed state, while the row is asking "Sure?".
local DANGER_WELL    = { R = 0.115, G = 0.030, B = 0.028, A = 1.00 }
local DANGER_WELL_ON = { R = 0.320, G = 0.055, B = 0.048, A = 1.00 }
-- Both are DARKER than a normal row, not brighter, and that is the whole
-- point of them.
--
-- Lifting them was the obvious move and it was wrong. Every token in this
-- panel is light - amber, white, cyan - so a brighter fill eats their
-- contrast: at the brightest version the amber on a selected row measured
-- 2.73:1, under the 3:1 floor for large text, on the one row the player is
-- actually working with. Selecting a row made it the hardest row on screen to
-- read, which is the exact inverse of what selecting is for.
--
-- Going down instead separates just as well - 1.38 against a normal row,
-- against 1.94 for the bright version - while every token GAINS contrast:
-- that same amber comes back at 7.3:1. Luminance is the wrong channel to
-- carry this signal up; the caret and the accent bar carry it instead.
-- Hover shares the selection fill on purpose.
--
-- Its own darker value measured 1.20 against the panel body, so a hovered row
-- effectively vanished into the panel, and 1.34 against the selection, so
-- hovering made a row read as MORE selected than the selected one. Every fill
-- dark enough to sit below the selection lands within 1.5 of both. The signal
-- moved to the rail, which gets wider under the pointer.
local ROW_HOVER = { R = 0.025, G = 0.065, B = 0.117, A = 1.00 }
local RAIL_W      = 3
local RAIL_W_HOT  = 6
-- Where the keyboard is, quieter than where the mouse is.
local ROW_SEL   = { R = 0.025, G = 0.065, B = 0.117, A = 1.00 }
-- The cyan edge that says "this one", independent of fill luminance. A row
-- has the caret; a tile has no room for one and gets this instead.
local ACCENT    = { R = 0.42,  G = 0.80,  B = 1.00,  A = 1.00 }
-- "this one already has a rule", on the same left rail the cursor uses. It
-- was a 6x5 pixel dot in the corner of a tile, which is under the threshold
-- of being noticed at all and, under deuteranopia, the same colour as Remove.
-- A full-height bar is position-encoded, so it survives any colour vision and
-- it scans down a column.
local RULE_RAIL = { R = 0.558, G = 0.847, B = 0.631, A = 1.00 }
-- A hit region with no appearance. A Border with a fully transparent brush
-- still takes hit testing while its visibility is Visible, which is what lets
-- a word have a click target bigger than itself without a box drawn round it.
local INVISIBLE = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
-- Inset, darker than the row it sits in, which is how every text field in
-- every dark interface says "type here".
-- Measurably darker than the row it sits in, not merely darker than nothing.
-- The first attempt used the panel's own colour, so the well only existed
-- where a row stripe happened to be behind it and its boundary against that
-- stripe measured 1.48:1, under the 3:1 a UI boundary needs to be seen.
local FIELD_WELL = { R = 0.012, G = 0.020, B = 0.030, A = 1.00 }
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
-- Dark, because this field's text is light.
--
-- Worth writing down because it was got backwards twice. The ceiling box
-- renders what you type in a dark colour, so that one needs a pale field. The
-- filter box renders it light, so a pale field hides it, which is what
-- "typing in the text bar is unreadable" was. Same widget class, two
-- different text colours, neither of them settable from here.
--
-- So they no longer share a colour. This one is dark and matches the panel.
local FIELD_BG    = { R = 0.055, G = 0.075, B = 0.100, A = 1.00 }
local CEILING_BG  = { R = 0.82,  G = 0.85,  B = 0.89,  A = 1.00 }
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
        root, root_tree, backdrop = nil, nil, nil
        blocks, drawn, stripes, placed = {}, {}, {}, {}
        images, tile_face = {}, {}
        search_box, amount_box, editing = nil, nil, nil
        styled_boxes = {}
        picker_key, picker_hit = nil, nil
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
    root, root_tree = host, host_tree
    backdrop = nil
    blocks, drawn, stripes, placed = {}, {}, {}, {}
    -- Every table that holds a widget, not just the four that were listed.
    --
    -- images, tile_face and amount_box survived both resets and kept handles
    -- into the tree that was just discarded, and tile_face is guaranteed to:
    -- tile() writes tile_face[key] = stripes[key], so it is a second
    -- reference to a table this line clears. Those handles are then asked
    -- IsHovered() by the mouse keybind and alive() by blank_unused, which is
    -- the stored-wrapper dereference that this whole codebase is built to
    -- avoid - and the comment three lines up says so in as many words.
    images, tile_face = {}, {}
    search_box, amount_box, editing = nil, nil, nil
    -- Cleared with the boxes it describes. style_box only ever styles a given
    -- field once, keyed here, so leaving this set after the boxes are dropped
    -- meant the rebuilt EditableTextBox kept UMG's pale default - light text
    -- on a pale field, which is the unreadable-filter bug this panel already
    -- spent a round fixing.
    styled_boxes = {}
    -- The picker list was built from an item table that went with the old
    -- world. Nothing else invalidates it: a world switch resets search_text
    -- and show_all to the values already in the key, so it would match.
    picker_key, picker_hit = nil, nil
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
-- hittable: this slab is the thing the pointer reports, instead of whatever
-- text happens to sit on it.
--
-- Slabs are hit-test invisible by default and that was right when a row's
-- only clickable thing was one word. It stopped being right as rows grew:
-- a list row's hit key owns no text at all - its name is drawn under
-- "n:"..key - so the only hoverable part of a 330 by 36 row was the 28 pixel
-- icon, and a row whose icon had not loaded could not be hovered at all.
-- The tab bar had the same shape: the target was the word ADD and nothing
-- else, about 50 pixels wide.
local function slab(key, px, py, w, h, colour, hittable)
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
        -- Hit test invisible unless the caller wants this to BE the target.
        -- A visible-to-hit-testing border sits above the text it backs and
        -- swallows its hover, which is exactly what is wanted when the slab
        -- is registered as the surface for the key, and exactly what is not
        -- when several separate words on one row each need their own.
        pcall(function() border:SetVisibility(hittable and 0 or 3) end)
        stripes[key] = border
    end

    -- Re-applied every time, not only at construction: a recycled border may
    -- have been made for a different role last frame.
    pcall(function() border:SetVisibility(hittable and 0 or 3) end)

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
            -- State first, base colour second. It read `colour or hot or sel
            -- or ROW_BG`, and Lua stops at the first non-nil: any caller that
            -- passed a colour got that colour forever. The three action rows
            -- all pass BUTTON_BG - "+ Add a rule", "Show every item with a
            -- job", "< Back" - so the panel's three most pressable controls
            -- were the only ones that could never light up under the mouse or
            -- the keyboard.
            border:SetBrushColor((want == "hot" and ROW_HOVER)
                or (want == "sel" and ROW_SEL)
                or colour
                or ROW_BG)
        end)
        drawn["s:" .. key] = token
    end
end

-- A full width row, which is what the rules list is made of.
local function stripe(key, row, from, width, colour, hittable)
    slab(key, from - 6, row * LINE - 3, width, ROW_H, colour, hittable)
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
    -- Tabs keep their own colour. The selection tint was overriding it, so on
    -- the picker the inactive RULES tab rendered brighter than the active ADD
    -- tab and the underline was the only thing still telling the truth.
    local shown = (selected and not key:match("^tab_")) and "hover" or colour_key

    -- The marker used to be glued on here, as a "> " or "  " prefix on every
    -- clickable string. That put a 13 pixel slot inside three different
    -- columns of the same row - the job, the storage figure and Remove - and
    -- only the JOB heading was ever compensated for it, so IN STORAGE hung 12
    -- pixels right of its own heading and nothing numeric could be aligned on
    -- an edge. It also meant a row with several hit keys marked whichever one
    -- the pointer was over rather than the row.
    --
    -- It is now one element per row, drawn in its own slot by the caller. See
    -- row_is_current and MARK_W.

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

-- The cursor slot at the left of every selectable row, and the caret drawn
-- into it. 13 pixels is what the old two-space prefix measured at 17pt, so
-- rows keep the indent they already had and only the header moves to match.
-- How far the title block sits below its plain row position, so there is a
-- band of chrome between the tab strip and the words under it.
local TITLE_DROP = 10

local MARK_W = 20

-- The leading glyph on an action row: "+", "<", or the toggle's box. Wide
-- enough for the widest of them at ROW_PT, so every label starts on one edge.
local GLYPH_SLOT = 42

-- Whether any of a row's hit keys is the current one.
--
-- A rule row owns four - the job, the storage figure, the limit and Remove -
-- and the marker belongs to the row rather than to whichever of them the
-- pointer happens to be over. The pointer wins when it is over something,
-- otherwise the keyboard position stands, which is the same rule the stripe
-- tint uses so the two can never disagree.
local function row_is_current(...)
    local cur = hover_key or was_sel
    if cur == nil then return false end
    for i = 1, select("#", ...) do
        if select(i, ...) == cur then return true end
    end
    return false
end

-- drop: extra pixels down, for the two header lines that need clearance
-- under the tab bar without moving every row beneath them.
local function line(key, row, col, text, colour_key, points, drop)
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
    local y = (row * LINE - 3) + (ROW_H - pt * 1.35) / 2 - pt * 0.13 + (drop or 0)
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

-- Placing text by its right edge or its centre.
--
-- text_at asks the slot to auto-size, because sizing a text slot explicitly
-- produced widgets that positioned correctly and drew nothing (see the note
-- on text_at). Auto-size means a string grows rightward from its origin and
-- there is no justification to set, so alignment has to be done by choosing
-- the origin, which means knowing how wide the string will be.
--
-- Both factors are measured off screenshots rather than guessed. Digits are
-- much narrower than the average glyph: four digits of "8879" at 17pt
-- occupied 49 pixels, and "16562", "8000" and "15000" all agree on 12.2 to
-- 12.4 pixels per digit. Using the word factor for numbers would overestimate
-- by a sixth and leave every right-aligned column visibly short of its edge.
local GLYPH_W = 0.83     -- mixed-case words, from the tab bar
local DIGIT_W = 0.72     -- digits, from the rules list
-- All-caps column headings. Measured off the first right-aligned build, where
-- IN STORAGE and LIMIT came up 7 and 4 pixels short of the edge their own
-- values sat on, because the mixed-case factor overestimates a caps-and-space
-- string by about seven percent.
local CAPS_W  = 0.76

-- Thousands separators. The only thing the numeric columns are for is
-- deciding which of two figures is bigger, and "16562" against "15000" makes
-- a reader count digit positions where "16,562" against "15,000" does not.
-- Shared so the picker and the rules list cannot write the same number two
-- different ways, which they did.
local function group_digits(n)
    local flipped = tostring(math.floor(tonumber(n) or 0)):reverse()
    local chunked = flipped:gsub("(%d%d%d)", "%1,")
    local out = chunked:reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

local function text_w(text, pt, factor)
    text = tostring(text)
    -- Separators are much narrower than the digits around them, and counting
    -- them as full width made every grouped number finish short of the edge
    -- it was aligned to while an ungrouped one landed on it - so "573" hung
    -- four pixels right of "16,635" in a column whose only job is comparing
    -- them. Measured at roughly two fifths of a digit.
    local commas = select(2, text:gsub(",", ""))
    return (#text - commas * 0.6) * pt * (factor or GLYPH_W)
end

local function centre_x(px, w, text, pt, factor)
    return px + math.max(0, (w - text_w(text, pt, factor)) / 2)
end

local function right_x(edge, text, pt, factor)
    return edge - text_w(text, pt, factor)
end


-- An item id as words. "Food_BerryJuice" reads "Food Berry Juice".
--
-- The second pattern keeps runs of capitals together, so HPMedicine breaks as
-- HP Medicine rather than into single letters.
local function pretty_name(item)
    local out = {}
    for chunk in tostring(item):gmatch("[^_%s]+") do
        -- Two capitals before the next word, not one. The single-capital form
        -- turned "AIcore" into "A Icore" while the readout above the list, on
        -- the same screen, called it AIcore. A run is what the rule was for:
        -- HPMedicine still becomes HP Medicine.
        chunk = chunk:gsub("(%l)(%u)", "%1 %2"):gsub("(%u%u)(%u%l)", "%1 %2")
        out[#out + 1] = chunk
    end
    local name = table.concat(out, " ")
    if name == "" then return tostring(item) end
    return name
end

local function fit_name(text, chars)
    text = tostring(text)
    if #text <= chars then return text end
    -- Trailing space stripped before the dots. Cutting on a word boundary
    -- left "Baked Meat Chicken .." against "Baked Meat Grass Ma..", so the
    -- gap looked like a typo in some rows and not others.
    return (text:sub(1, chars - 2):gsub("%s+$", "")) .. ".."
end

-- One item as a row: a left rail, its icon, its name, and how many are in
-- storage. The rail carries two things that never collide - the cursor, and
-- whether this item already has a rule - because the cursor is somewhere else
-- whenever you are reading the rail for the other reason.
local function list_row(key, at, item, have, top, limited)
    local col = at % LIST_COLS
    local row = math.floor(at / LIST_COLS)
    local px = PAD + col * (LIST_W + LIST_GUTTER)
    local py = top + row * LIST_PITCH

    -- The row itself is the target. Its hit key owns no text - the name is
    -- drawn under "n:"..key - so before this the only hoverable part of the
    -- row was the icon, and a row still waiting for its icon had none at all.
    slab(key, px, py, LIST_W, LIST_H, TILE_BG, true)
    tile_face[key] = stripes[key]

    -- The rail says three things at once without any of them fighting: it is
    -- wider under the pointer, cyan where the cursor is, green where a rule
    -- already exists. Width is the hover channel because no fill dark enough
    -- to sit below the selection can be told apart from the panel behind it.
    slab("rail:" .. key, px, py,
        (hover_key == key) and RAIL_W_HOT or RAIL_W, LIST_H,
        (row_is_current(key) and ACCENT)
            or (limited and RULE_RAIL)
            or TILE_BG)

    picture(key, px + 8, py + math.floor((LIST_H - LIST_ICON) / 2), LIST_ICON,
        item, item .. (icons.ready(item) and "+" or "-"))

    -- The name takes whatever the count is not using.
    --
    -- A fixed budget cut every name to sixteen characters, which on the full
    -- list produced three rows reading "Baked Meat Ice.." that could not be
    -- told apart - the exact failure the names were added to fix. Most items
    -- on that list are not in storage at all and so have no count, and their
    -- names should have the whole row.
    local count = have > 0 and group_digits(have) or nil
    local room = LIST_COUNT_R - LIST_NAME_X
    if count then room = room - text_w(count, 14, DIGIT_W) - 10 end

    -- Green while a rule already exists, so the rail and the name agree.
    text_at("n:" .. key, px + LIST_NAME_X, py + 7,
        fit_name(pretty_name(item), math.max(6, math.floor(room / (15 * GLYPH_W)))),
        limited and "atlimit" or "item", 15, true)

    if count then
        text_at("q:" .. key, px + right_x(LIST_COUNT_R, count, 14, DIGIT_W),
            py + 8, count, "limit", 14, true)
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
-- Assigns the forward-declared local above; do not add "local" here.
styled_boxes = {}

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
        st.BackgroundColor = {
            -- The filter field wears the same inset well as the limit
            -- fields. As FIELD_BG it sat at 1.16 against the panel, so its
            -- own boundary was nearly invisible, and UMG's hint colour - the
            -- one part of this widget whose colour cannot be set - measured
            -- 1.88 against it, well under the 3:1 that any visible thing
            -- needs. Darkening what CAN be set fixes both: the boundary reads
            -- at 2.2 and the hint at 3.2.
            SpecifiedColor = (which == "ceiling") and CEILING_BG or FIELD_WELL,
            ColorUseRule = 0,
        }

        -- Only the background. The four foreground colours an
        -- EditableTextBox carries were all set and none of them moved the
        -- text, so they are not pretended at here.
        -- Offered, not required. It refuses on this build and the field is
        -- already dark by the time it does.
        pcall(function() box:SetStyle(st) end)
    end)

    -- The WIDGET's own setter, which is not one of the four struct fields
    -- that were tried and did nothing. Worth one call: if it lands, the
    -- ceiling box can carry dark text on its pale field instead of the
    -- near-invisible mid grey it defaults to. A missing method is a Lua
    -- error, which pcall does catch - unlike an access violation, which it
    -- never could - so this cannot cost anything but the attempt.
    -- The font size, which is what was actually clipping the digits.
    --
    -- set_size works on a TextBlock's own .Font; an EditableTextBox keeps
    -- its font inside the style struct instead, so it kept UMG's default 24
    -- while the row around it drew at 17. A 24pt line does not fit a 30 pixel
    -- box, so the number showed its top two thirds and had its feet cut off -
    -- growing the box only moved where the cut fell.
    pcall(function()
        local st = box.WidgetStyle
        if st == nil then return end
        if st.TextStyle ~= nil and st.TextStyle.Font ~= nil then
            st.TextStyle.Font.Size = ROW_PT
        end
        if st.Font ~= nil then st.Font.Size = ROW_PT end
        pcall(function() box:SetStyle(st) end)
    end)

    local fore = (which == "ceiling")
        and { R = 0.06, G = 0.08, B = 0.11, A = 1.00 }
        or { R = 0.90, G = 0.93, B = 0.97, A = 1.00 }
    local ok_fore = pcall(function() box:SetForegroundColor(fore) end)

    log.say("text field " .. which .. ": " ..
        ((which == "ceiling") and "pale field" or "dark well") ..
        ", SetForegroundColor " .. (ok_fore and "took" or "refused"))
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
        -- Below the text layer, not above it.
        --
        -- UMG keeps a field's hint colour in the one part of the style struct
        -- this build will not let us write, and that hint measured 2.20
        -- against the field. Darkening the field cannot rescue it: against
        -- that grey, pure black only reaches 3.25. So the panel draws its own
        -- placeholder instead, which means the box has to sit UNDER the text
        -- layer rather than over it. Nothing else overlaps the field, so
        -- nothing else is affected.
        pcall(function() slot:SetZOrder(8996) end)
        pcall(function() search_box:SetVisibility(0) end)
        style_box(search_box, "filter")
    end

    local slot
    pcall(function() slot = search_box.Slot end)
    if alive(slot) then
        pcall(function()
            slot:SetPosition({ X = X + ROW_INSET, Y = Y + row * LINE })
        end)
        -- 30 cut the descenders off its own hint text. A field that clips the
        -- word "type" is not a field anybody trusts to hold what they typed.
        -- As wide as the grid it filters. It ran the full panel width while
        -- the tiles stopped well short, so it overhung the thing it acts on.
        -- The same width as the bars beneath it. Sized to the grid, it
        -- stopped 176 pixels short of them and left a dead gutter down the
        -- right of every picker screen.
        pcall(function()
            slot:SetSize({ X = ROW_W, Y = SEARCH_H })
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
        -- Exactly the well's footprint, from the same constants the well is
        -- drawn from. It used to be 210 wide at COL_CAP - 6, so a box for a
        -- four digit number ran 90 pixels past the LIMIT column and sat on
        -- top of PALS - the row read "8000  Stopped" with the two overlapping
        -- and neither belonging to the box.
        -- The band's full height, not four pixels short of it.
        --
        -- An EditableTextBox adds its own padding around the text, so a 26
        -- pixel box holding 17pt digits clipped them across the middle - the
        -- number showed its top half and nothing else. It matches the well
        -- exactly, and the well grew with it.
        pcall(function()
            slot:SetPosition({
                X = X + COL_CAP - WELL_INSET,
                Y = Y + editing.row * LINE - 3,
            })
        end)
        pcall(function() slot:SetSize({ X = WELL_W, Y = ROW_H }) end)
        -- Right aligned, to sit where the number it replaces sat. The digits
        -- started hard against the left edge of a box drawn around a column
        -- whose values are set from their right.
        pcall(function() amount_box:SetJustification(2) end)
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
    if focused then
        editing.had_focus = true
        return
    end

    -- Not focused, and never has been.
    --
    -- The box is reused rather than rebuilt, so it still holds the previous
    -- edit's text, and there are frames between the editor opening and the
    -- keyboard actually arriving. Committing in that window reads that stale
    -- text and writes it as the new limit: a Wood ceiling of 8000 came back
    -- as 7500 one second after the box opened, with nothing typed and nothing
    -- said. A limit changing on its own is the same failure that once wiped a
    -- Stone ceiling of 15000, so it is closed rather than narrowed - nothing
    -- commits until the box has genuinely held the keyboard at least once.
    --
    -- Abandoned, not committed, if the keyboard never arrives at all. An edit
    -- that never took focus cannot contain anything worth saving.
    if not editing.had_focus then
        editing.waiting = (editing.waiting or 0) + 1
        if editing.waiting > 30 then
            log.say("the ceiling box never took the keyboard, so the " ..
                workdefs.label(editing.work) .. " limit on " ..
                editing.item .. " is unchanged")
            editing = nil
            pcall(function() amount_box:SetVisibility(1) end)
        end
        return
    end

    local want = tonumber((text:gsub("[^%d]", "")))
    local job, item = editing.work, editing.item
    editing = nil
    pcall(function() amount_box:SetVisibility(1) end)

    -- Nothing usable typed means leave the rule alone.
    --
    -- This commits when the box stops holding the keyboard, which is what
    -- makes "type it and click away" work, but it also fires on a focus lost
    -- for any other reason. A real limit of 15000 was overwritten with
    -- 1505500 and then with 1 inside six seconds that way, which switched
    -- Mining off entirely and said nothing about it.
    --
    -- So an empty or unreadable box now cancels, and zero cancels too rather
    -- than deleting the rule: deleting is what Remove is for, and Remove asks
    -- first. An edit should never be able to destroy more than it was aimed
    -- at.
    if want == nil or want <= 0 then
        log.say("nothing typed, the " .. workdefs.label(job) .. " limit on " ..
            item .. " is unchanged")
        return
    end

    caps.set(job, item, want)
    M.wants_pass = true

    -- Says so when the new limit is already passed, because that stops the
    -- job the moment it is set and the panel should not let that happen
    -- quietly.
    local have = (stock_totals(cfg) or {})[item] or 0
    if want < have then
        log.say(string.format(
            "%s %s limit set to %d, which is below the %d in storage, so %s stops now",
            workdefs.label(job), item, want, have, workdefs.label(job)))
    else
        log.say(string.format("%s %s limit set to %d",
            workdefs.label(job), item, want))
    end
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

-- Assigns the forward-declared local above; do not add "local" here.
function stock_totals(cfg)
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
    -- Starts at the backdrop's own top edge, not three pixels below it. The
    -- backdrop is placed at Y - PAD and this band was placed at Y - 3, so a
    -- PAD-3 = 15 pixel strip of body tone sat above the header and read as a
    -- render seam along the top of the panel. The height grows by the same
    -- amount so the band still ends where it did.
    slab("tabbar", -PAD, -PAD, W + PAD * 2, ROW_H + PAD - 3, CHROME_BG)

    local tabs = {
        { key = "tab_rules", label = "RULES", mode = "list" },
        { key = "tab_new",   label = "ADD",   mode = "item" },
    }

    local x = PAD
    for _, tab in ipairs(tabs) do
        local on = (active == tab.mode)
        hit(tab.key, { kind = "tab", mode = tab.mode })

        -- A padded region, and it IS the target. The word alone was about
        -- fifty pixels of a thirty four pixel tall bar, so clicking a tab
        -- meant hitting three capitals exactly; the pointer landing a few
        -- pixels off found the chrome behind them and nothing happened.
        slab("tabhit:" .. tab.key, x - 12, -6, #tab.label * 20 * 0.83 + 24,
            TAB_H, INVISIBLE, true)
        tile_face[tab.key] = stripes["tabhit:" .. tab.key]

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
    slab("tabhit:close", W - 102, -6, 5 * 20 * 0.83 + 24, TAB_H, INVISIBLE, true)
    tile_face["tab_close"] = stripes["tabhit:close"]
    line("tab_close", 0, W - 90, "CLOSE", "dim", 20)

    -- What this is and what it does, which the panel never said. Opening it
    -- cold gave you two tabs, a caption about clicking things, and numbers
    -- with no stated meaning.
    -- Not "Pal Work Priority". Palworld already has work suitability and
    -- priority, which is about which job a Pal picks; nothing on this screen
    -- ranks anything. The mod keeps its name, the screen says what it does.
    -- Nudged down out of the tab bar. At its plain row-1 position the cap
    -- height of the title sat four pixels under the active tab's underline,
    -- so the two read as one stacked block instead of a header and a bar.
    line("title", 1, PAD, "Production Limits", "title", 22, TITLE_DROP)
    line("why", 2, PAD,
        "Your Pals stop a job once base storage reaches the limit you set.",
        "dim", 14, TITLE_DROP)

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

-- Grouped in threes, because the only thing these two columns are for is
-- deciding which of two numbers is bigger. "16562" against "15000" makes a
-- reader count digit positions; "16,562" against "15,000" does not.
local function short_amount(n)
    n = math.floor(tonumber(n) or 0)

    -- Past a million the separators stop earning their width and the column
    -- would start pushing into the one beside it.
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    end
    return group_digits(n)
end

local function draw_list(cfg, totals)
    local rules = rule_list(cfg)

    draw_tabs("list")
    local row = 3

    -- The instruction line doubles as the editor's label. A text field that
    -- appears over a number with no caption leaves you guessing which of the
    -- two numbers it replaces, and "click a job to change it" is not the
    -- sentence you need while typing.
    --
    -- It borrows the subtitle's row rather than reserving one of its own. A
    -- dedicated row meant a whole empty LINE above the table on every normal
    -- visit - 34 pixels of dead air carrying a sentence that only appears
    -- while a number is being typed - and collapsing it instead would have
    -- shifted the table out from under the row you had just clicked. The
    -- general explanation is the one thing you do not need while typing, so
    -- it steps aside.
    if editing ~= nil then
        line("why", 2, PAD,
            "Setting the " .. workdefs.label(editing.work) .. " ceiling for " ..
            editing.item .. "  |  Type a number, then click anywhere to save",
            "action", 14)
    end

    -- Names both numbers. Without this the pair reads as progress towards a
    -- goal, which is the opposite of what it means.
    if #rules > 0 then
        -- The two leading spaces match the marker slot every hit row
        -- carries, so JOB sits over Lumbering instead of thirteen pixels
        -- left of it.
        -- Sits over the job names exactly, because both are placed from the
        -- same constant. It used to be the string "  JOB" placed at PAD, and
        -- two spaces at 12pt are not two spaces at 17pt, so the heading came
        -- out five pixels left of the data it headed.
        line("h_job",  row, PAD + MARK_W, "JOB",    "faint", 12)
        line("h_item", row, COL_ITEM, "ITEM",       "faint", 12)
        -- Numeric headings are CENTRED over their column, not set from its
        -- right edge.
        --
        -- Words align left and numbers align right, which is what makes a
        -- column of figures comparable at a glance. That leaves the heading
        -- with no fixed edge to meet: the values under it are right aligned
        -- from a computed width, and the heading's own width is computed the
        -- same way, so any error in either estimate shows up as the two
        -- disagreeing - which is exactly what "some text is left bound and
        -- some is right bound" looked like from the outside. Centring halves
        -- the error and makes it symmetric, and a centred heading over a
        -- right-aligned column is a normal table.
        line("h_have", row,
            centre_x(COL2, COL2_R - COL2, "IN STORAGE", 12, CAPS_W),
            "IN STORAGE", "faint", 12)
        line("h_cap",  row,
            centre_x(COL_CAP - WELL_INSET, WELL_W, "LIMIT", 12, CAPS_W),
            "LIMIT", "faint", 12)
        -- PALS, not STATUS. The column sits 780 pixels right of the job it
        -- describes with three number columns in between, so "STATUS" had
        -- three things it could plausibly be the status OF - the job, the
        -- item, or the rule - and readers picked the rule. Naming the subject
        -- in the heading makes "Stopped" mean the pals stopped.
        line("h_st",   row, COL_DONE, "PALS",       "faint", 12)
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

            stripe(key, row, PAD, ROW_W)

            -- One caret for the whole row, in the slot the layout already
            -- reserved for it. Every column after this one is placed from a
            -- fixed x and never moves, whether the row is current or not.
            line("mk" .. i, row, PAD,
                row_is_current(key, "amt" .. i, "cap" .. i, "del" .. i)
                    and ">" or "",
                "hover", ROW_PT)
            -- Cyan only when it can be changed.
            --
            -- The job cycled through all fourteen work types, so a Wood rule
            -- could be walked onto Watering - a job that cannot make wood -
            -- and the rule quietly stopped meaning anything. Most items have
            -- exactly one job that produces them, and for those this is a
            -- fact about the item rather than a control, so it stops wearing
            -- the colour every control on this panel uses.
            -- Guarded: this module hot-reloads and workdefs does not, so a
            -- panel dropped in after workdefs gained works_for_item talks to
            -- the old one, where the field is nil. A nil call here takes
            -- draw_list down and the panel comes up as a bare header. Third
            -- time this shape has bitten; it costs one line to refuse it.
            local works = workdefs.works_for_item
                and workdefs.works_for_item(rule.item) or {}
            local choosable = #works > 1
            line(key, row, PAD + MARK_W, workdefs.label(rule.work),
                choosable and "action" or "item", ROW_PT)
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
            -- Amber once storage has reached the limit, neutral while it is
            -- under. The one fact a reader opens this panel for - am I over
            -- or under - was left entirely to mental arithmetic between two
            -- identically coloured numbers 170 pixels apart.
            local have_text = short_amount(have)
            line("amt" .. i, row, right_x(COL2_R, have_text, ROW_PT, DIGIT_W),
                have_text, met and "over" or "limit", ROW_PT)

            -- A well behind the number, so it looks like something you can
            -- type into.
            --
            -- The limit was styled as plain text, indistinguishable from the
            -- storage figure beside it that cannot be changed, which is why
            -- the panel needed a line of prose telling you to click it. An
            -- instruction line explaining where to click is the design
            -- admitting its controls do not look like controls.
            if not editing_this then
                -- The well is the click target, not the digits inside it.
                -- It is drawn to say "type here" and was not the thing that
                -- could be pressed: a four digit number is about a fifty
                -- pixel target inside a 118 pixel box.
                slab("capbox" .. i, COL_CAP - WELL_INSET, row * LINE - 3,
                    WELL_W, ROW_H, FIELD_WELL, true)
                tile_face["cap" .. i] = stripes["capbox" .. i]
            end

            local cap_text = editing_this and "" or short_amount(rule.amount)
            line("cap" .. i, row, right_x(COL_CAP_R, cap_text, ROW_PT, DIGIT_W),
                cap_text, "title", ROW_PT)

            -- AT LIMIT, not PAUSED, and not amber.
            --
            -- PAUSED reads as "this rule is switched off" when it means "this
            -- rule fired". The most likely misreading was the exact opposite
            -- of the truth. Amber made it worse: it is the caution colour
            -- everywhere else in games, so two working rules looked like two
            -- warnings.
            -- Says what is actually true, with the number.
            --
            -- Both rows read AT LIMIT while storage stood 557 and 1500 above
            -- the limit, and still climbing. To anybody reading it cold that
            -- is not a status, it is evidence the mod does not work. A
            -- ceiling stops new work; it cannot un-chop wood already in a
            -- chest, so being over is normal and the panel has to say so.
            -- Kept short on purpose. "OVER BY 1518" ran into Remove, and the
            -- panel cannot simply widen: at 1050 its right edge already sits
            -- a few pixels from the game's own Base Info panel, so growing it
            -- trades one collision for a worse one.
            -- What the job is doing, in a word.
            --
            -- OVER 651 restated arithmetic already sitting two columns to its
            -- left, and AT LIMIT described the storage rather than the job
            -- while claiming a precision it did not have. The JOB column is
            -- right there, so this column reads as a sentence about it:
            -- Lumbering ... Stopped.
            -- What the PALS are doing, which is why the column is headed PALS.
            --
            -- This said "Paused", and a paused rule is a rule that is switched
            -- off, so the most likely reading was the exact inverse of the
            -- truth: it means the rule fired and is enforcing right now. The
            -- word is about the pals, the heading says so, and neither reading
            -- is available any more.
            --
            -- The state itself comes from the scheduler rather than from
            -- `have >= rule.amount`. A work type stops only when every item
            -- limited for it is at its ceiling, so a row can be over its own
            -- limit while its job carries on for something else - that is
            -- "Waiting", and it is the only way to find out that a Stone
            -- limit is doing nothing because Ore is still short.
            -- Guarded because panel.lua hot-reloads and scheduler.lua does
            -- not: between dropping in a new panel and restarting the game,
            -- the running scheduler is still the old one and does not export
            -- this yet. Falling back to the per-item answer is wrong in the
            -- multi-item case, but it is the answer this row gave before, and
            -- a wrong word beats a nil call that takes the whole refresh out.
            local capped
            if scheduler.cap_state then
                capped = scheduler.cap_state(cfg, rule.work, totals)
            else
                capped = met
            end

            local status, tone
            if cfg.enabled == false then
                -- Both of these mean no rule on this screen is doing
                -- anything, and both used to render as "Working", which is a
                -- flat untruth the panel had no other way to correct.
                --
                -- "Rule off" rather than "Off", because "Off" and "Stopped"
                -- are the same word in plain English and nothing would have
                -- told a reader that one means "hit its limit" and the other
                -- means "not switched on". "Testing" rather than "Dry run",
                -- which is a developer's phrase no player is going to read as
                -- "would stop, but nothing is being sent".
                status, tone = "Rule off", "dim"
            elseif cfg.dry_run then
                status, tone = "Testing", "dim"
            elseif capped then
                status, tone = "Stopped", "over"
            elseif met then
                status, tone = "Waiting", "unmet"
            else
                status, tone = "Working", "working"
            end
            line("done" .. i, row, COL_DONE, status, tone, ROW_PT)

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
            -- A surface of its own, tinted towards red.
            --
            -- Remove had no fill at all: a scanline across the row ran
            -- unbroken from the limit well to the panel edge, so the only
            -- thing separating "Paused" from "Remove" was 48 pixels of gap
            -- and a slight difference in warmth. Two pale warm words at the
            -- same size and weight read as a matched pair of labels, and one
            -- of them deletes a rule.
            -- Ends where the row ends. It used to run 12 pixels past both
            -- the row band and the table, so the one control that destroys
            -- something looked pasted on top of the list rather than in it.
            slab("delbox" .. i, COL3 - 10, row * LINE - 1,
                (W - ROW_INSET - ROW_PAD) - (COL3 - 10), ROW_H - 4,
                asking and DANGER_WELL_ON or DANGER_WELL, true)
            tile_face["del" .. i] = stripes["delbox" .. i]
            -- Centred in the box, not started at its left edge. "Remove"
            -- is wider than the space that was left for it, so the word ran
            -- out past the red surface and past the row itself.
            local del_text = asking and "Sure?" or "Remove"
            local del_x, del_w = COL3 - 10, (W - ROW_INSET - ROW_PAD) - (COL3 - 10)
            line("del" .. i, row, centre_x(del_x, del_w, del_text, ROW_PT),
                del_text, asking and "danger" or "quiet", ROW_PT)

            if choosable then
                hit(key, { kind = "job", rule = rule, works = works })
            end
            -- On the limit, which is the number being edited, the number the
            -- well is drawn behind and the number the typing box opens over.
            -- It was registered on the storage figure 170 pixels to the left:
            -- the well said "click here" over something that was not
            -- clickable, and clicking the thing that was opened a box
            -- somewhere else entirely.
            hit("cap" .. i, { kind = "rule", rule = rule, row = row })
            hit("del" .. i, { kind = "drop", rule = rule })
            row = row + 1
        end
        row = row + 1
    end

    -- The one action on this screen that creates something, so it is the one
    -- that gets the filled treatment. "+ Add a rule", "Show every item with a
    -- job" and "< Back" were the same bar in the same tone with the same cyan
    -- label: a create, a filter and a navigation, visually indistinguishable.
    hit("new", { kind = "new" })
    stripe("new", row, PAD, ROW_W, PRIMARY_BG, true)
    tile_face["new"] = stripes["new"]
    -- Glyph and label in fixed slots, so all three action rows start their
    -- words on one edge. Baked into single strings before, where "[x]   ",
    -- "+   " and "<   " are three different widths and the labels came out
    -- ten and thirty pixels apart.
    line("mk_new", row, PAD, row_is_current("new") and ">" or "", "hover", ROW_PT)
    line("g_new", row, PAD + MARK_W, "+", "primary", ROW_PT)
    line("new", row, PAD + MARK_W + GLYPH_SLOT, "Add a rule", "primary")

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
    -- Work Suitability Deforest and friends are the game's own trait tokens,
    -- not things a base produces. They match "deforest" in the job table and
    -- walked straight into the picker.
    "suitability", "passive", "skillcard", "skill_",
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

-- What the picker is showing, before paging.
local function build_picker_source(totals)
    -- Searching casts wider than the base holds, but still only over things
    -- the base could make. Asked for more rows than before, because the
    -- filter takes most of them away again.
    if search_text ~= "" then
        -- Searching casts wider than the shelf, but it does not flip the
        -- toggle. Reporting `true` here made the button relabel itself to
        -- "Show only what I have" the moment anything was typed, so the user
        -- appeared to have changed a mode they never touched, and the results
        -- filled with items they own none of.
        return only_producible(items.search(search_text, 400)), show_all
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

-- The same list, remembered between frames.
--
-- Nothing above changes within a frame, or between frames while the search
-- box, the toggle and the stock figures all stand still - but it was rebuilt
-- from scratch ten times a second, walking the whole item table and filtering
-- it, which is around 180,000 substring searches per frame.
--
-- The stock figures count by table IDENTITY, not by their contents: the
-- scheduler builds a fresh pass_totals every pass and publishes it whole, so
-- the numbers cannot change without the table changing with them.
--
-- The table itself is held rather than its address. An address is not a safe
-- key: once the old totals table is unreferenced it can be collected, and a
-- later table can be allocated at the same address, which would match a key
-- it has nothing to do with and serve a stale list. Holding the reference
-- makes that impossible, and costs one table. It is a plain map of strings to
-- numbers, not an engine object, so there is no wrapper-age question here.
-- Both forward-declared above, so ensure_root can drop them on a rebuild.
picker_key = nil
picker_hit = nil

local function picker_source(totals)
    if picker_key ~= nil
        and picker_key[1] == search_text
        and picker_key[2] == show_all
        and picker_key[3] == totals
    then
        return picker_hit[1], picker_hit[2]
    end

    local list, everything = build_picker_source(totals)
    picker_key = { search_text, show_all, totals }
    picker_hit = { list, everything }
    return list, everything
end

local function draw_item_picker(cfg, totals)
    icons.new_frame()

    local source, everything = picker_source(totals)
    local pages = math.max(1, math.ceil(#source / LIST_PER_PAGE))
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

    -- Ours, in a colour the panel controls, and only while the field is
    -- empty. The bar was otherwise flat dark with no border and no words,
    -- which does not read as somewhere you can type - and the field is the
    -- one thing that makes 233 items findable.
    --
    -- Placed from the FIELD's own box, not from line()'s row formula. The
    -- field is 36 tall and sits flush on the row's top edge while a row is 30
    -- tall and inset three, so a hint placed by row sat about eight pixels
    -- high in it - which is what "not properly in the middle" was.
    text_at("hint", ROW_INSET + 13,
        4 * LINE + (SEARCH_H - ROW_PT * 1.35) / 2 - ROW_PT * 0.13,
        search_text == "" and "Search for an item to limit" or "",
        "hint_on_field", ROW_PT, true)

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
    -- Always, not only on an empty field. This sentence used to disappear
    -- the moment anything was typed, which is precisely when somebody is
    -- about to click a tile for the first time.
    caption = caption .. "   |   Click an item to limit it"
    line("sub", 5, PAD, caption, "dim", 13)

    local top = 6 * LINE
    local from = page * LIST_PER_PAGE + 1

    grid_from, grid_count = #order + 1, 0

    -- Which items already have a rule, so the grid can say so.
    local has_rule = {}
    for _, r in ipairs(rule_list(cfg)) do has_rule[r.item] = true end

    for i = from, math.min(from + LIST_PER_PAGE - 1, #source) do
        local id = source[i]
        local key = "pick" .. (i - from)

        list_row(key, i - from, id, totals[id] or 0, top, has_rule[id])
        hit(key, { kind = "item", item = id })
        grid_count = grid_count + 1
    end

    -- Where the grid ends, measured from the tiles actually drawn rather than
    -- from the page size. Reserving all five rows for ten items left the
    -- panel with an empty half and everything below it stranded at the
    -- bottom of a box nothing filled.
    -- The grid reserves its whole page whether or not it is full.
    --
    -- Sized to its contents, toggling "show every item" grew the list from
    -- four rows to six and moved everything under it down 136 pixels - so the
    -- second click of a double-click landed on a list row and silently made a
    -- rule, and collapsing it again moved the bar out from under the pointer
    -- entirely, sending the click to the world behind the panel. A control
    -- that moves when you press it is a trap, and this one changed what the
    -- next click did.
    local row = 6 + math.ceil((LIST_ROWS * LIST_PITCH) / LINE) + 1

    -- The pager keeps its row even on a single page.
    --
    -- Drawn only when there was more than one page, it took its 34 pixels
    -- with it - so the two buttons below moved every time the list crossed
    -- eighteen items, which is exactly what toggling "show every item" does.
    -- Reserving the row costs one empty line and makes the two controls at
    -- the bottom of this screen sit still, whatever the list is showing.
    -- Two buttons with a surface each, and each one clickable all over.
    --
    -- These were four separate words with a hit on two of them, so Previous
    -- answered only on its arrow and Next only on its label - and a disabled
    -- page rendered in the same grey as the body text, which made "you are on
    -- the last page" look like a caption rather than a spent control. Now
    -- they are shaped like the other buttons on this screen: a bar you can
    -- press anywhere, tinted when it does something and flat when it does not.
    local PAGE_W = 200
    local can_prev = page > 0
    local can_next = page < pages - 1

    if pages > 1 then
        if can_prev then hit("prev", { kind = "page", by = -1 }) end
        if can_next then hit("next", { kind = "page", by = 1 }) end

        slab("prevbox", PAD, row * LINE - 1, PAGE_W, ROW_H - 4,
            can_prev and BUTTON_BG or ROW_BG, can_prev)
        slab("nextbox", PAD + PAGE_W + 12, row * LINE - 1, PAGE_W, ROW_H - 4,
            can_next and BUTTON_BG or ROW_BG, can_next)
        if can_prev then tile_face["prev"] = stripes["prevbox"] end
        if can_next then tile_face["next"] = stripes["nextbox"] end

        line("prev", row, PAD + 16, "<   Previous",
            can_prev and "action" or "spent", ROW_PT)
        line("next", row, PAD + PAGE_W + 28, "Next   >",
            can_next and "action" or "spent", ROW_PT)
        line("pageno", row, PAD + PAGE_W * 2 + 40,
            string.format("page %d of %d", page + 1, pages), "dim", 13)
    else
        -- The row is kept even on a single page, or the two buttons below it
        -- move every time the list crosses eighteen items.
        line("prev", row, PAD + 16, "", "dim", ROW_PT)
        line("next", row, PAD + PAGE_W + 28, "", "dim", ROW_PT)
        line("pageno", row, PAD + PAGE_W * 2 + 40, "", "dim", 13)
    end
    row = row + 1

    -- Rows, like every other action in this panel. These were 20pt text
    -- floating in dead space below the grid, which made the two most
    -- important controls on the screen look like a caption. "+ add a rule"
    -- across in the rules list is the same kind of thing and reads as a
    -- control because it sits on a stripe.
    -- A checkbox with a fixed label, not a label that swaps.
    --
    -- It read "Show every item with a job" in one state and "Show only what I
    -- have" in the other, with nothing else changing, so there was no way to
    -- tell whether the words described what you were looking at or what
    -- pressing it would do. A stable label plus a box that fills says both at
    -- once, and the box survives being read by somebody who cannot separate
    -- the two label colours.
    hit("all", { kind = "toggle_all" })
    stripe("all", row, PAD, ROW_W, BUTTON_BG, true)
    tile_face["all"] = stripes["all"]
    line("mk_all", row, PAD, row_is_current("all") and ">" or "", "hover", ROW_PT)
    line("g_all", row, PAD + MARK_W,
        everything and "[x]" or "[  ]", "action", ROW_PT)
    line("all", row, PAD + MARK_W + GLYPH_SLOT,
        "Show every item with a job", "action", ROW_PT)
    row = row + 1

    hit("back", { kind = "back" })
    stripe("back", row, PAD, ROW_W, BUTTON_BG, true)
    tile_face["back"] = stripes["back"]
    line("mk_back", row, PAD, row_is_current("back") and ">" or "", "hover", ROW_PT)
    line("g_back", row, PAD + MARK_W, "<", "action", ROW_PT)
    line("back", row, PAD + MARK_W + GLYPH_SLOT, "Back", "action", ROW_PT)

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
        local w = tile_face[key] or blocks[key] or images[key]
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

    -- was_sel is set after the draw instead, once `order` is this frame's.
    was_hit = hits
    hits, order, used = {}, {}, {}

    local ts = os.clock()
    local totals = stock_totals(cfg)
    perf_stock = os.clock() - ts

    local td = os.clock()
    local rows = redraw(cfg, totals)
    perf_draw = os.clock() - td

    -- Clamped after the draw, since the row count is only known then.
    if want_first_row and #order > tab_hits then
        want_first_row = false
        sel = tab_hits + 1
    end
    if sel > #order then sel = #order end
    if sel < 1 then sel = 1 end

    -- Taken from the order just drawn, with the sel just clamped, rather than
    -- from the previous frame's order. On a screen that is not changing shape
    -- the two are the same key; on a tab switch, a page turn, or the frame a
    -- rule is added, the old order named something that is no longer on
    -- screen and the cursor blinked out for one frame.
    was_sel = order[sel]

    -- Centred vertically from what was actually drawn.
    --
    -- The height is only known once the screen has been drawn, so a screen
    -- that changed height was drawn at the old offset while its backdrop was
    -- sized for the new one. That is the gap between the panel and its
    -- contents in the switch from ADD back to RULES. Drawing it again is
    -- cheaper than living with it, and only happens on the frame the height
    -- actually changes rather than every frame.
    -- Anchored by its top edge, not centred.
    --
    -- Centring meant the panel's height decided where its header sat, so
    -- switching from the rules list to the picker moved the tab bar a hundred
    -- pixels up: the tab you just clicked jumped out from under the pointer,
    -- and clicking again in the same place hit empty panel.
    -- Y is set from TOP_Y at load and nothing else ever writes it, so the
    -- redraw-on-move branch that used to sit here could not run. It was left
    -- over from the centred layout, where the height decided the offset.

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
    if name ~= "item" and name ~= "list" then return false end
    -- sel lands on the first row of the new screen, not on 1.
    --
    -- It used to set sel = tab_hits + 1 and then, two lines later,
    -- unconditionally overwrite it with 1 - which is the RULES tab. Both the
    -- selection tint and the "> " marker are suppressed on tabs on purpose,
    -- so parking the cursor there means no cursor is drawn anywhere. Clicking
    -- a tab with the mouse goes through M.apply and gets this right; every
    -- screen change driven through the command channel did not, which is why
    -- the panel looked like it had no keyboard cursor at all.
    mode, page = name, 0
    want_first_row = true
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
        pcall(function() scheduler.want_totals = false end)
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

    -- The pass measures storage for us while this is open, so the panel never
    -- has to sweep containers itself. Without it, a base with no rules set
    -- left last_totals empty and the fallback scan below ran every fifteen
    -- seconds on the drawing thread.
    pcall(function() scheduler.want_totals = true end)

    want_first_row = true

    log.say("work rules open, Ctrl+F9 again to close")
end

function M.reset()
    M.open = false
    pcall(function() scheduler.want_totals = false end)
    scanned_once, scanned_at = nil, 0
    root, root_tree, backdrop = nil, nil, nil
    blocks, drawn, hits, used = {}, {}, {}, {}
    stripes, placed, search_box, search_text, want_focus = {}, {}, nil, "", false
    amount_box, editing, edit_focus = nil, nil, false
    tile_face = {}
    styled_boxes = {}
    images, grid_from, grid_count = {}, 0, 0
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
        local w = tile_face[key] or blocks[key] or images[key]
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

        -- Up and down cross a whole row of the list. Only while the
        -- selection is among them: on the buttons underneath, a row is one
        -- step.
        local at = sel - grid_from
        if grid_count > 0 and at >= 0 and at < grid_count then
            local to = at + (what == "up" and -LIST_COLS or LIST_COLS)
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
        want_first_row = true
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

        -- Only among the jobs that could actually produce this item. The
        -- cycle used to run the whole ORDER list, so two clicks on a Stone
        -- rule landed it on Oil Extraction and the ceiling stopped firing,
        -- with nothing on screen to say the pairing was nonsense.
        local works = what.works
            or (workdefs.works_for_item and workdefs.works_for_item(rule.item))
            or {}
        if #works < 2 then
            log.say(rule.item .. " is only made by " ..
                workdefs.label(rule.work) .. ", so there is nothing to switch to")
            return false
        end

        local at = 1
        for i, name in ipairs(works) do
            if name == rule.work then at = i break end
        end

        at = at + ((dir < 0) and 1 or -1)
        if at > #works then at = 1 end
        if at < 1 then at = #works end

        local moved = works[at]
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
