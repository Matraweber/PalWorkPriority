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

-- The guild this panel speaks for.
--
-- Every rule the panel reads or writes is scoped to it, so a player editing
-- limits on a shared server changes their own guild's bases and nothing else.
-- Before this, one rule set covered the whole machine and a ceiling set by one
-- guild suspended that work at every base on the server.
--
-- Resolved per call rather than kept. It is three engine reads, the panel
-- already pays more than that on every refresh, and holding the objects across
-- frames is the use-after-free this codebase is built to avoid. nil when the
-- player is in no guild, which caps treats as "no scope" and refuses to write
-- under rather than widening to everyone.
--
-- Guarded like every other call from here into a module that does NOT
-- hot-swap. palapi is one of those: reload a panel that expects my_guild into
-- a session whose palapi predates it and the call is a nil, thrown once per
-- row, once per frame, for the rest of the session. Answering nil instead
-- costs the reload path its guild scope until the next restart, which caps
-- reads as "no scope" and refuses to write under rather than widening.
local function mine()
    if not api.my_guild then return nil end
    return api.my_guild()
end

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
local rows = {}                 -- order index -> which visible row it belongs to

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
local pinned = {}               -- item id -> true, a pin widget holds its icon
local pin_count = 0

-- Rows that live in the blueprint's ScrollBox rather than on the canvas.
--
-- RB.slot is the CanvasPanel for the row being drawn right now, and RB.base
-- the absolute Y that row would have had on the canvas. Every primitive
-- subtracts that base, so callers keep passing the same absolute Y they
-- always did and the row's own widgets land at the top of their own box.
-- Both nil means the canvas, which is every path that is not a hosted rules
-- list, and every path at all when there is no pak.
-- One table, not five locals. panel.lua's main chunk sits at Lua's hard limit
-- of 200 locals per function, and exceeding it breaks only the RELOAD path:
-- loadfile refuses the new chunk, reload.now keeps the old module, and the
-- game carries on running code from before the edit while every file on disk
-- says otherwise. Three changes in a row appeared to do nothing that way.
local RB = {
    hosts = {},            -- row index -> { box = SizeBox, canvas = CanvasPanel }
    slot = nil,            -- the row canvas being drawn into right now
    base = 0,              -- that row's absolute Y on the panel's canvas
    pads = {},             -- list name -> padding last pushed onto its slot

    -- How long one frame may spend showing tiles it has never shown before.
    --
    -- The picker's first draw was 75-104ms: every tile on the page created,
    -- written and pictured in one beat, which is six frames the game did not
    -- get to render. Everything else in a refresh is now under 5ms, so this
    -- is the whole of what was left to feel.
    --
    -- Eight milliseconds is BreedingHelper's number too - its planner scan
    -- takes SCAN_SOFT_SLICE_SECONDS = 0.008 per frame - and it is not a
    -- coincidence: half a 16.7ms frame leaves room for the rest of the
    -- refresh and for the game. A count would have been the easy version and
    -- the wrong one, because what a tile costs depends on whether its picture
    -- is already pinned.
    SLICE = 0.008,
    filled = {},           -- tile key -> the item id that tile is showing
    pending = false,       -- a page stopped mid fill and wants another frame
    draw_t0 = 0,           -- when the current draw started
    cfg = nil,             -- last config handed to refresh, for fill_tick
    -- The shell's chrome rows, in the order the commandlet stacked them into
    -- Body, with the heights it gave them. Everything here sits ABOVE the two
    -- lists, so whichever of them are showing decides where a list begins.
    rows = {
        { "Tabs", 34 }, { "Title", 34 }, { "Sub", 26 }, { "Notice", 22 },
        { "Search", 40 }, { "Caption", 24 }, { "Head", 28 },
    },
    on = {},               -- row name -> drawn into this frame
    base_col = {},         -- slab key -> the base colour its caller passed
    -- When ensure_root last vouched for the widget tree.
    --
    -- hover_tick runs off a 16ms loop and dereferences widgets STORED since
    -- an earlier frame - tile_face, blocks, images - which is the one thing
    -- this codebase forbids without a fresh validation in front of it:
    -- alive() on a freed wrapper is the crash, not a guard against it. The
    -- draw path is safe because ensure_root runs first and drops the tree on
    -- a world change; the loop had no such thing, and got six attempts per
    -- beat instead of one.
    validated = -1,
    -- Where a draw's time actually goes, per primitive. Counted rather than
    -- reasoned about: "it must be the icons" was wrong once already.
    prof = {},
    -- Top left, for widgets inside a row box. The panel's own canvas is
    -- centre anchored, which is what X = -(W/2) exists to undo; a row box
    -- already starts where its row starts, so centre anchoring there put
    -- every column half a row too far right.
    TOPLEFT = { Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } },
}

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

-- What the panel last told the player, and when.
--
-- Everything the panel says went to log.say, which reaches the UE4SS console
-- and priority.log and nothing a player looks at. The most important sentence
-- the mod writes - "that limit is below what you already hold, so this job
-- stops now" - was written to a file. The subtitle already steps aside for the
-- editing caption, so it is the surface that exists; a notice borrows it for a
-- few seconds and then it goes back to explaining the screen.
local notice, notice_at = nil, -1
local NOTICE_FOR = 7.0
local tab_hits = 0              -- how many order entries the tab bar owns

-- A Remove waiting for its second click, and when it started.
local pending_drop = nil
local pending_at = 0
local perf_worst, perf_at = 0, 0
local perf_hover, perf_draw, perf_hits = 0, 0, 0
local perf_stock, perf_blank = 0, 0
-- The setup half of a refresh: the amount box, the root canvas and the
-- backdrop. Unmeasured until a 400ms refresh reported every named bucket at
-- zero, which means the time was somewhere nothing was looking.
local perf_setup = 0

-- How many icons may be resolved in one refresh. Three keeps the worst frame
-- near 40ms while a page still fills inside a fifth of a second.
local ICONS_PER_FRAME = 3
local icon_budget = ICONS_PER_FRAME
-- key -> when an icon that failed to resolve may be tried again.
local icon_retry = {}
-- How long a failed resolve waits before trying again. Short, because the
-- usual reason for failing is that the texture is still loading and will be
-- there within a beat or two; the only cost of asking again is one lookup.
local ICON_RETRY_S = 0.3
-- The same figures, frozen at the moment the worst refresh was seen.
local worst_setup, worst_hover, worst_hits = 0, 0, 0
local worst_stock, worst_draw, worst_blank = 0, 0, 0

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
-- 1050 until the status column had to hold a sentence rather than a word.
--
-- "Stopped at 1" needs about 150 pixels at ROW_PT and STATUS had 132, so it
-- ran under Remove and the reader saw "Stopped at 1" with the 1 half eaten.
-- The panel is what decides how wide the panel is - the shell's backdrop is
-- sized from this at runtime - so widening here widens the whole thing, and
-- COL3 moves with it to hand the difference to STATUS instead of to the
-- right margin.
local W = 1110

-- The blueprint sizes its backdrop from this, so it has to be told before the
-- widget is ever built. Declared here rather than at the top of the file
-- because W is, and luacheck said so before the game had to.
pcall(function() overlay.width = W end)
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
-- Moved right with W, so the 60 pixels the panel gained land in STATUS
-- rather than making the Remove button wider. Remove keeps the 86 it had.
local COL3     = 1012
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
-- Measured from the row band's inset, not the text inset.
--
-- The list was built from PAD while every other surface in the panel - the
-- search field above it, both footer bars below it, the rules rows and the
-- primary button - is built from ROW_INSET, six pixels wider. So the list sat
-- visibly pinched between two wider slabs, top and bottom, on the screen a
-- player spends the most time on, and the whole block stepped six pixels
-- sideways on every tab switch.
local LIST_W       = math.floor((ROW_W - LIST_GUTTER * (LIST_COLS - 1))
                                / LIST_COLS)
local LIST_H       = 36
local LIST_PITCH   = LIST_H + 4
-- Nine, from the space that is actually there.
--
-- At six, the picker wrapped fourteen items into three columns and then left
-- 226 pixels of the panel empty below them - a third of its height - while
-- paging every eighteen items. The layout was arguing with itself: it ran out
-- of width and had height to spare.
--
-- Ten was the first answer and it was wrong. The sum counted the two footer
-- rows and forgot the pager, which sits between them and the grid and holds
-- its row even on a single page. With ten rows the pager was pushed past the
-- bottom of the backdrop entirely: turning on "show every item with a job"
-- drew "< Previous  Next >  page 1 of 7" over the game world, outside the
-- panel, with the HUD visible behind it. Only that screen showed it, because
-- it is the only one with enough items to page.
--
-- Measured off the drawn panel: the grid starts at y=402 and the backdrop
-- ends at 891, so 489 to spend. The pager takes 34 and the two footer rows 68,
-- which leaves 387 - nine pitches of 40 with 27 to spare, where ten would need
-- 400 and overrun by 13.
--
-- Twenty seven per page rather than eighteen still takes the full list from
-- thirteen pages to eight.
local LIST_ROWS    = 9
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
    -- Lifted from 4.34:1, which failed the floor. The healthy state was the
    -- least legible text on the rules screen while the state you want people
    -- to notice less, Stopped, was the brightest - exactly backwards.
    working = { R = 0.72, G = 0.78, B = 0.85, A = 1.00 },
    -- On the filled primary button, where cyan-on-tint measured 3.94 and was
    -- the lowest contrast text in the panel while being its main action.
    primary = { R = 1.00, G = 1.00, B = 1.00, A = 1.00 },
    -- The filter placeholder, on the filter well. Light enough to clear 4.5
    -- there, quiet enough not to be mistaken for something already typed.
    hint_on_field = { R = 0.31, G = 0.35, B = 0.41, A = 1.00 },
    -- A control that exists but has nothing left to do. Quieter than an
    -- active one and darker than the prose, so "no more pages" cannot be
    -- mistaken for a sentence.
    -- A spent control still has to be readable. At 2.15:1 on its own flat
    -- bar this was the least legible thing in the panel by a wide margin -
    -- well under the 3:1 that anything visible needs, never mind text.
    spent  = { R = 0.62, G = 0.67, B = 0.73, A = 1.00 },
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
-- Darker than a data row, not lighter.
--
-- At its old value the cyan label on these bars measured 3.94:1 - four
-- controls under the 4.5 floor, including both pager buttons - and the bar
-- itself was lighter than the list rows above it, so the two least important
-- controls on the screen carried the strongest surface in the panel. Darker
-- fixes the label to 6.9 and puts the hierarchy back the right way up.
local BUTTON_BG = { R = 0.048, G = 0.065, B = 0.093, A = 1.00 }
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
-- Hover separates from selection by hue, at the same luminance.
--
-- It used to be the identical value, and the note explaining that is still
-- right about what was tried: a darker hover measured 1.20 against the panel
-- body, so it vanished, and 1.34 against the selection, so hovering made a row
-- read as MORE selected than the selected one. Every fill dark enough to sit
-- below the selection lands within 1.5 of both.
--
-- What that note then said was "the signal moved to the rail, which gets wider
-- under the pointer" - and the rail is drawn by list_row, on tiles. A rules
-- row has no rail. It has the caret, and the caret marks SELECTION, so on that
-- list hover had no signal of its own at all: pointing at row two while row
-- one was selected drew two rows in the same fill, told apart by one glyph.
--
-- Luminance cannot fix that without giving back the contrast the value below
-- was chosen for. Chroma can. This is neutral slate where the selection is
-- distinctly blue, at 0.062 against 0.060 - close enough that every token on
-- the row keeps the contrast it measured at, far enough apart in hue to see.
local ROW_HOVER = { R = 0.058, G = 0.062, B = 0.072, A = 1.00 }
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
local CEILING_BG  = { R = 0.82,  G = 0.85,  B = 0.89,  A = 1.00 }


-- Registers a row as clickable and, in the same breath, as reachable by the
-- arrow keys. Two lists that could disagree would be a bug waiting.
-- The optional third argument groups several hits into one visible row.
--
-- A rule row registers three of them - the job, the ceiling and Remove - and
-- up and down used to step through all three, so reaching the next rule took
-- three presses. Nobody reading a list thinks of it that way. Hits that pass
-- no row get one of their own and behave exactly as before.
local function hit(key, what, row)
    hits[key] = what
    order[#order + 1] = key
    rows[#order] = row or ("solo:" .. #order)
end

-- Said on screen as well as to the log.
--
-- Same text both places on purpose: the log stays a complete record for
-- anyone reading it after the fact, and the player gets told at the moment it
-- happens rather than never.
local function announce(text)
    notice, notice_at = text, os.clock()
    log.say(text)
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
    RB.hosts, RB.slot, RB.base, RB.pads = {}, nil, 0, {}
    -- The fill map goes with the widgets it describes. Left behind, every
    -- tile in a rebuilt tree would look already drawn, so nothing would be
    -- rationed and nothing written - an empty picker that thinks it is full.
    -- A flag describing an engine object shares that object's lifetime.
    RB.filled = {}
    RB.validated = -1
        pinned, pin_count = {}, 0
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
    RB.hosts, RB.slot, RB.base, RB.pads = {}, nil, 0, {}
    -- The fill map goes with the widgets it describes. Left behind, every
    -- tile in a rebuilt tree would look already drawn, so nothing would be
    -- rationed and nothing written - an empty picker that thinks it is full.
    -- A flag describing an engine object shares that object's lifetime.
    RB.filled = {}
    RB.validated = -1
    -- pinned holds booleans, not widgets, but the widgets those booleans
    -- describe just went with the old tree - a flag that describes an engine
    -- object shares its lifetime, so it clears where the widget tables clear.
    pinned, pin_count = {}, 0
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

    -- The blueprint brings its own backdrop, sized and anchored by Slate. Two
    -- of them would be one too many, and ours is the one drawn by hand.
    if overlay.parts then return end

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

        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        -- Under the text, over the world.
        pcall(function() slot:SetZOrder(8990) end)
        -- Hit testable, and the ZOrder above is what makes that safe: the
        -- backdrop is 8990 and every slab is 8995, so a row on top still wins
        -- the hit test and this only ever catches clicks that would otherwise
        -- have landed on nothing.
        --
        -- It has to catch them. Under Game-and-UI a click that misses every
        -- widget goes on to the game viewport, which takes mouse capture, and
        -- the click after that is the one the panel finally sees. That is the
        -- "I have to click tabs twice" report: the first click was not lost in
        -- the panel, it was spent on the world behind it.
        --
        -- Harmless under UI-only too, where nothing reached the viewport
        -- anyway, so this does not depend on which route is in force.
        pcall(function() backdrop:SetVisibility(0) end)
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
-- current: force the selected tone regardless of the key.
--
-- A row owns several hit keys and the stripe owns none of them, so matching
-- the stripe's own key against the cursor only worked while the row's first
-- column happened to be a hit target. Once the job stopped being clickable
-- for single-job items the cursor key became the limit, the stripe stopped
-- matching, and the selected row lost its fill entirely - leaving a 10px ">"
-- as the whole cursor on that screen, while ADD had a rail and a fill.
-- One row's box inside RuleList, made once and kept.
--
-- A CanvasPanel reports no desired size, so a bare one in a ScrollBox gets no
-- height and the row is invisible - which is the first thing that goes wrong
-- if this is written the obvious way. The SizeBox is what gives it one.
--
-- Rows are created in ascending order because draw_list draws them that way,
-- and a ScrollBox orders children by when they were added, not by any index
-- it is told. Anything that ever draws rows out of order has to rebuild these
-- rather than reuse them.
-- Push RuleList down to where the canvas table starts.
--
-- Two coordinate systems meet here. The panel's chrome is centre anchored at
-- TOP_Y + row * LINE; the ScrollBox is wherever Slate puts it, which with the
-- placeholders collapsed is the top of Body - the backdrop's top edge (-H/2)
-- plus its 18 of padding. The gap between those is what this closes, so the
-- first row lands under the column headings instead of behind the tab bar,
-- which is exactly where the first filled list drew it.
local function align_list_to(row, which, unit)
    local parts = overlay.parts
    if not parts or not alive(parts[which]) then return end

    -- Nothing, now that the chrome is in the flow with it.
    --
    -- This used to pad the list down to TOP_Y + row * LINE, because the tabs,
    -- the heading, the subtitle and the column headings were all drawn at
    -- absolute canvas positions and the list had to be pushed under them by
    -- hand. They are rows above it now, so Slate has already put the list
    -- exactly where it goes and any padding on top of that is a gap - which
    -- is what it looked like: seventy four pixels of empty backdrop between
    -- the headings and the first rule.
    --
    -- Kept as a function rather than deleted at the call sites, because it is
    -- what puts the padding BACK to zero on a list that had some before the
    -- chrome moved, and because a shell that fails to mount still needs the
    -- old behaviour. row and unit stay in the signature for that.
    local pad = 0
    if not (overlay.parts and next(RB.on) ~= nil) then
        local body_top = -(700 / 2) + 18
        local want = TOP_Y + row * (unit or LINE)
        pad = math.max(0, want - body_top)
    end

    -- Per list, because they are siblings in the same VerticalBox and each
    -- has its own idea of where its first row belongs.
    RB.pads = RB.pads or {}
    if RB.pads[which] ~= pad then
        local ok = pcall(function()
            local slot = parts[which].Slot
            if slot then
                slot:SetPadding({ Left = 0, Top = pad, Right = 0, Bottom = 0 })
            end
        end)
        if ok then RB.pads[which] = pad end
    end
end

-- Draw the next lines into a shell row instead of onto the canvas.
--
-- The row is uncollapsed so it takes its height, and RB.base is set to the Y
-- that row would have had on the canvas - so callers keep passing the same
-- absolute row numbers they always did and the widgets land at the top of
-- their own box. Answers false with no shell, which is what leaves every
-- caller on the behaviour it had before there was one.
function RB.use_row(name)
    local parts = overlay.parts
    if not parts or not alive(parts[name]) then return false end

    RB.on[name] = true
    pcall(function() parts[name .. "Row"]:SetVisibility(0) end)

    RB.slot = parts[name]

    -- Zero, and that is the whole point of a row.
    --
    -- Slate has already put the row where it goes, so a widget belongs at the
    -- TOP of it and the caller passes row 0. The first attempt set this to the
    -- gap between Body's top and canvas row 0, which reproduced the tabs at
    -- their old absolute position - 32 pixels below their own row, overflowing
    -- into the next one. It looked correct only because the row below was
    -- still collapsed, and would have collided the moment anything moved into
    -- it. Negative offsets still reach upward, which is how the header band
    -- gets out past Body's padding to the backdrop's edge.
    RB.base = 0
    return true
end

function RB.done_row()
    RB.slot, RB.base = nil, 0
end

-- Rows nobody drew into this frame go away, so they cost no height. This is
-- what lets one shell serve the rules screen and the picker: the search field
-- and the caption belong to one of them, the column headings to both.
function RB.tidy_rows()
    local parts = overlay.parts
    if not parts then return end

    for _, row in ipairs(RB.rows) do
        if not RB.on[row[1]] and alive(parts[row[1] .. "Row"]) then
            pcall(function() parts[row[1] .. "Row"]:SetVisibility(1) end)
        end
    end
    -- Kept for "pwp panel rows", which runs a frame after the draw it is
    -- asking about and would otherwise only ever see an empty table.
    RB.on_last, RB.on = RB.on, {}
end

local function row_host(i, which, height)
    local parts = overlay.parts
    if not parts or not alive(parts[which]) then return nil end
    if not alive(root_tree) then return nil end

    -- Keyed by list as well as index, or the picker's row 0 and the rules'
    -- row 0 would be the same box in two different parents.
    i = which .. ":" .. i

    local have = RB.hosts[i]
    if have and alive(have.box) and alive(have.canvas) then
        pcall(function() have.box:SetVisibility(0) end)
        return have.canvas
    end

    local box_cls = api.cdo("/Script/UMG.SizeBox")
    local canvas_cls = api.cdo("/Script/UMG.CanvasPanel")
    if not box_cls or not canvas_cls then return nil end

    local box, inner
    pcall(function() box = StaticConstructObject(box_cls, root_tree) end)
    if not alive(box) then return nil end
    pcall(function() inner = StaticConstructObject(canvas_cls, root_tree) end)
    if not alive(inner) then return nil end

    pcall(function() box:SetHeightOverride(height or LINE) end)
    pcall(function() box:AddChild(inner) end)

    local ok = pcall(function() parts[which]:AddChild(box) end)
    if not ok then return nil end

    RB.hosts[i] = { box = box, canvas = inner }
    return inner
end

-- Rows the list no longer has. Collapsed rather than removed: taking a child
-- out of a ScrollBox and putting it back is how the old panel ended up with
-- two of everything, and a collapsed box occupies nothing.
local function hide_rows_from(n, which)
    -- A list with nothing left in it gives its padding back too.
    --
    -- These two ScrollBoxes are siblings in one VerticalBox, and each is
    -- padded down to meet the panel's own layout. Padding occupies height
    -- whether or not anything is in the box, so an emptied RuleList still
    -- pushed the picker a screen down the panel and put its tiles off the
    -- bottom edge - collapsing the rows was not the same as taking the space
    -- back.
    if n == 0 then
        RB.pads = RB.pads or {}
        if RB.pads[which] ~= 0 then
            local parts = overlay.parts
            local ok = parts and alive(parts[which]) and pcall(function()
                parts[which].Slot:SetPadding(
                    { Left = 0, Top = 0, Right = 0, Bottom = 0 })
            end)
            if ok then RB.pads[which] = 0 end
        end
    end

    local prefix = which .. ":"
    for i, h in pairs(RB.hosts) do
        local mine = tostring(i):match("^" .. prefix .. "(%d+)$")
        if mine and tonumber(mine) >= n and h and alive(h.box) then
            pcall(function() h.box:SetVisibility(1) end)
        end
    end
end

local function slab(key, px, py, w, h, colour, hittable, current)
    local _p = RB.prof["slab"]
    if _p == nil then _p = { n = 0, ms = 0 } RB.prof["slab"] = _p end
    _p.n = _p.n + 1
    local host = ensure_root()
    if not host then return end

    used["s:" .. key] = true

    -- The row's own canvas when one is being drawn, the panel's otherwise.
    -- Captured per widget: a recycled key may have belonged to the other one
    -- last frame, and re-parenting is not something to do quietly.
    local into = RB.slot or host
    local base = RB.slot and RB.base or 0

    local border = stripes[key]
    if not alive(border) then
        local cls = api.cdo("/Script/UMG.Border")
        if not cls or not alive(root_tree) then return end

        pcall(function() border = StaticConstructObject(cls, root_tree) end)
        if not alive(border) then return end

        local slot
        local ok = pcall(function() slot = into:AddChildToCanvas(border) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
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

    -- X and Y are the canvas's centring offsets. A row canvas spans the list
    -- from its own left edge, so inside one the caller's px is already right
    -- and only the row's base has to come off the Y.
    local ox = RB.slot and 0 or X
    local oy = RB.slot and -base or Y

    local at = px .. ":" .. py .. ":" .. w .. ":" .. h .. ":" .. tostring(RB.slot ~= nil)
    if placed["s:" .. key] ~= at then
        local slot
        pcall(function() slot = border.Slot end)
        if alive(slot) then
            pcall(function() slot:SetPosition({ X = ox + px, Y = oy + py }) end)
            pcall(function() slot:SetSize({ X = w, Y = h }) end)
            placed["s:" .. key] = at
        end
    end

    RB.base_col[key] = colour

    -- Three states. The mouse and the keyboard were sharing one highlight, so
    -- there was no way to see where the keyboard was while the mouse was over
    -- something else.
    local want = (key == hover_key and "hot")
        or ((current or key == was_sel) and "sel")
        or "cold"

    -- The token written has to be the token compared. It was writing `want`
    -- and comparing `want .. colour`, so every slab failed its own cache check
    -- and repainted on every frame.
    local token = want .. tostring(colour) .. tostring(current)
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
-- How far a hosted row's content is lifted so it lands centred in its host.
--
-- stripe and line both anchor to (row * LINE - 3), which predates the shell:
-- back when every row was drawn at an absolute canvas position, -3 was simply
-- where the bar went. Inside a row host that -3 is measured from the host's
-- own top edge, so a 30 pixel bar in a 34 pixel row sat at -3..27 - three
-- pixels above the box, with seven pixels of nothing under it.
--
-- Rows two and onward got away with it. Their overflow lands on the row above
-- and is drawn normally, so they measure a full 30. The FIRST row's overflow
-- leaves the body entirely and is clipped, so that row alone came out 27 tall
-- with its text sitting low in what was left of it - which is the row a player
-- looks at first, and the only one that ever looked wrong.
--
-- Taking this off the base moves everything the row draws - bar, caret, every
-- column - down by five, landing the bar at 2..32 inside a 34 tall box. Two
-- above, two below, and nothing outside it to clip.
RB.ROW_LIFT = (LINE - ROW_H) / 2 + 3

local function stripe(key, row, from, width, colour, hittable, current)
    slab(key, from - 6, row * LINE - 3, width, ROW_H, colour, hittable, current)
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
    local _p = RB.prof["text"]
    if _p == nil then _p = { n = 0, ms = 0 } RB.prof["text"] = _p end
    _p.n = _p.n + 1
    local canvas = ensure_root()
    if not canvas then return end

    used[key] = true

    -- Same routing as slab: the row's own canvas while a row is being drawn.
    local into = RB.slot or canvas
    local base = RB.slot and RB.base or 0

    local tb = blocks[key]
    if not alive(tb) then
        local cls = api.cdo("/Script/UMG.TextBlock")
        if not cls or not alive(root_tree) then return end

        pcall(function() tb = StaticConstructObject(cls, root_tree) end)
        if not alive(tb) then return end

        local slot
        local ok = pcall(function() slot = into:AddChildToCanvas(tb) end)
        if not ok or not alive(slot) then return end

        -- Auto sized, because that is what demonstrably renders here.
        -- Sizing the slot explicitly, which is what this did, produced widgets
        -- that were positioned correctly and drew nothing at all, while the
        -- identically constructed text in overlay.lua's probe showed fine. The
        -- only difference between them was this call.
        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
        pcall(function() slot:SetAutoSize(true) end)
        pcall(function() slot:SetZOrder(9000) end)
        pcall(function() tb:SetVisibility(passthrough and 3 or 0) end)
        -- Offset AND colour. The offset alone has been here all along and
        -- drew nothing, because UMG's ShadowColorAndOpacity defaults to fully
        -- transparent - so the intent was in the file and the shadow was not.
        -- It matters on a panel that sits over a moving 3D scene, and it is
        -- also what the game's own text does.
        pcall(function() tb:SetShadowOffset({ X = 1, Y = 1 }) end)
        pcall(function()
            tb:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.6 })
        end)
        if points then set_size(tb, points) end

        blocks[key] = tb
        drawn[key] = nil
    end

    -- Position every frame, not only at construction: a row moves when the
    -- screen above it changes length.
    -- Ten times a second, so a move that changes nothing is worth skipping.
    local ox = RB.slot and 0 or X
    local oy = RB.slot and -base or Y

    local at = px .. ":" .. py .. ":" .. tostring(RB.slot ~= nil)
    if placed[key] ~= at then
        local slot
        pcall(function() slot = tb.Slot end)
        if alive(slot) then
            pcall(function() slot:SetPosition({ X = ox + px, Y = oy + py }) end)
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
-- The column headings, pushed down inside their own row.
--
-- The subtitle's descenders bottomed out two pixels above the headings' cap
-- height: the "j" of "job", the "p" of "stop" and the "y" of "you" sat inside
-- the row below and the two lines read as one smeared block. Two pixels is the
-- tightest gap on the panel, between the two things that most need telling
-- apart, while data rows get four and the title gets eighteen.
--
-- Done as a drop rather than by making the Sub row taller, because those
-- heights are baked into the pak and this is a text position. The Head row is
-- 28 tall carrying 12pt caps, so there is room to move down into.
RB.HEAD_DROP = 2

-- The rules list pages, and until now it did not.
--
-- It drew every rule it had. The panel's backdrop is a fixed 700 tall, so
-- past about fifteen rules the rows simply carried on down the screen: tested
-- with nineteen, and the last four rules and the "Add a rule" bar were drawn
-- over the game world with no backdrop behind them and the HUD showing
-- through. Nothing warned, and nothing scrolled - the list just left the box.
--
-- Thirteen a page, measured against the drawn panel rather than guessed. Rows
-- start at y=332 and step 34, the backdrop ends at 890, and the pager row and
-- the "Add a rule" bar want a row each: 332 + 13*34 = 774, then 808 for the
-- pager and 842 for the bar, which clears the bottom with room to spare.
-- Fourteen would fit and fifteen would not, so this is one row of margin
-- rather than none.
RB.RULES_PER_PAGE = 13
RB.rule_page = 0

-- The subtitle needs its own drop, smaller than the title's.
--
-- It used to share TITLE_DROP, which is 10 and is tuned for 22pt text in the
-- 34 tall Title row. The subtitle is 14pt in the 26 tall Sub row, and 10 put
-- it at roughly 11..30 - four pixels past the bottom of its own row.
--
-- On the rules screen that spill was invisible, because the row below is the
-- column headings and those are dropped away from it. On the picker the row
-- below is the search field, whose box fills almost all of its own row, so
-- the subtitle's descenders finished five pixels INSIDE the box. Two rows in
-- a vertical flow cannot overlap by accident; one of them has to be leaving
-- its own box, and it was this one.
--
-- 4 puts it near enough to 5..24 inside 26, which clears the row with a little
-- under the descenders. HEAD_DROP comes down from 8 to 2 at the same time, so
-- the gap to the column headings stays where it was measured rather than
-- growing by the six pixels the subtitle just moved up.
-- Measured on the drawn panel rather than derived. The title ends at 272 and
-- the search box starts at 302, so there are thirty pixels for an eighteen
-- pixel line and only twelve of slack.
--
-- Splitting that evenly measured well and looked wrong: a 22pt title wants
-- more air beneath it than a 14pt line needs above a box, so 7 and 6 read as
-- the title and subtitle being jammed together. The room came from the search
-- row instead, which had four spare pixels doing nothing under its box.
RB.SUB_DROP = 4

-- Resolved once, here, with a fallback.
--
-- caps.lua does not hot-reload and this module does, so a session started
-- before LADDER moved into caps gets nil - and this is an INDEX, not a call,
-- so it is invisible to a search for guarded calls. Every path that reaches
-- it is pcall-wrapped with the message discarded, which is precisely how the
-- last incarnation of this exact bug stayed hidden: caps.lua's own comment
-- describes it.
local LADDER = caps.LADDER or {
    100, 250, 500, 1000, 2000, 3000, 5000, 7500,
    10000, 15000, 20000, 30000, 50000,
}

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

-- Keep an icon resident by giving the engine a reason to.
--
-- This is how Creative Menu gets away with never searching: it is a cooked
-- widget Blueprint, its tiles hold brush references, and a texture something
-- references is a texture the engine keeps. Our tiles hold references too -
-- but only eighteen of them, re-pointed at every page turn, so the icons of
-- the page you left become unreferenced, get collected, and have to be
-- LoadAsset-ed and swept for all over again when you come back. That is the
-- revisit blank icons.lua documents, and the whole reason browsing costs
-- anything the second time.
--
-- So: one extra Image per icon ever shown, Collapsed so it is never laid out
-- or drawn, parented to the same tree as everything else so a world switch
-- takes it too. The reference lives in the ENGINE, widget -> brush ->
-- texture; Lua keeps only pinned[id] = true, a boolean about our own widget,
-- which is the one kind of keeping this codebase allows itself.
--
-- Capped because every pin is texture memory the engine can no longer free.
-- 400 pins at the icon sizes in this pak is a few tens of MB, about what one
-- open Creative Menu costs, and beyond the cap the picker simply behaves as
-- it does today - swept when resident, reloaded when not.
local PIN_MAX = 400

local function pin(texture, item_id)
    if pinned[item_id] ~= nil or pin_count >= PIN_MAX then return end
    if not (alive(root) and alive(root_tree)) then return end

    local cls = api.cdo("/Script/UMG.Image")
    if not cls then return end

    local img
    pcall(function() img = StaticConstructObject(cls, root_tree) end)
    if not alive(img) then return end

    if not pcall(function() root:AddChildToCanvas(img) end) then return end

    -- The texture wrapper is from this same call, per the tile that is about
    -- to draw it, so handing it to a second brush costs nothing and keeps
    -- nothing in Lua.
    pcall(function() img:SetBrushFromTexture(texture, false) end)
    pcall(function() img:SetVisibility(1) end)

    -- The widget, not just a flag.
    --
    -- It already holds the texture on its brush - that is what pinning means -
    -- so it is also the cheapest place to get that texture back from: one
    -- property read on a widget we own, against a sweep of every Texture2D in
    -- memory. Keeping it is allowed for the same reason the panel keeps its
    -- other widgets: we made it, it is parented to our tree, and it is
    -- validated with alive() before every use.
    pinned[item_id] = img
    pin_count = pin_count + 1
end

-- Pin what a sweep found, not merely what is on screen.
--
-- A sweep resolves every loaded icon in one pass and the panel used to keep
-- the eighteen it was drawing and drop the rest, so the next page swept all
-- 7,171 textures again. Pinning the surplus is what turns the sweep from a
-- per-page cost into a converging one: each sweep leaves fewer icons that
-- could ever need another.
--
-- Rationed, because pinning is a construct plus a brush write each and doing
-- sixty in a frame is its own stall. Eight a sweep, at most twice a second.
--
-- The map's textures are live only inside the sweep's own frame, which is
-- when this runs - icons calls it before returning.
local function pin_from_sweep(found)
    if not (alive(root) and alive(root_tree)) then return end

    -- Twenty four, not eight. Eight took ten sweeps to cover the seventy odd
    -- item icons a browse loads, and each of those sweeps is the 25ms this is
    -- trying to make unnecessary. Pinning is a construct and a brush write;
    -- doing more of them in the frame that already swept is the trade.
    local left = 24
    for name, tex in pairs(found or {}) do
        if left <= 0 then return end
        -- The sweep is keyed by icon NAME; pins are keyed by item id. Only
        -- ids already resolved can be matched up, which is most of them.
        if pinned[name] == nil and tex ~= nil then
            pin(tex, name)
            left = left - 1
        end
    end
end

-- Run from here rather than from a keybind. UE4SS never sees a key press
-- while the panel holds the input mode, which is exactly when these questions
-- matter, so the diagnostics fire themselves the first time a tile is drawn.
local probed = false

local function picture(key, px, py, size, item_id, token)
    local _p = RB.prof["pic"]
    if _p == nil then _p = { n = 0, ms = 0 } RB.prof["pic"] = _p end
    _p.n = _p.n + 1
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

    -- Same routing as slab and text_at: the grid row's own canvas when the
    -- picker is filling ItemList, the panel's canvas otherwise.
    local into = RB.slot or host

    local img = images[key]
    if not alive(img) then
        local cls = api.cdo("/Script/UMG.Image")
        if not cls or not alive(root_tree) then return end

        pcall(function() img = StaticConstructObject(cls, root_tree) end)
        if not alive(img) then return end

        local slot
        local ok = pcall(function() slot = into:AddChildToCanvas(img) end)
        if not ok or not alive(slot) then return end

        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
        pcall(function() slot:SetAutoSize(false) end)
        pcall(function() slot:SetZOrder(8998) end)
        pcall(function() img:SetVisibility(0) end)
        images[key] = img
    end

    local at = px .. ":" .. py .. ":" .. size .. ":" .. tostring(RB.slot ~= nil)
    if placed["i:" .. key] ~= at then
        local slot
        pcall(function() slot = img.Slot end)
        if alive(slot) then
            local ox = RB.slot and 0 or X
            local oy = RB.slot and -RB.base or Y
            pcall(function() slot:SetPosition({ X = ox + px, Y = oy + py }) end)
            pcall(function() slot:SetSize({ X = size, Y = size }) end)
            placed["i:" .. key] = at
        end
    end

    -- A budget, because resolving an icon is expensive and eighteen of them
    -- land on one frame.
    --
    -- Measured rather than guessed: StaticFindObject averages 12ms on this
    -- build, and every icon drawn goes through one. A page turn changes all
    -- eighteen tokens at once, so the frame that draws a new page spent about
    -- 430ms inside the lookup - the entire remaining lag, and the reason the
    -- earlier readings blamed loading, which turns out to average 0.3ms.
    --
    -- The texture cannot be kept between frames, so the call cannot be
    -- avoided; it can only be spread. Rows past the budget keep whatever they
    -- were showing and are picked up on the next refresh a tenth of a second
    -- later, so a page fills over two or three frames instead of stalling one.
    local hold = icon_retry[key]
    if hold and os.clock() < hold and drawn["i:" .. key] ~= token then
        return
    end

    if drawn["i:" .. key] ~= token and icon_budget <= 0 then
        -- Left for the next frame. Nothing is drawn wrong meanwhile: the
        -- image keeps its old contents and its token stays stale, which is
        -- exactly the condition that brings us back here.
        return
    end

    if drawn["i:" .. key] ~= token then
        icon_budget = icon_budget - 1
        -- The game's own loader first. It takes the item id and does the
        -- rest: finds the icon, streams it, puts it on the Image. When that
        -- works there is nothing here for the table, the queue or the
        -- rationing to do.
        --
        local _tg = os.clock()

        -- The pin first. An icon this panel has shown before is on a pin's
        -- brush, and reading it back is O(1) - where icons.get may sweep every
        -- texture in memory, which measured 80ms and was running ten times a
        -- second for as long as any icon on the page was unresolved.
        local texture
        local icon_name = item_id and icons.name_for
            and icons.name_for(item_id) or nil
        local pin_w = icon_name and pinned[icon_name] or nil
        if pin_w ~= nil and pin_w ~= true and alive(pin_w) then
            pcall(function()
                local b = pin_w.Brush
                local res = b and b.ResourceObject
                if res ~= nil then
                    local ok, yes = pcall(function() return res:IsValid() end)
                    if ok and yes then texture = res end
                end
            end)
        end

        if texture == nil then
            texture = item_id and icons.get(item_id) or nil
        end
        RB.t_get = (RB.t_get or 0) + (os.clock() - _tg)
        if texture then
            local _ta = os.clock()
            apply_texture(img, texture, size)
            RB.t_apply = (RB.t_apply or 0) + (os.clock() - _ta)
            -- Keyed by icon name, the same key the sweep uses, so a pin made
            -- here and a pin made from a sweep are the same pin.
            if icon_name then pin(texture, icon_name) end
            pcall(function() img:SetOpacity(1.0) end)
            -- Marked drawn only now. A failed resolve leaves the token stale
            -- so the next refresh tries again, which is what makes an icon
            -- appear by itself once it has loaded - the job the "+"/"-" in
            -- the old token was doing, without its cost.
            drawn["i:" .. key] = token
        else
            -- Not before a full second has passed. Without this an item with
            -- no icon retries every frame and eats the whole budget, starving
            -- the rows whose icons are really there.
            icon_retry[key] = os.clock() + ICON_RETRY_S
            -- Kept, not hidden. A hidden widget reports no hover, and the
            -- tile still has to be clickable when its picture is missing.
            pcall(function() img:SetOpacity(0.0) end)
        end
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

-- How many characters of this string fit in `width` pixels at `pt`.
--
-- Elision was budgeted in CHARACTERS against a proportional font, so it cut
-- by length rather than by width: a 214px name survived while a 201px one was
-- elided, and at least 54 pixels per column went unused while names were
-- being cut. Measuring turns the budget into what it was always meant to be.
local function fits(text, width, pt)
    return math.max(4, math.floor(width / (pt * GLYPH_W)))
end

local function fit_name(text, chars)
    text = tostring(text)
    if #text <= chars then return text end

    -- Elided in the MIDDLE, not at the end.
    --
    -- Names in this game share long prefixes and differ at the tail -
    -- "Skill Unlock Grass Mammoth" against "Skill Unlock Grass Mammoth Ice" -
    -- so cutting the end made two different items render the SAME string. Two
    -- rows on one page came out identical to the pixel, and with no icon on
    -- either there was nothing left to tell them apart before committing a
    -- rule to one of them. Keeping both ends keeps the half that
    -- distinguishes them.
    --
    -- Trailing space stripped before the dots, or a cut landing on a word
    -- boundary leaves a gap that reads as a typo in some rows and not others.
    local tail = math.min(9, math.floor(chars / 3))
    local head = chars - tail - 2
    if head < 1 then return text:sub(1, chars) end
    return (text:sub(1, head):gsub("%s+$", "")) .. ".." .. text:sub(-tail)
end

-- One item as a row: a left rail, its icon, its name, and how many are in
-- storage. The rail carries two things that never collide - the cursor, and
-- whether this item already has a rule - because the cursor is somewhere else
-- whenever you are reading the rail for the other reason.
local function list_row(key, at, item, have, top, limited)
    local col = at % LIST_COLS
    local row = math.floor(at / LIST_COLS)

    -- Three tiles share a grid row, so the row is the unit that goes into the
    -- ScrollBox and the tiles keep their X inside it. Set here rather than at
    -- the caller because this is where both halves are already worked out.
    RB.slot = row_host(row, "ItemList", LIST_PITCH)
    -- Centred in its host for the same reason the rules rows are, though this
    -- one never clipped: a 36 tall tile in a 40 tall row was flush against the
    -- top with all four spare pixels below it.
    RB.base = RB.slot
        and (top + row * LIST_PITCH - (LIST_PITCH - LIST_H) / 2) or 0
    local px = ROW_INSET + col * (LIST_W + LIST_GUTTER)
    local py = top + row * LIST_PITCH

    -- The row itself is the target. Its hit key owns no text - the name is
    -- drawn under "n:"..key - so before this the only hoverable part of the
    -- row was the icon, and a row still waiting for its icon had none at all.
    local _ts = os.clock()
    slab(key, px, py, LIST_W, LIST_H, TILE_BG, true)
    RB.t_slab = (RB.t_slab or 0) + (os.clock() - _ts)
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

    -- The token is just the item.
    --
    -- It used to carry icons.ready(item) so a tile would redraw when its
    -- picture finally arrived - but ready() costs a 12ms StaticFindObject the
    -- first time it is asked about an item, once per row, which is 200ms of a
    -- page turn spent asking a question that resolving the icon answers
    -- anyway. picture() marks itself drawn only once it actually applied a
    -- texture, so an icon that is not there yet comes back on its own.
    local _tp = os.clock()
    picture(key, px + 8, py + math.floor((LIST_H - LIST_ICON) / 2), LIST_ICON,
        item, item)
    RB.t_pic = (RB.t_pic or 0) + (os.clock() - _tp)

    -- "Already limited" said in a second channel, not only in green.
    --
    -- The green name measured 1.14:1 in luminance against a plain white one -
    -- no lightness difference at all - and under deuteranopia the two
    -- simulate to a pair of near-identical off-whites. It is the state that
    -- stops a player creating a rule they already have, and roughly one man
    -- in twelve could not see it. A word carries the same fact at any colour
    -- vision, and the count column is empty for these rows more often than
    -- not.

    -- The name takes whatever the count is not using.
    --
    -- A fixed budget cut every name to sixteen characters, which on the full
    -- list produced three rows reading "Baked Meat Ice.." that could not be
    -- told apart - the exact failure the names were added to fix. Most items
    -- on that list are not in storage at all and so have no count, and their
    -- names should have the whole row.
    local count = have > 0 and group_digits(have) or nil
    local room = LIST_COUNT_R - LIST_NAME_X

    -- The badge sits BESIDE the count now, on one baseline, not above it.
    --
    -- Stacked, it pushed the count down nine pixels to make room, so the three
    -- rows carrying the most state were the three whose numbers did not line
    -- up with the column - a step in the one column whose entire job is being
    -- comparable at a glance, at exactly the rows a player is looking hardest
    -- at.
    --
    -- It also reads as a word: "LIMITED", not "LIMIT SET". Above a number,
    -- "LIMIT SET 20,761" parses as a label and its value, which says the limit
    -- is 20,761 when that figure is what the base is HOLDING - the opposite of
    -- what the row means. An adjective cannot be read as a label for the
    -- number next to it.
    local badge = limited and "LIMITED" or nil
    local count_w = count and (text_w(count, 14, DIGIT_W) + 10) or 0

    if count then room = room - count_w end
    if badge then room = room - text_w(badge, 11, CAPS_W) - 10 end

    if badge then
        -- 11pt against the count's 14pt, so a shared top edge is not a shared
        -- baseline. Two pixels of the difference puts them on one.
        text_at("set:" .. key,
            px + right_x(LIST_COUNT_R - count_w, badge, 11, CAPS_W),
            py + 10, badge, "atlimit", 11, true)
    end

    -- Green while a rule already exists, so the rail and the name agree.
    text_at("n:" .. key, px + LIST_NAME_X, py + 7,
        fit_name(pretty_name(item), fits(item, room, 15)),
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

            -- And it stops taking hit tests, which clearing the colour does
            -- not do. An invisible stripe still answered IsHovered, and two
            -- screens put a full width bar at the same place in the same
            -- canvas: "+ Add a rule" on the rules list, "Show every item with
            -- a job" in the picker. Identical rectangles, identical ZOrder,
            -- and the one added later wins the hit test. So after a visit to
            -- ADD, hovering the add bar hovered the picker's ghost, whose key
            -- is not in hits on that screen, and the click went nowhere.
            --
            -- The words kept working because labels sit at 9000 and stripes
            -- at 8995, which is exactly the "only the text is clickable"
            -- report, and why nothing was ever wrong with the row itself.
            --
            -- Safe because slab re-applies SetVisibility on every draw,
            -- outside both the construction branch and the placed cache, so a
            -- stripe blanked here comes back hit testable the moment its own
            -- screen draws it again.
            pcall(function() border:SetVisibility(3) end)

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

        -- Sized to the row it covers.
        --
        -- Nothing set this before, so the box took the engine default while
        -- the row around it draws at ROW_PT - the number visibly grew when
        -- clicked and shrank again on commit. Set through the same style
        -- struct as the background, which UE4SS hands out by reference, and
        -- left alone if the build will not take it: a wrong size is untidy,
        -- a throw here would cost the whole field.
        pcall(function()
            if st.Font ~= nil then st.Font.Size = ROW_PT end
        end)

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

    -- Into the shell's own row when there is one. It was left on the canvas
    -- through the first pass of this work, on the grounds that an
    -- EditableTextBox with a typing path is not something to reparent
    -- casually - but the grid moved up into the flow without it and the field
    -- ended up lying across the first row of tiles. A widget that stays
    -- behind does not stay put, it just ends up somewhere wrong.
    local into = RB.use_row("Search") and RB.slot or host

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
        local ok = pcall(function() slot = into:AddChildToCanvas(search_box) end)
        if not ok or not alive(slot) then
            search_box = nil
            return nil
        end

        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
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
            if RB.slot then
                -- Y = 4, not 0. The Search row is 40 tall and the box is
                -- 36, and flush to the top spent all four spare pixels below
                -- it - where they do nothing - while the subtitle above had
                -- one pixel of clearance. Four of them moved to the top of the
                -- box is the whole gap, taken from a row that was not using
                -- it, which leaves the title its own breathing room instead of
                -- borrowing from that.
                slot:SetPosition({ X = ROW_INSET, Y = 4 })
            else
                slot:SetPosition({ X = X + ROW_INSET, Y = Y + row * LINE })
            end
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
    RB.done_row()

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

        pcall(function() slot:SetAnchors(RB.slot and RB.TOPLEFT or CENTRE) end)
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
    -- Not focused until the engine says so, and the answer is only trusted
    -- when the call itself succeeded.
    --
    -- This defaulted to true, so a build where HasKeyboardFocus is missing or
    -- throws set had_focus on the very first poll and then returned for ever:
    -- never committing, never abandoning, the editor pinned open for the
    -- session with the header still reading "Setting the X ceiling for Y".
    -- The pcall's own result was discarded, so "the call failed" and "the box
    -- has focus" were the same answer.
    local focused = false
    local asked = pcall(function()
        focused = (amount_box:HasKeyboardFocus() == true)
    end)

    if asked and focused then
        editing.had_focus = true
        editing.waiting = 0
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
    if not editing.had_focus or not asked then
        editing.waiting = (editing.waiting or 0) + 1
        if editing.waiting > 30 then
            announce("the ceiling box never took the keyboard, so the " ..
                workdefs.label(editing.work) .. " limit on " ..
                editing.item .. " is unchanged")
            editing = nil
            pcall(function() amount_box:SetVisibility(1) end)
        end
        return
    end

    local want = tonumber((text:gsub("[^%d]", "")))
    local job, item, was = editing.work, editing.item, editing.was
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
        announce("nothing typed, the " .. workdefs.label(job) .. " limit on " ..
            item .. " is unchanged")
        return
    end

    -- Unchanged means nobody typed here, whatever took the keyboard away.
    --
    -- The box commits when it stops holding the keyboard, which is what makes
    -- "type it and click away" work, and it fires just as readily when the
    -- whole game loses focus - alt tabbing with a ceiling open, or another
    -- window stealing it. That wrote the number already showing: a request to
    -- the server, a rule change pass and a log line, for a change nobody
    -- made. Measured on 23 August, the server logged "Deforest set Wood to
    -- 1200 by a player" for a box that had never been typed in.
    --
    -- This does not rescue a half typed number - a box holding "1" of "15000"
    -- when focus is lost still commits 1, and from here that cannot be told
    -- from someone who meant 1. It removes the case that costs nothing to
    -- remove.
    if want == was then return end

    caps.set(job, item, want, mine())
    M.wants_pass = true

    -- Says so when the new limit is already passed, because that stops the
    -- job the moment it is set and the panel should not let that happen
    -- quietly.
    local have = (stock_totals(cfg) or {})[item] or 0
    if want < have then
        announce(string.format(
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
        -- Grouped, like the cell it opens on top of. The column reads
        -- 15,000 and the box used to open on 15000, so the number appeared to
        -- change the instant it was clicked. The commit strips everything
        -- that is not a digit, so the commas cost nothing to carry.
        seed = rule.amount and group_digits(rule.amount) or "",
        -- Kept as a number and never cleared, unlike seed, which the first
        -- draw consumes. The commit compares against it to tell a real edit
        -- from a box that merely lost the keyboard.
        was = rule.amount,
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
                    -- The fullest base, not the sum of them.
                    --
                    -- Under camp scope the ceiling is checked against ONE
                    -- base at a time, so the sum is a number no decision is
                    -- ever made against. It read 15,207 beside a 15,000 limit
                    -- with nothing stopping, because neither base held 15,000
                    -- on its own - the panel appearing to break its own rule
                    -- while behaving correctly.
                    --
                    -- The largest single holding is the one that trips a
                    -- ceiling, so it is the honest thing to put next to it:
                    -- when it passes the limit, something really does stop.
                    if n > (totals[id] or 0) then totals[id] = n end
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

    -- The band above stays on the canvas on purpose. It runs the full width
    -- of the BACKDROP, outside Body's padding, so it is not a row of the
    -- stack at all - it is decoration behind one, and a row canvas could not
    -- reach the panel's edges to draw it.
    --
    -- What moves is everything you can see or click. Hit testing asks the
    -- widget IsHovered() rather than comparing coordinates, so reparenting
    -- costs the clicks nothing.
    RB.use_row("Tabs")

    -- The band comes into the row with the tabs, and it has to.
    --
    -- It was drawn on the panel's canvas at ZOrder 8995 while the tabs sat
    -- inside Backdrop's subtree at ZOrder 0, so it painted straight over them
    -- and the first attempt at this lost the words entirely. Anything on the
    -- canvas above the backdrop covers everything in the flow, which is a
    -- general rule: as chrome moves into the shell its decoration has to move
    -- with it or it ends up on the wrong side of the panel.
    --
    -- Placed in row coordinates. RB.base is what slab subtracts, so adding it
    -- back asks for a position measured from the row's own top left - and
    -- -PAD there is Body's padding, which is what lets the band run to the
    -- backdrop's edges instead of stopping short of them.
    -- Hit testable, which chrome normally would not need to be.
    --
    -- Under Game-and-UI a click that lands on no widget goes on to the game
    -- viewport, which takes mouse capture and spends it. This band runs to the
    -- backdrop's edges and sat HitTestInvisible, so every click that missed the
    -- small per-tab targets was donated to the world behind the panel, and the
    -- NEXT one was the first the tabs actually saw. That is the "I have to
    -- click ADD and RULES twice" report.
    --
    -- It cannot steal from the tabs themselves: the tabhit slabs below are
    -- constructed after this one, and with equal ZOrder the later child of a
    -- canvas wins the hit test.
    slab("tabbar", -PAD, -PAD, W + PAD * 2, ROW_H + PAD - 3, CHROME_BG, true)

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
    -- The panel never said how to leave it. In a game that draws a keycap
    -- beside every action in the corner of the screen - Command Pal 4, Summon
    -- Pal E - a bare word is the loudest "this is not part of the game" tell
    -- the panel has, and Alt+F1 appears nowhere on it.
    -- Drop 4, not 6: 12pt beside 20pt shares a top edge at the same drop, not a
    -- baseline. Measured off the drawn panel, 6 put ESC two pixels below
    -- CLOSE'''s baseline.
    line("tab_esc", 0, W - 148, "ESC", "faint", 12, 4)
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
    -- Row 0 in each, because the row is already where the line goes.
    RB.use_row("Title")
    line("title", 0, PAD, "Production Limits", "title", 22, TITLE_DROP)

    RB.use_row("Sub")
    line("why", 0, PAD,
        "Your Pals stop a job once base storage reaches the limit you set.",
        "dim", 14, RB.SUB_DROP)

    RB.done_row()

    -- Counted rather than assumed. The keyboard cursor starts at order[1],
    -- which is whatever the tab bar registered first, so switching screens
    -- left the marker sitting on RULES while the ADD screen was showing. The
    -- two disagreed about where you were.
    tab_hits = #order
end

local function rule_list(cfg)
    local out = {}
    for work, by_item in pairs(caps.all(cfg, mine())) do
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
    local all_rules = rule_list(cfg)

    -- Clamped rather than trusted. Removing the last rule on the last page
    -- would otherwise leave the view on a page that no longer exists, showing
    -- nothing, with no way back except the pager it just stopped drawing.
    local rule_pages = math.max(1,
        math.ceil(#all_rules / RB.RULES_PER_PAGE))
    if RB.rule_page >= rule_pages then RB.rule_page = rule_pages - 1 end
    if RB.rule_page < 0 then RB.rule_page = 0 end

    local rules = {}
    local rule_from = RB.rule_page * RB.RULES_PER_PAGE
    for i = rule_from + 1,
            math.min(rule_from + RB.RULES_PER_PAGE, #all_rules) do
        rules[#rules + 1] = all_rules[i]
    end

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
        RB.use_row("Notice")
        line("why", 0, PAD,
            "Setting the " .. workdefs.label(editing.work) .. " ceiling for " ..
            editing.item .. "  |  Type a number, then click anywhere to save",
            "action", 14)
        RB.done_row()
    elseif notice and (os.clock() - notice_at) < NOTICE_FOR then
        -- Below the editing caption on purpose: while a number is being typed
        -- the instruction for typing it is the more useful of the two.
        RB.use_row("Notice")
        line("why", 0, PAD, notice, "action", 14)
        RB.done_row()
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
        RB.use_row("Head")
        line("h_job",  0, PAD + MARK_W, "JOB",    "faint", 12, RB.HEAD_DROP)
        line("h_item", 0, COL_ITEM, "ITEM",       "faint", 12, RB.HEAD_DROP)
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
        line("h_have", 0,
            centre_x(COL2, COL2_R - COL2, "IN STORAGE", 12, CAPS_W),
            "IN STORAGE", "faint", 12, RB.HEAD_DROP)
        line("h_cap",  0,
            centre_x(COL_CAP - WELL_INSET, WELL_W, "LIMIT", 12, CAPS_W),
            "LIMIT", "faint", 12, RB.HEAD_DROP)
        -- PALS, not STATUS. The column sits 780 pixels right of the job it
        -- describes with three number columns in between, so "STATUS" had
        -- three things it could plausibly be the status OF - the job, the
        -- item, or the rule - and readers picked the rule. Naming the subject
        -- in the heading makes "Stopped" mean the pals stopped.
        -- STATUS, not PALS. The column holds Working, Waiting and Stopped,
        -- which is the state of the job, and a heading reading PALS over
        -- those invites reading them as a count of pals. Wider than PALS but
        -- narrower than the values already under it, so the layout is unmoved.
        line("h_st",   0, COL_DONE, "STATUS",     "faint", 12, RB.HEAD_DROP)
        RB.done_row()
        row = row + 1
    end

    if #rules == 0 then
        line("empty", row, PAD, "No rules yet. Every job runs unlimited", "dim")
        row = row + 2
    else
        -- The picker's boxes go away while the rules are showing, or
        -- they hold their height under this list and push everything
        -- below it down a screen.
        hide_rows_from(0, "ItemList")
        align_list_to(row, "RuleList")

        for i, rule in ipairs(rules) do
            -- Everything this iteration draws goes into row i's own box when
            -- the blueprint is hosting. row_host answers nil on the canvas
            -- path, which leaves both of these nil and every primitive on the
            -- behaviour it has always had.
            RB.slot = row_host(i, "RuleList")
            RB.base = RB.slot and (row * LINE - RB.ROW_LIFT) or 0

            local have = totals[rule.item] or 0
            local met = have >= rule.amount
            local key = "rule" .. i

            -- One answer for the whole row, used by both the fill and the
            -- caret, so the two can never disagree about which row is current.
            local here = row_is_current(key, "amt" .. i, "cap" .. i, "del" .. i)

            stripe(key, row, PAD, ROW_W, nil, false, here)

            -- One caret for the whole row, in the slot the layout already
            -- reserved for it. Every column after this one is placed from a
            -- fixed x and never moves, whether the row is current or not.
            line("mk" .. i, row, PAD, here and ">" or "", "hover", ROW_PT)
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
            -- The same words the picker used to offer it. This column showed
            -- the raw id, so an item chosen from a list reading "Baked
            -- Berries" turned into "Baked_Berries" the moment it became a
            -- rule, and the two screens disagreed about the name of the thing
            -- you had just picked.
            line("itm" .. i, row, COL_ITEM,
                short_item(pretty_name(rule.item)), "item", ROW_PT)
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
            -- What the pass decided, not what this screen can re-derive.
            --
            -- Asking cap_state here means asking it against `totals`, which
            -- under the default camp scope is the SUM across every camp while
            -- the pass decides per camp against each camp's own storage. Two
            -- bases with 3000 wood each under a 5000 limit rendered Stopped
            -- while both kept working. The pass now publishes its verdict and
            -- this reads it.
            --
            -- Still guarded, and now for two reasons: panel.lua hot-reloads
            -- and scheduler.lua does not, so a freshly dropped panel may be
            -- talking to a scheduler that exports neither; and last_capped is
            -- empty until a pass has run at all.
            local capped, partly = nil, nil
            local seen = scheduler.last_capped and scheduler.last_capped[rule.work]
            -- From THIS pass, or not at all.
            --
            -- scheduler.lua keys these by pass precisely so a camp that stops
            -- being loaded drops out rather than leaving a stale verdict
            -- behind - and the only reader ignored the key. Walk away from a
            -- base whose ceiling was met and run_pass stops considering it, so
            -- nothing ever overwrites the entry and the row says Stopped for
            -- the rest of the session. Falling through to cap_state answers
            -- from storage as it is now.
            if seen and seen.pass ~= scheduler.pass_id then seen = nil end
            if seen and seen.camps and seen.camps > 0 then
                capped = seen.capped >= seen.camps
                partly = seen.capped > 0 and seen.capped < seen.camps
                            and seen.capped or nil
            elseif scheduler.cap_state then
                capped = scheduler.cap_state(cfg, rule.work, totals, mine())
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
            elseif partly then
                -- Honest about a split rather than picking a side. Under camp
                -- scope a limit can be met at one base and not another, and
                -- both "Stopped" and "Working" would be wrong at one of them.
                --
                -- This was shortened to plain "Stopped" for a while because
                -- the count ran under the Remove button. That was the column
                -- being too narrow, not the sentence being too long: the
                -- panel is 60 pixels wider now and STATUS has 192 rather than
                -- 132, which holds "Stopped at 12" with room to spare.
                status, tone = "Stopped at " .. partly, "over"
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

            local nav_row = "rule:" .. i
            if choosable then
                hit(key, { kind = "job", rule = rule, works = works }, nav_row)
            end
            -- On the limit, which is the number being edited, the number the
            -- well is drawn behind and the number the typing box opens over.
            -- It was registered on the storage figure 170 pixels to the left:
            -- the well said "click here" over something that was not
            -- clickable, and clicking the thing that was opened a box
            -- somewhere else entirely.
            hit("cap" .. i, { kind = "rule", rule = rule, row = row }, nav_row)
            hit("del" .. i, { kind = "drop", rule = rule }, nav_row)
            row = row + 1
        end

        -- Back to the canvas for the chrome below the list, and any row boxes
        -- left over from a longer list put away.
        -- Leftover rows away FIRST, so the pager's own host can be re-shown
        -- after them.
        RB.slot, RB.base = nil, 0
        hide_rows_from(#rules + 1, "RuleList")

        row = row + 1

        -- The pager goes INTO the list as one more row, not onto the canvas
        -- under it.
        --
        -- "Add a rule" lives in the shell's Foot row, which the vertical flow
        -- places straight after RuleList - so a pager drawn at an absolute
        -- canvas position came out beneath it, with the cyan bar splitting the
        -- list from its own page controls. As a list row it lands where it
        -- reads: under the last rule, above the button.
        --
        -- Drawn only when it can do something. Unlike the picker's it does not
        -- hold its row on a single page: the picker's grid is a fixed height
        -- whatever it holds, so a vanishing pager moved the buttons under it,
        -- while this list is already as tall as its contents and one page is
        -- the normal case.
        if rule_pages > 1 then
            -- A FIXED host, one past a full page, never #rules + 1.
            --
            -- Keyed by index, so #rules + 1 was host 14 on a full page and
            -- host 7 on a six rule page - and a widget does not follow its key
            -- to a new parent. The pager's boxes stayed in host 14, which the
            -- shorter page had just collapsed, so page two drew no pager at
            -- all and there was no way back to page one. Found by paging to
            -- the end and being stranded there.
            --
            -- A collapsed row takes no height in a VerticalBox, so hosts
            -- between the last rule and this one close up and the pager still
            -- sits directly under the list.
            RB.slot = row_host(RB.RULES_PER_PAGE + 1, "RuleList")
            RB.base = RB.slot and (row * LINE - RB.ROW_LIFT) or 0

            local can_prev = RB.rule_page > 0
            local can_next = RB.rule_page < rule_pages - 1

            if can_prev then hit("rprev", { kind = "rpage", by = -1 }) end
            if can_next then hit("rnext", { kind = "rpage", by = 1 }) end

            slab("rprevbox", PAD, row * LINE - 1, 200, ROW_H - 4,
                can_prev and BUTTON_BG or ROW_BG, can_prev)
            slab("rnextbox", PAD + 212, row * LINE - 1, 200, ROW_H - 4,
                can_next and BUTTON_BG or ROW_BG, can_next)
            if can_prev then tile_face["rprev"] = stripes["rprevbox"] end
            if can_next then tile_face["rnext"] = stripes["rnextbox"] end

            line("rprev", row, PAD + 16, "<   Previous",
                can_prev and "action" or "spent", ROW_PT)
            line("rnext", row, PAD + 228, "Next   >",
                can_next and "action" or "spent", ROW_PT)
            line("rpageno", row, PAD + 440, string.format(
                "page %d of %d, %d limits", RB.rule_page + 1, rule_pages,
                #all_rules), "dim", 13)

            RB.slot, RB.base = nil, 0
            row = row + 1
        else
            line("rprev", row, PAD + 16, "", "dim", ROW_PT)
            line("rnext", row, PAD + 228, "", "dim", ROW_PT)
            line("rpageno", row, PAD + 440, "", "dim", 13)
        end
    end

    -- The one action on this screen that creates something, so it is the one
    -- that gets the filled treatment. "+ Add a rule", "Show every item with a
    -- job" and "< Back" were the same bar in the same tone with the same cyan
    -- label: a create, a filter and a navigation, visually indistinguishable.
    hit("new", { kind = "new" })
    if RB.use_row("Foot") then RB.base = -RB.ROW_LIFT end
    stripe("new", 0, PAD, ROW_W, PRIMARY_BG, true)
    tile_face["new"] = stripes["new"]
    -- Glyph and label in fixed slots, so all three action rows start their
    -- words on one edge. Baked into single strings before, where "[x]   ",
    -- "+   " and "<   " are three different widths and the labels came out
    -- ten and thirty pixels apart.
    line("mk_new", 0, PAD, row_is_current("new") and ">" or "", "hover", ROW_PT)
    line("g_new", 0, PAD + MARK_W, "+", "primary", ROW_PT)
    line("new", 0, PAD + MARK_W + GLYPH_SLOT, "Add a rule", "primary")
    RB.done_row()

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
    -- Cut content that still ships in the item table.
    --
    -- Palworld's data keeps entries the game itself cannot give you. The wiki
    -- files them under Category:Unused, and Curry is the clearest case: an
    -- item whose only id is "Curry_old", documented as unobtainable without
    -- modifying the game. They have no icon because they are not real, which
    -- is why a page of the picker came back with blank squares - the icons
    -- were never missing, the items were.
    --
    -- Offering one is the same error as offering a Pal drop: the player picks
    -- it, gets a rule, and no pal will ever make the thing.
    "_old", "_tmp", "tmp_", "_dummy", "unused", "deprecated",
    -- Named families the wiki documents as unobtainable. Pal Growth Stone XL
    -- is the clearest: no recipe, no drop, no merchant, reachable only by
    -- modifying the game. It slipped past the markers above because its id
    -- carries none of them - it got in by matching "stone" in the job table
    -- and being filed under Mining, which is a substring match rather than a
    -- fact about the item.
    "growth_stone", "skillunlock", "palegg_",
}

-- Ids that end in a bare serial, like Yakushima_Ingot001 or Key_Sphere_01.
--
-- These are the other shape cut content takes. A real variant reads
-- PalSphere_Giga; a leftover reads Ingot001. Kept separate from INTERNAL
-- because it is a shape rather than a word, and matched only at the end so
-- an id that merely contains digits is untouched.
local function looks_serial(id)
    local hay = tostring(id):lower()
    return hay:match("%d%d%d$") ~= nil or hay:match("_%d%d$") ~= nil
end

local function looks_internal(id)
    local hay = tostring(id):lower()
    for _, mark in ipairs(INTERNAL) do
        if hay:find(mark, 1, true) then return true end
    end
    return looks_serial(hay)
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
    -- An id the icon loader has exhausted every route for is not an item the
    -- game itself believes in. See icons.gave_up.
    if icons.gave_up and icons.gave_up(id) then return false end
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

-- How many distinct items storage holds.
--
-- The order is by quantity, and quantities change constantly while Pals work
-- - so keying the list on the totals TABLE meant it was rebuilt and re-sorted
-- every time the scheduler published, and rows physically swapped places
-- under the cursor. Berries fell below Fiber between two captures a minute
-- apart and the two traded cells. On a screen driven by arrow keys, the row
-- you read and the row you press Enter on can then be different items.
--
-- Counting ids instead holds the order steady while the numbers move, and
-- still rebuilds when an item appears or runs out - which is the one moment a
-- re-sort is expected.
local function id_count(totals)
    local n = 0
    for _ in pairs(totals or {}) do n = n + 1 end
    return n
end

local function picker_source(totals)
    -- The fourth term is how many ids the icon loader has written off. It
    -- only ever grows, and when it does the filtered list is stale.
    local gave_up = icons.gave_up_n or 0
    local ids_now = id_count(totals)

    if picker_key ~= nil
        and picker_key[1] == search_text
        and picker_key[2] == show_all
        and picker_key[3] == ids_now
        and picker_key[4] == gave_up
    then
        return picker_hit[1], picker_hit[2]
    end

    local list, everything = build_picker_source(totals)
    picker_key = { search_text, show_all, ids_now, gave_up }
    picker_hit = { list, everything }
    return list, everything
end

local function draw_item_picker(cfg, totals)
    RB.pf = { t = os.clock() }
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
    -- The echo of the cursor's item used to sit on the row above the search
    -- field, bold and white, at the exact x a field label would use - so it
    -- read as the LABEL of that box ("searching within Stone"), and it
    -- blinked out entirely whenever the cursor moved to a footer bar. The
    -- rail already says which row is current and the row says its own name in
    -- full, so the line is gone and everything below moved up into the space
    -- it was holding. That is where the column headings now sit, and the
    -- panel is no taller than it was.
    RB.pf.pre_search = os.clock()
    ensure_search(3)
    RB.pf.post_search = os.clock()

    -- Ours, in a colour the panel controls, and only while the field is
    -- empty. The bar was otherwise flat dark with no border and no words,
    -- which does not read as somewhere you can type - and the field is the
    -- one thing that makes 233 items findable.
    --
    -- Placed from the FIELD's own box, not from line()'s row formula. The
    -- field is 36 tall and sits flush on the row's top edge while a row is 30
    -- tall and inset three, so a hint placed by row sat about eight pixels
    -- high in it - which is what "not properly in the middle" was.
    -- Into the field's own row, with the field. The panel draws this hint
    -- itself because UMG keeps a field's placeholder colour in the one part
    -- of the style struct this build will not let us write, and the stock one
    -- measured 2.20 against the field - so it is a separate widget, and a
    -- separate widget is one that can be left behind. It was: the field moved
    -- into the shell and its own placeholder stayed on the canvas, lying
    -- across the caption underneath.
    RB.use_row("Search")
    text_at("hint", ROW_INSET + 13,
        (SEARCH_H - ROW_PT * 1.35) / 2 - ROW_PT * 0.13,
        search_text == "" and "Search for an item to limit" or "",
        "hint_on_field", ROW_PT, true)
    RB.done_row()

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
    RB.use_row("Caption")
    line("sub", 0, PAD, caption, "dim", 13)
    RB.done_row()

    -- Names the only number on this screen.
    --
    -- Each row read "Stone .... 17,114" with nothing anywhere saying what
    -- 17,114 was - on a screen titled Production Limits, where a bare number
    -- beside an item name reads as the limit. A player's first act was to
    -- click an item believing they were confirming a limit that already
    -- existed, when they were opening a blank one. The rules table labels its
    -- numbers; this one did not.
    --
    -- Repeated over each of the three columns, because each column is its own
    -- little table.
    RB.use_row("Head")
    RB.pf.chrome = os.clock()
    for c = 0, LIST_COLS - 1 do
        local cx = ROW_INSET + c * (LIST_W + LIST_GUTTER)
        line("h_it" .. c, 0, cx + LIST_NAME_X, "ITEM", "faint", 12, RB.HEAD_DROP)
        line("h_st" .. c,
            0, cx + right_x(LIST_COUNT_R, "IN STORAGE", 12, CAPS_W),
            "IN STORAGE", "faint", 12, RB.HEAD_DROP)
    end
    RB.done_row()

    local top = 6 * LINE
    local from = page * LIST_PER_PAGE + 1

    grid_from, grid_count = #order + 1, 0

    -- Which items already have a rule, so the grid can say so.
    local has_rule = {}
    for _, r in ipairs(rule_list(cfg)) do has_rule[r.item] = true end

    hide_rows_from(0, "RuleList")
    align_list_to(top / LINE, "ItemList", LINE)

    for i = from, math.min(from + LIST_PER_PAGE - 1, #source) do
        local id = source[i]
        local key = "pick" .. (i - from)

        -- A tile already showing this item is a handful of guarded writes
        -- that all decline; a tile showing it for the first time creates its
        -- widgets. Only the second kind is rationed, which is why a settled
        -- page still redraws whole at under 5ms and only a page being built
        -- for the first time is spread across frames.
        if RB.filled[key] ~= id then
            -- Broken at any tile, not only on a grid row boundary.
            --
            -- The row was the first shape of this and it did not work: a tile
            -- shown for the first time costs about ten milliseconds - widget
            -- creation, not the picture, which pinning already has down to
            -- one or two - so a three tile row is thirty, and forcing a whole
            -- row through meant every frame of the fill was still a frame the
            -- game lost. Measured at the checkpoint: "3 tiles, 4 fresh,
            -- spent 33".
            --
            -- The cost of the finer grain is that a row can be part drawn for
            -- a frame or two. On a first build the rest of the row is blank
            -- anyway, and on a rebuild it briefly holds the previous page -
            -- at 16ms a tile that is one or two frames of staleness against a
            -- guaranteed dropped frame, which is the better trade.
            --
            -- grid_count > 0 keeps one tile of progress per frame, so a slice
            -- too small for even one tile still cannot stall the fill.
            if grid_count > 0 and (os.clock() - RB.draw_t0) > RB.SLICE then
                RB.pending = true
                break
            end
            RB.filled[key] = id
        end

        list_row(key, i - from, id, totals[id] or 0, top, has_rule[id])
        hit(key, { kind = "item", item = id })
        grid_count = grid_count + 1
    end

    -- Back to the canvas for the pager and everything under it, and grid rows
    -- left over from a fuller page put away.
    RB.pf.tiles = os.clock()
    RB.slot, RB.base = nil, 0
    hide_rows_from(math.ceil(grid_count / LIST_COLS), "ItemList")

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
    -- Both buttons into the shell's Foot row, which is 76 tall for exactly
    -- this: two 34 pixel rows and a little air. Rows 0 and 1 inside it, since
    -- a chrome row is already where it goes and the caller counts from its
    -- top. The rules screen puts its add bar in the same row - only one of
    -- the two screens is ever drawing.
    --
    -- These were the last thing still on the canvas, left there because they
    -- collided with nothing. That is not a reason: the grid moved into the
    -- flow above them and the search field had to follow, and a widget left
    -- behind does not stay put, it ends up somewhere wrong.
    local footed = RB.use_row("Foot")
    -- Down by the same lift the list rows get, and for the same reason: the
    -- shared anchor puts a row's content three pixels above its own top edge,
    -- so the first footer bar was drawn INTO the grid above it. Measured, the
    -- last tile ended at 599 and this bar began at 600 - the two touched. The
    -- other chrome rows compensate with their own drops; this one had none.
    if footed then RB.base = -RB.ROW_LIFT end
    local r_all = footed and 0 or row
    local r_back = footed and 1 or (row + 1)

    hit("all", { kind = "toggle_all" })
    stripe("all", r_all, PAD, ROW_W, BUTTON_BG, true)
    tile_face["all"] = stripes["all"]
    line("mk_all", r_all, PAD, row_is_current("all") and ">" or "", "hover", ROW_PT)
    line("g_all", r_all, PAD + MARK_W,
        everything and "[x]" or "[  ]", "action", ROW_PT)
    line("all", r_all, PAD + MARK_W + GLYPH_SLOT,
        "Show every item with a job", "action", ROW_PT)

    hit("back", { kind = "back" })
    stripe("back", r_back, PAD, ROW_W, BUTTON_BG, true)
    tile_face["back"] = stripes["back"]
    line("mk_back", r_back, PAD, row_is_current("back") and ">" or "", "hover", ROW_PT)
    line("g_back", r_back, PAD + MARK_W, "<", "action", ROW_PT)
    line("back", r_back, PAD + MARK_W + GLYPH_SLOT, "Back", "action", ROW_PT)

    RB.done_row()

    local pf = RB.pf
    if pf and (os.clock() - pf.t) > 0.020 then
        log.say(string.format(
            "picker draw %.0fms  (to search %.0f, search %.0f, rest of " ..
            "chrome %.0f, tiles %.0f, %d tiles)",
            (os.clock() - pf.t) * 1000,
            ((pf.pre_search or pf.t) - pf.t) * 1000,
            ((pf.post_search or pf.t) - (pf.pre_search or pf.t)) * 1000,
            ((pf.chrome or pf.t) - (pf.post_search or pf.t)) * 1000,
            ((pf.tiles or pf.t) - (pf.chrome or pf.t)) * 1000, grid_count))
    end

    return row + 2
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

-- One pass of whichever screen is up, returning how many rows tall it came
-- out. Separated so the frame that changes height can run it twice.
local function redraw(cfg, totals)
    -- The slice is measured from here rather than from the top of refresh, so
    -- a slow beat elsewhere cannot eat the whole allowance before a single
    -- tile has been drawn. Cleared first: a draw that finishes is a draw with
    -- nothing pending, and only the tile loop sets it again.
    RB.draw_t0, RB.pending = os.clock(), false

    if mode == "item" then
        return draw_item_picker(cfg, totals)
    end
    hide_search()
    return draw_list(cfg, totals)
end

-- Is the pointer over anything belonging to this key?
--
-- All three surfaces are asked, not just the first one that exists. A key can
-- own a slab AND text AND a picture, and only ONE of them can be hovered at a
-- time: Slate gives the pointer to the topmost hit-testable widget under it,
-- and this panel draws text at a higher Z order than the slabs behind it.
--
-- Taking the first surface that existed therefore broke every control that
-- had just been given a slab. Asking the slab alone meant hovering the WORD
-- reported nothing, because the word was on top and had taken the pointer -
-- so tabs, list rows, the limit well, Remove and the action bars all answered
-- in the padding around their labels and nowhere else. Which is worse than
-- where they started, and is what "a lot of the mouse events stopped working"
-- was.
local function over_key(key)
    local hit_any = false
    pcall(function()
        local a = tile_face[key]
        if a ~= nil and alive(a) and a:IsHovered() then hit_any = true return end
        local b = blocks[key]
        if b ~= nil and alive(b) and b:IsHovered() then hit_any = true return end
        local c = images[key]
        if c ~= nil and alive(c) and c:IsHovered() then hit_any = true end
    end)
    return hit_any
end

-- icons calls this from inside the frame that swept, which is the only frame
-- those textures are safe in.
pcall(function() icons.on_sweep = pin_from_sweep end)

-- One row's tint, recomputed in place. The frame-rate half of hover.
--
-- Ignores the keyboard-selection state on purpose: this runs between full
-- draws, and a row that was both selected and hovered falls back to its base
-- colour for at most one body beat before the full draw restores the finer
-- distinction. The alternative was recomputing row_is_current here, which
-- drags half the draw's context into a path that exists to avoid the draw.
RB.retint = function(key)
    if key == nil then return end
    local border = stripes[key]
    if not alive(border) then return end
    pcall(function()
        border:SetBrushColor((key == hover_key and ROW_HOVER)
            or RB.base_col[key]
            or ROW_BG)
    end)
    -- The token is stale now; the next full draw recomputes it honestly.
    drawn["s:" .. key] = nil

    -- The picker tile's rail, whose hover channel is WIDTH - 3px wide, 6px
    -- under the pointer, per the note at its draw site. The tint above moves
    -- at frame rate now, so a rail waiting for the 100ms body pass reads as
    -- the one part of the highlight still trailing - which is exactly what
    -- it was. Rules rows have no rail; the lookup just misses for them.
    --
    -- Width only. The rail's colour also reacts to the cursor, but its base
    -- colour encodes "a rule exists" (green), and this path cannot know that
    -- without dragging the draw's context in - a briefly stale colour for
    -- one body beat is invisible next to a stale width, which is the thing
    -- being fixed.
    local rail = stripes["rail:" .. key]
    if alive(rail) then
        local slot
        pcall(function() slot = rail.Slot end)
        if alive(slot) then
            pcall(function()
                slot:SetSize({
                    X = (key == hover_key) and RAIL_W_HOT or RAIL_W,
                    Y = LIST_H,
                })
            end)
            placed["s:rail:" .. key] = nil
        end
    end
end

-- Poll the pointer and move the highlight, WITHOUT drawing anything else.
--
-- The highlight used to move only when the whole panel redrew - ten times a
-- second, up to 100ms behind the pointer, which is what "hovering is not
-- fluent" was. Then a hover change was made to force the redraw, which fixed
-- the wait and introduced a worse cost: sweeping the mouse across five rows
-- paid five full redraws, ~30-50ms each, with the 9ms owner check inside
-- every one.
--
-- The scan is 0.05ms, measured. The retint is two token-guarded brush writes.
-- So this runs from a persistent 16ms game-thread loop - BreedingHelper
-- drives its whole panel this way, off its widget's own Tick - and the full
-- draw stays on its 100ms deadline for data changes, exactly as before.
-- The pad, read at frame rate rather than on the body beat.
--
-- IsInputKeyDown is a LEVEL read, and the body beat is clock's 100ms floor,
-- so a press shorter than one beat was invisible. A deliberate d-pad press is
-- 60 to 100ms, which is exactly the range that was being dropped, and it read
-- as "the controller is unreliable" rather than as aliasing.
--
-- The 16ms loop already exists for the pointer highlight and calls into this
-- module, so this costs a registration of nothing. Moving the selection here
-- does not draw: nav changes which row is selected and the next body beat
-- renders it, same as the mouse.
function M.pad_tick()
    if not (M.open and RB.pad and RB.pad.drive) then return end

    local cfg = RB.pad_cfg
    if cfg == nil then return end

    RB.pad.tick_ms = 16

    pcall(function()
        RB.pad.drive({
            nav      = function(verb) M.nav(cfg, verb) end,
            close    = function() M.toggle() end,
            tab_prev = function() M.tab_step(cfg, -1) end,
            tab_next = function() M.tab_step(cfg, 1) end,
            remove   = function() M.row_action(cfg, "drop") end,
        })
    end)
end

function M.hover_tick()
    if not M.open then return false end

    -- Before the validity window below, deliberately. Reading a controller
    -- touches no widget, so it has no reason to be refused on the frames when
    -- the widget tree is not proven fresh - and those are exactly the frames
    -- after a redraw, when a player is most likely to be pressing something.
    pcall(M.pad_tick)

    -- Only inside the window a draw has just validated. 150ms is one body
    -- beat plus slack: past that the tree has not been proven this side of a
    -- world change, and the widgets below are wrappers from an earlier frame.
    -- Refusing costs one missed highlight update; not refusing costs the
    -- process, which is what it cost.
    if (os.clock() - (RB.validated or -1)) > 0.15 then return false end

    local before = hover_key
    hover_key = nil
    for key in pairs(was_hit or {}) do
        if over_key(key) then
            hover_key = key
            break
        end
    end
    if hover_key == before then return false end

    RB.retint(before)
    RB.retint(hover_key)
    return true
end

-- Carries a page that ran out of slice on to the next frame.
--
-- Rides main.lua's 16ms game thread loop, the one hover already uses, rather
-- than the 100ms clock beat. That is the point of it: eighteen tiles at eight
-- milliseconds a beat would take most of two seconds to appear, while at
-- frame rate the same fill is done in about a third of a second and no single
-- frame pays more than half its budget.
--
-- It calls the ordinary refresh rather than reaching into the draw directly,
-- so hits, order and the used map are rebuilt by the code that already gets
-- that right. Setup is free now, stock is on its own timer and the draw
-- rations itself, so a refresh with nothing new to show is under 5ms: the
-- extra frequency buys the fill and costs nothing once the fill is over.
function M.fill_tick()
    if not (M.open and RB.pending and RB.cfg) then return false end
    M.refresh(RB.cfg)
    return true
end

function M.refresh(cfg)
    -- Timed, because "laggy" has three plausible causes here and guessing
    -- between them has already cost a round. Reports the worst refresh seen
    -- in each five second window, once, with where the time went.
    local t0 = os.clock()
    frame_id = frame_id + 1
    icon_budget = ICONS_PER_FRAME

    -- Kept so fill_tick can carry a half drawn page on without the clock. It
    -- is config's own table, plain Lua this mod owns, not an engine object -
    -- holding it across frames costs nothing and risks nothing.
    RB.cfg = cfg or RB.cfg

    -- The root is validated FIRST, before anything touches a stored widget.
    --
    -- ensure_root is the only thing that drops amount_box when the overlay is
    -- rebuilt, and the editing block below used to run ahead of it - including
    -- on the once-a-second tick while the panel is CLOSED, where ensure_root
    -- was never reached at all. So an overlay rebuilt without a world switch
    -- left a freed box, and alive() on it is the crash rather than a check
    -- against it, once a second, for the rest of the session.
    --
    -- It is frame-cached, so asking here costs nothing that was not going to
    -- be paid anyway.
    local tsetup = os.clock()

    -- Nothing to validate when the panel is shut and nothing is being typed.
    --
    -- ensure_root ends in overlay.host(), whose first act is owner_name() - a
    -- FindFirstOf for PalPlayerController plus a GetFullName. Measured on this
    -- build at 9ms, because FindFirstOf can only early-exit on a class that is
    -- common and there is exactly one player controller in an array of tens of
    -- thousands. At ten refreshes a second that is 90ms of every second spent
    -- checking whether a widget nobody is looking at is still valid.
    --
    -- It cannot simply be cached: overlay.lua sets OWNER_TTL to zero on
    -- purpose, and says why - a stale name matches, the drop is skipped, and
    -- alive() is then called on a widget outered to a freed controller, which
    -- is the crash rather than the check for it.
    --
    -- But the reason this runs while shut is to drop a freed amount_box, and
    -- there is no amount_box unless a ceiling is being typed. With the panel
    -- closed and editing nil there is nothing here to protect.
    local rooted
    if M.open or editing ~= nil then
        rooted = ensure_root()
        if rooted then RB.validated = os.clock() end
    end
    perf_setup = os.clock() - tsetup

    -- Closing the game's own menu hands the cursor back to the world without
    -- caring that this panel is still open. Guarded like every other call into
    -- a sibling that hot reloads: a reload into a session whose overlay
    -- predates this would take the refresh down once a second.
    if rooted and overlay.reassert_input then
        pcall(function() overlay.reassert_input() end)
    end

    -- The other direction, and it runs whether or not the panel is rooted.
    --
    -- reassert_input puts the panel's input back when the game takes it while
    -- the panel is OPEN. This catches the opposite and worse case: the panel
    -- shut with the game still in the panel's input mode, which leaves a
    -- player unable to click their own pause menu.
    if overlay.watch_input then
        pcall(function() overlay.watch_input() end)
    end

    if overlay.watch_cursor then
        pcall(function() overlay.watch_cursor() end)
    end

    -- Step aside when the game opens UI of its own.
    --
    -- This is what the goal asked for all along - behave like the creative
    -- menu - and it is also what makes disabling the controller safe. A
    -- disabled controller ignores the game's menus too, so the one state that
    -- must never exist is our panel open underneath one of them. Rather than
    -- police that, this makes it impossible: the game opens something, we get
    -- out of the way and hand input back on the way out.
    --
    -- api.game_ui_active is the game's own answer, recorded by main.lua's gate
    -- BEFORE the gate overrides it, and measured uncontaminated: with the
    -- panel open and no game menu it reads false while the override reads
    -- true.
    --
    -- Compared against what it was when the panel opened, so opening the panel
    -- from inside a menu does not slam it shut again on the next beat.
    if M.open then
        if api.game_ui_active == true and RB.game_ui_at_open ~= true then
            log.debug("panel: the game opened its own UI, stepping aside")
            pcall(function() M.toggle() end)
            return
        end
    else
        RB.game_ui_at_open = api.game_ui_active
    end

    -- The pad, driving the same verbs the arrow keys drive.
    --
    -- Hung off RB rather than a top-level local because this file sits four
    -- short of Lua's 200-local ceiling, and going over breaks hot reload
    -- silently, which is exactly the tool being used to develop this.
    --
    -- loadfile for the same reason the pad command uses it: require would hand
    -- back whatever UE4SS compiled at startup. Cached after the first read, and
    -- a panel reload clears the cache with the rest of RB.
    if RB.pad == nil then
        local built = false
        local rl = package.loaded["reload"]
        local dir = rl and rl.scripts_dir
        if dir then
            local chunk = loadfile(dir .. "pad.lua")
            if chunk then
                local ok, result = pcall(chunk)
                if ok and type(result) == "table" then built = result end
            end
        end

        -- Fall back to whatever is already loaded, the way the pad command
        -- has all along. Without this the two paths disagree: the command
        -- keeps working while the driver silently does not exist, so the pad
        -- reads perfectly in a probe and moves nothing in the panel. That is
        -- an unpleasant shape of bug and it costs one line to rule out.
        if type(built) ~= "table" then
            built = package.loaded["pad"]
            if type(built) ~= "table" then
                local got, req = pcall(require, "pad")
                built = (got and type(req) == "table") and req or false
            end
        end

        RB.pad = built
        log.debug("panel: pad driver " ..
            (type(RB.pad) == "table" and "loaded" or "NOT AVAILABLE"))
    end

    if RB.pad and RB.pad.drive then
        if M.open then
            -- Driven from hover_tick at 16ms instead, so a quick tap is not
            -- missed. See M.pad_tick. cfg is stashed because that loop is
            -- called with no arguments.
            RB.pad_cfg = cfg
        else
            -- A button still down when the panel shuts must not fire again the
            -- instant it reopens.
            pcall(RB.pad.forget)

            -- Shut, so the only thing worth reading is the chord that opens it.
            if RB.pad.open_asked then
                local asked = false
                pcall(function() asked = RB.pad.open_asked() end)
                if asked then pcall(function() M.toggle() end) end
            end
        end
    end

    -- The typed-ceiling box, when one is open: placed, then read.
    if rooted and editing ~= nil then
        ensure_amount_box()
        poll_amount(cfg)
    end

    if not M.open then return end
    if not rooted then return end

    -- Which row the mouse is on, decided from last frame's map before it is
    -- rebuilt. One frame of lag on a highlight is invisible; drawing the whole
    -- screen twice to avoid it is not.
    local th = os.clock()
    local hn = 0
    hover_key = nil
    for key in pairs(hits) do
        hn = hn + 1
        if over_key(key) then
            hover_key = key
            break
        end
    end
    perf_hover, perf_hits = os.clock() - th, hn

    -- was_sel is set after the draw instead, once `order` is this frame's.
    was_hit = hits
    hits, order, used, rows = {}, {}, {}, {}

    local ts = os.clock()
    local totals = stock_totals(cfg)
    perf_stock = os.clock() - ts

    local td = os.clock()
    local rows = redraw(cfg, totals)
    perf_draw = os.clock() - td

    -- Everything after the draw, timed as one lump.
    --
    -- setup + hover + stock + draw came to about 31ms of a 44ms refresh, and
    -- the four are captured from the SAME frame as the total - so 13ms was
    -- being spent somewhere nobody was looking. Tail work is the only
    -- candidate left: tidy_rows, blanking, the caret, the cursor guard.
    RB.t_tail = os.clock()

    -- One draw's worth of primitive calls, kept for the bench.
    RB.last_prof, RB.prof = RB.prof, {}
    -- The WORST draw since the last bench, not the last draw. A page turn is
    -- one frame in ten and by the time anyone asks, ten quiet ones have been
    -- and gone - which is how the first attempt at this reported 0ms for the
    -- thing it was measuring.
    local w = RB.worst_t or { slab = 0, pic = 0, n = 0 }
    if (RB.t_slab or 0) > w.slab then w.slab = RB.t_slab end
    if (RB.t_pic or 0) > w.pic then
        w.pic = RB.t_pic
        w.get, w.apply = RB.t_get or 0, RB.t_apply or 0
    end
    RB.t_get, RB.t_apply = 0, 0
    RB.worst_t = w
    RB.t_slab, RB.t_pic = 0, 0

    -- Chrome rows nobody drew into this frame put away, before the textures.
    RB.tidy_rows()

    -- The draw is over, so drop the textures it was handed. icons builds a map
    -- of them in one sweep to avoid a 9.4ms lookup per tile, and that map is
    -- only safe for as long as the draw that built it - this is the closing
    -- half of that lifetime, and the reason holding the objects is allowed.
    icons.new_frame()

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

    -- The breakdown of the WORST refresh, captured when it happens.
    --
    -- The report printed the worst total beside whatever the LATEST refresh
    -- had spent, so the two never described the same frame - which is how a
    -- 400ms total came to sit beside four buckets reading zero, and why two
    -- rounds of guessing at the cause went nowhere. Snapshotted here instead.
    -- perf_worst is in milliseconds; compare in milliseconds.
    local ms = (os.clock() - t0) * 1000
    if ms > perf_worst then
        perf_worst = ms
        worst_setup, worst_hover, worst_hits = perf_setup, perf_hover, perf_hits
        RB.worst_tail = RB.t_tail and (os.clock() - RB.t_tail) or 0
        worst_stock, worst_draw, worst_blank = perf_stock, perf_draw, perf_blank
    end
    if (os.clock() - perf_at) > 5.0 then
        perf_at = os.clock()
        if perf_worst > 4.0 then
            log.say(string.format(
                "panel refresh worst %.1fms  (setup %.1f, hover %.1f/%d, " ..
                "stock %.1f, draw %.1f, blank %.1f, tail %.1f)",
                perf_worst, worst_setup * 1000, worst_hover * 1000, worst_hits,
                worst_stock * 1000, worst_draw * 1000, worst_blank * 1000,
                (RB.worst_tail or 0) * 1000))
        end
        perf_worst = 0
    end
end

local function blank_everything()
    -- Same rule as refresh: nothing here touches a stored widget until the
    -- root has been validated this frame. M.toggle reaches this directly.
    if not ensure_root() then
        blocks, stripes, images, backdrop = {}, {}, {}, nil
        return
    end

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
            -- Hit tests too. See blank_unused.
            pcall(function() border:SetVisibility(3) end)
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

        -- An open ceiling edit is dropped, not left pending.
        --
        -- refresh() runs poll_amount BEFORE it checks M.open, and main.lua
        -- calls refresh once a second whether the panel is open or not - so
        -- closing the panel mid-edit lost the box's focus and committed a
        -- second later, with the panel already gone. That is the same silent
        -- ceiling change had_focus was added to stop, arriving through the
        -- one door it did not cover.
        editing = nil
        pcall(function() if alive(amount_box) then amount_box:SetVisibility(1) end end)
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

    log.say("Production Limits open, Alt+F1 or Esc to close")
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
        if current == nil then return LADDER[1] end
        for _, n in ipairs(LADDER) do
            if n > current then return n end
        end
        return LADDER[#LADDER]
    end

    if current == nil then return nil end
    local below = nil
    for _, n in ipairs(LADDER) do
        if n < current then below = n end
    end

    -- Clamped, like the top of the ladder already was.
    --
    -- This returned nil below the lowest rung and the caller read nil as
    -- "delete the rule". The top end has always clamped, so stepping up
    -- stopped and stepping down destroyed - and every rule the ADD tab
    -- creates starts on the lowest rung, so every new rule was one right
    -- click from gone, with no confirmation, while the Remove button next to
    -- it asks twice. Deleting belongs to Remove.
    return below or LADDER[1]
end

local function hovered()
    for key, what in pairs(hits) do
        if over_key(key) then
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
-- The tab bar is not somewhere the selection should walk through.
--
-- tab_hits counts the order entries the tab bar owns - the two tabs and the
-- close button - and they are always the first ones. Stepping through them to
-- get anywhere meant that holding down on the last row took several presses
-- to come back round to the first rule, past three controls nobody was
-- navigating towards.
--
-- They are not unreachable: the shoulders switch tabs and B closes, which is
-- how a pad expects to reach chrome anyway, and the mouse still clicks them.
local function is_chrome(i)
    return tab_hits > 0 and i <= tab_hits
end

function M.move(delta)
    if not M.open or #order == 0 then return false end

    local i, guard = sel, 0
    repeat
        i = i + delta
        if i > #order then i = 1 end
        if i < 1 then i = #order end
        guard = guard + 1
        if not is_chrome(i) then sel = i return true end
    until guard > #order

    return false
end

-- One press, one row, whatever the row is made of.
--
-- Lands on the ceiling where a row has one, because that is what left and
-- right act on and what a player is nearly always here to change. Falls back
-- to the row's first entry otherwise.
function M.move_row(delta)
    if not M.open or #order == 0 then return false end

    local from = rows[sel]
    local i, guard = sel, 0

    repeat
        i = i + delta
        if i > #order then i = 1 end
        if i < 1 then i = #order end
        guard = guard + 1

        if rows[i] ~= from and not is_chrome(i) then
            local landed = i
            for j = 1, #order do
                if rows[j] == rows[i] then
                    local what = hits[order[j]]
                    if what and what.kind == "rule" then landed = j break end
                end
            end
            sel = landed
            return true
        end
    until guard > #order

    return false
end

-- Act on part of the selected row without having to walk onto it first.
--
-- With up and down moving a whole row at a time, Remove is no longer somewhere
-- the selection passes through, so a controller needs a way to ask for it
-- directly. This finds the entry of the given kind belonging to the row the
-- selection is on.
function M.row_action(cfg, kind)
    if not M.open then return false end

    local r = rows[sel]
    if r == nil then return false end

    for i = 1, #order do
        if rows[i] == r then
            local what = hits[order[i]]
            if what and what.kind == kind then
                return M.apply(cfg, what, -1)
            end
        end
    end
    return false
end

-- Next or previous tab, for the shoulder buttons.
function M.tab_step(cfg, delta)
    if not M.open then return false end

    local want = (mode == "list") and "item" or "list"
    if delta == nil then delta = 1 end

    for i = 1, #order do
        local what = hits[order[i]]
        if what and what.kind == "tab" and what.mode == want then
            return M.apply(cfg, what, -1)
        end
    end
    return false
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

    -- By row, not by hit. See move_row.
    if what == "up" then return M.move_row(-1) end
    if what == "down" then return M.move_row(1) end
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

    -- Jump straight to a page, for sweeping the picker from outside.
    --
    -- "click page" matches whichever pager hit pairs() yields first, which is
    -- fine on page one where only Next exists and useless anywhere else. An
    -- audit of thirteen pages needs to land on the page it asked for.
    if verb == "page" then
        if mode ~= "item" then return "the picker is not open" end
        local n = tonumber(rest)
        if n == nil then return "usage: page <number>" end
        page = math.max(0, math.floor(n) - 1)
        want_first_row = true
        return "page " .. (page + 1)
    end

    -- The pak experiment's first question: can THIS mod resolve a cooked
    -- widget class at all? Three stages, resolve only, nothing constructed.
    --
    -- Stage three is the one that earns its keep. It resolves a class that is
    -- KNOWN to be cooked and installed - BreedingHelper's WBP_BreedingCalc,
    -- which its own ui.lua loads through AssetRegistryHelpers:GetAsset with a
    -- note that plain LoadAsset returns null wrappers for cooked BP classes
    -- on this build ("verified in-game 2026-07-12"). If that route works in
    -- our hands on their asset, the Lua half of the bridge is proven before
    -- our pak exists, and a failure later can only be in OUR pak. Loading a
    -- class object runs no Blueprint code - Construct scripts belong to
    -- instances, and no instance is made here.
    -- Resolve our own cooked widget class, the way that is known to work.
    --
    -- Synchronous GetAsset is what hung the game on 21 August: on a package
    -- that is not loaded yet it does a synchronous load, and a synchronous
    -- load off the game thread waits on a thread that is waiting on it. The
    -- earlier version of this probe got away with it only because the class
    -- it asked for was already resident - which docs/widget-spec.md warns is
    -- the misleading example, not the proof.
    --
    -- So: on the game thread, through a callback, with FindOrAddFName, and
    -- the two asks spaced apart rather than fired together.
    -- The construction stages, one by one, on a warm world. The world-load
    -- attempt just failed with everything conflated into one message; this
    -- separates library, class and Create, and says which one is the problem
    -- NOW, minutes after load, which also answers whether it was timing.
    -- Fire prepare() by hand. It normally runs at ClientRestart, which a hot
    -- reload does not trigger, so without this the blueprint path can only be
    -- tested by restarting the game - and restarts are exactly what this
    -- whole exercise has been spending too many of.
    -- What identifies a base camp, so "Stopped at 1" can say which one.
    -- Schema only: property and function NAMES off the class, never a call on
    -- an instance. Reading the class is what discover.lua does safely; calling
    -- an unverified name on a live object is what has taken the game down.
    if verb == "camp" then
        local cls = StaticFindObject("/Script/Pal.PalBaseCamp")
        if not cls then return "PalBaseCamp did not resolve" end

        local hits = 0
        pcall(function()
            cls:ForEachProperty(function(p)
                local n, t = "", ""
                pcall(function() n = p:GetFName():ToString() end)
                pcall(function() t = p:GetClass():GetFName():ToString() end)
                local low = n:lower()
                if low:find("name") or low:find("location") or low:find("transform")
                    or low:find("level") or low:find("rank") or low:find("id") then
                    hits = hits + 1
                    log.say("  prop " .. t .. " " .. n)
                end
            end)
        end)
        pcall(function()
            cls:ForEachFunction(function(f)
                local n = ""
                pcall(function() n = f:GetFName():ToString() end)
                local low = n:lower()
                if low:find("name") or low:find("location") or low:find("level") then
                    hits = hits + 1
                    log.say("  fn   " .. n)
                end
            end)
        end)
        return "camp probe done, " .. hits .. " candidate(s)"
    end

    if verb == "geom" then
        local parts = overlay.parts
        log.say("  overlay.width: " .. tostring(overlay.width))
        log.say("  parts: " .. tostring(parts ~= nil))
        if parts then
            local bs, rs = "?", "?"
            pcall(function()
                local s = parts.Backdrop.Slot
                bs = tostring(s ~= nil) .. " cls=" ..
                    (s and s:GetClass():GetFName():ToString() or "-")
            end)
            pcall(function()
                local s = parts.RuleList.Slot
                rs = tostring(s ~= nil) .. " cls=" ..
                    (s and s:GetClass():GetFName():ToString() or "-")
            end)
            log.say("  Backdrop.Slot: " .. bs)
            log.say("  RuleList.Slot: " .. rs)
            local ok = pcall(function()
                parts.Backdrop.Slot:SetSize({ X = 1086, Y = 700 })
            end)
            log.say("  SetSize direct: " .. tostring(ok))
            local ok2 = pcall(function()
                parts.RuleList.Slot:SetPadding(
                    { Left = 0, Top = 200, Right = 0, Bottom = 0 })
            end)
            log.say("  SetPadding direct: " .. tostring(ok2))
        end
        return "geom probe done"
    end

    if verb == "host" then
        if not overlay.prepare then return "this build cannot do that" end
        overlay.prepare()
        return "asked; the answer lands in the log a moment from now"
    end

    if verb == "create" then
        local out = {}
        local pc = api.player_controller()
        out[#out+1] = "pc: " .. tostring(pc ~= nil)

        local lib = api.cdo("/Script/UMG.Default__WidgetBlueprintLibrary")
        out[#out+1] = "library cdo: " .. tostring(lib ~= nil)

        local cls
        pcall(function()
            cls = StaticFindObject(
                "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules.WBP_WorkRules_C")
        end)
        local cls_ok = false
        pcall(function() cls_ok = cls ~= nil and cls:IsValid() end)
        out[#out+1] = "class resident: " .. tostring(cls_ok)

        if pc ~= nil and lib ~= nil and cls_ok then
            local made, err
            local ok = pcall(function() made = lib:Create(pc, cls, pc) end)
            if not ok then err = "threw" end
            local alive_ok = false
            pcall(function() alive_ok = made ~= nil and made:IsValid() end)
            out[#out+1] = "Create: ok=" .. tostring(ok) ..
                " alive=" .. tostring(alive_ok) .. (err and (" " .. err) or "")
            if alive_ok then
                local nm = "?"
                pcall(function() nm = made:GetFullName() end)
                out[#out+1] = "made: " .. nm
                local tree
                pcall(function() tree = made.WidgetTree end)
                local tree_ok = false
                pcall(function() tree_ok = tree ~= nil and tree:IsValid() end)
                out[#out+1] = "tree: " .. tostring(tree_ok)
                local root
                pcall(function() root = made.Root end)
                local root_ok = false
                pcall(function() root_ok = root ~= nil and root:IsValid() end)
                out[#out+1] = "made.Root property: " .. tostring(root_ok)
            end
        end

        for _, l in ipairs(out) do log.say("  " .. l) end
        return "create probe done"
    end

    if verb == "cooked" then
        if not overlay.mod_class then
            return "this build has no mod_class, reload overlay first"
        end

        local function try(label, package, asset)
            overlay.mod_class(package, asset, function(class)
                local full
                if class ~= nil then
                    pcall(function() full = class:GetFullName() end)
                end
                log.say(string.format("  %-14s %s", label,
                    full or "not found through the registry"))
            end)
        end

        -- ModActor first, and it is the CONTROL rather than the result:
        -- BPModLoaderMod loads it seconds after the pak mounts, so it answers
        -- from memory. If it resolves and the widget does not, the fault is
        -- in the asset, not the route.
        try("ModActor", "/Game/Mods/PalWorkPriority/ModActor", "ModActor_C")

        ExecuteWithDelay(1500, function()
            try("WBP_WorkRules",
                "/Game/Mods/PalWorkPriority/UI/WBP_WorkRules",
                "WBP_WorkRules_C")
        end)

        return "asked for both classes, answers follow in the log"
    end


    -- Whether the input mode is still ours. Lives here for the same reason
    -- `icons` does, and is guarded the same way: this module reloads, and a
    -- reload into a session whose overlay predates input_report would take the
    -- command down rather than answer it.
    -- The way out when the panel has left the game in UI input mode.
    if verb == "unstick" then
        if not overlay.force_release then return "this build cannot do that" end
        M.open = false
        return overlay.force_release()
    end

    if verb == "input" then
        if not overlay.input_report then return "this build cannot report that" end
        return overlay.input_report()
    end

    -- The gamepad probe, reachable without restarting the game.
    --
    -- It belongs on "pwp pad" and that is where it will live. But that command
    -- sits in main.lua, which is not swappable, so reaching it costs a restart
    -- and a restart is the one thing that hides the answer: the question is
    -- whether polling still reads input while the panel holds the UI route,
    -- and that state only exists in a session that has been driving the panel.
    --
    -- Required here rather than at the top of the file, because pad is new and
    -- a session whose panel predates it must not lose this whole command to a
    -- missing module.
    -- Which input route the panel holds while open, so both can be measured.
    if verb == "route" then
        if rest == "gameandui" then overlay.prefer_ui_only = false
        elseif rest == "uionly" then overlay.prefer_ui_only = true
        elseif rest ~= nil then return "use: route gameandui | route uionly" end
        if not overlay.reapply_input then return "this build cannot do that" end
        return overlay.reapply_input()
    end

    -- The way out if a close ever fails to give the character back.
    if verb == "pawn" then
        if not overlay.release_pawn then return "this build cannot do that" end
        return overlay.release_pawn()
    end

    -- Is the gate seeing anything at all?
    --
    -- The cursor fix rests on api.game_ui_active being written by main.lua's
    -- hook. If that value is nil the hook never fired, which would mean the
    -- game does not call IsAnyOverlayUIActive for the inventory, and the fix
    -- was built on a reading that never happens.
    -- Is the driver actually there, and is it being called?
    if verb == "drive" then
        local have = (type(RB.pad) == "table")
        local out = "pad driver " .. (have and "loaded" or "NOT LOADED")
            .. ", drive=" .. tostring(have and type(RB.pad.drive) == "function")
            .. ", panel open=" .. tostring(M.open)
        log.say(out)
        return out
    end

    if verb == "ui" then
        local out = "api.game_ui_active = " .. tostring(api.game_ui_active)

        -- Asked directly as well, so "the hook never fires" and "the hook
        -- fires and the answer is false" can be told apart.
        local hud, direct
        pcall(function() hud = FindFirstOf("PalHUDInGame") end)
        if hud == nil then pcall(function() hud = FindFirstOf("PalHUDService") end) end
        if hud ~= nil then
            pcall(function() direct = hud:IsAnyOverlayUIActive() end)
            out = out .. ", direct = " .. tostring(direct)
        else
            out = out .. ", no HUD found"
        end

        log.say(out)
        return out
    end

    -- What the pointer is actually over, and what the panel thinks it owns.
    --
    -- "Only the text is clickable, not the bar" has survived two fixes that
    -- both looked right in the source, so this reports the geometry rather
    -- than reasoning about it again.
    if verb == "hover" then
        log.say("hover_key = " .. tostring(hover_key))

        -- EVERYTHING under the pointer, not just the key being blamed.
        --
        -- The add-bar ghost was a second widget at identical coordinates that
        -- nobody thought to look for, and it cost two wrong fixes before an
        -- agent found it by reading. Asking Slate directly which widgets say
        -- they are hovered finds that class of bug in one reading.
        local hot = {}
        pcall(function()
            for k, w in pairs(stripes) do
                if alive(w) then
                    local h
                    pcall(function() h = w:IsHovered() end)
                    if h then hot[#hot + 1] = "stripe " .. k end
                end
            end
            for k, w in pairs(blocks) do
                if alive(w) then
                    local h
                    pcall(function() h = w:IsHovered() end)
                    if h then hot[#hot + 1] = "text " .. k end
                end
            end
        end)

        if #hot == 0 then
            log.say("  NOTHING under the pointer")
        else
            log.say("  under the pointer, " .. #hot .. ":")
            for _, name in ipairs(hot) do
                -- Marked when the panel would not act on it, which is the
                -- shape of the bug: hovered, but not a key this screen owns.
                local key = name:match("^%a+ (.+)$")
                local owned = (key ~= nil and hits[key] ~= nil)
                log.say("    " .. name .. (owned and "  <- clickable" or ""))
            end
        end

        local key = rest or "new"
        local face = tile_face[key]
        log.say("  tile_face[" .. key .. "] alive = " .. tostring(alive(face)))

        if alive(face) then
            local hovered, vis
            pcall(function() hovered = face:IsHovered() end)
            pcall(function() vis = face:GetVisibility() end)
            log.say("  hovered = " .. tostring(hovered)
                .. ", visibility = " .. tostring(vis) .. " (0 is hit testable)")

            local slot, pos, size
            pcall(function() slot = face.Slot end)
            if alive(slot) then
                pcall(function() pos = slot:GetPosition() end)
                pcall(function() size = slot:GetSize() end)
                if pos then log.say(string.format("  at %.0f,%.0f", pos.X, pos.Y)) end
                if size then log.say(string.format("  size %.0fx%.0f", size.X, size.Y)) end
            end
        end

        local block = blocks[key]
        log.say("  blocks[" .. key .. "] alive = " .. tostring(alive(block)))
        return "hover report in the log"
    end

    if verb == "pad" then
        -- loadfile, not require, and clearing package.loaded is not enough
        -- either. UE4SS keeps the chunk it compiled at startup, so require
        -- hands back the code from before the edit while reporting no error
        -- at all. reload.lua carries the long version of this, having found
        -- it the hard way; the first draft here repeated the same mistake and
        -- a version marker in the file is what caught it.
        --
        -- The watch entry is keyed by a constant name, so a copy loaded here
        -- can still cancel a watch an older copy started.
        local pad = package.loaded["pad"]

        local rl = package.loaded["reload"]
        local dir = rl and rl.scripts_dir
        if dir then
            local chunk = loadfile(dir .. "pad.lua")
            if chunk then
                local built, result = pcall(chunk)
                if built and type(result) == "table" then
                    pad = result
                    package.loaded["pad"] = result
                end
            end
        end

        if type(pad) ~= "table" then
            local got, req = pcall(require, "pad")
            pad = (got and type(req) == "table") and req or nil
        end
        if type(pad) ~= "table" then
            return "no pad module in this session"
        end
        if rest == "probe" then return pad.probe() end
        if rest == "watch" or rest == "watch on" then return pad.watch(true) end
        if rest == "watch off" then return pad.watch(false) end
        return "use: pad probe | pad watch | pad watch off"
    end

    -- One sweep against N lookups, for the picker's remaining lag.
    -- What a FindAllOf costs, per class, in this process.
    --
    -- Every mod here pays whatever this says: with bUseUObjectArrayCache off
    -- in UE4SS-settings.ini, FindAllOf walks the global object array rather
    -- than a per-class index. If that is so, the cost tracks the TOTAL number
    -- of objects and barely notices how many match - which would mean a
    -- one-object class costs the same as a seven thousand object one, and
    -- every mod that sweeps pays the same toll we do.
    -- The hover scan, timed alone and repeated, so the per-frame budget of a
    -- native-rate hover loop is a number rather than a guess.
    if verb == "hoverbench" then
        if not M.open then return "open the panel first" end
        local t0 = os.clock()
        local n = 0
        for _ = 1, 100 do
            for key in pairs(was_hit or {}) do
                n = n + 1
                if over_key(key) then break end
            end
        end
        local ms = (os.clock() - t0) * 1000
        return string.format("100 scans over %d widgets: %.1fms total, %.3fms per scan",
            n, ms, ms / 100)
    end

    -- Per row state, for the chrome collapse that follows repeated reloads.
    if verb == "rows" then
        local parts = overlay.parts
        if not parts then return "no parts at all" end

        -- Which widget these parts actually belong to, against the canvas the
        -- panel is drawing into. If a reload left the two disagreeing, that is
        -- the answer on its own.
        local function owner_of(w)
            local n = "nil"
            if w ~= nil then
                pcall(function() n = w:GetFullName() end)
            end
            return tostring(n):match("(WBP_WorkRules_C_%d+)") or tostring(n)
        end
        log.say("  parts.Root belongs to: " .. owner_of(parts.Root))
        log.say("  drawing into:          " .. owner_of(root))

        local on = RB.on_last or {}
        for _, row in ipairs(RB.rows) do
            local name = row[1]
            local slot, wrapper = parts[name], parts[name .. "Row"]
            log.say(string.format(
                "  %-8s slot %-5s row %-5s used %-5s host %s",
                name,
                tostring(alive(slot)), tostring(alive(wrapper)),
                tostring(on[name] == true),
                tostring(RB.hosts[name .. ":0"] ~= nil)))
        end
        for _, name in ipairs({ "ItemList", "RuleList" }) do
            log.say(string.format("  %-8s slot %-5s row %-5s", name,
                tostring(alive(parts[name])),
                tostring(alive(parts[name .. "Row"]))))
        end
        return "row report done"
    end

    -- Candidate cheap routes to the player controller. Read-only, every
    -- object taken from the call it is used in, nothing stored.
    if verb == "routes" then
        local function timed(name, fn)
            local got, t = nil, os.clock()
            for _ = 1, 5 do
                local r
                pcall(function() r = fn() end)
                got = r
            end
            local ms = (os.clock() - t) * 1000 / 5
            local nm = "nil"
            if got ~= nil then
                pcall(function() nm = got:GetFName():ToString() end)
            end
            log.say(string.format("  %-34s %6.2fms  %s", name, ms, nm))
        end

        timed("FindFirstOf PalPlayerController", function()
            return FindFirstOf("PalPlayerController")
        end)
        timed("UEHelpers.GetPlayerController", function()
            local ue = require("UEHelpers")
            return ue.GetPlayerController()
        end)
        timed("UEHelpers.GetEngine", function()
            local ue = require("UEHelpers")
            return ue.GetEngine()
        end)
        timed("Engine.GameViewport", function()
            local ue = require("UEHelpers")
            return ue.GetEngine().GameViewport
        end)
        timed("GameViewport.World", function()
            local ue = require("UEHelpers")
            return ue.GetEngine().GameViewport.World
        end)
        timed("World.OwningGameInstance", function()
            local ue = require("UEHelpers")
            return ue.GetEngine().GameViewport.World.OwningGameInstance
        end)
        timed("GameInstance.LocalPlayers[1]", function()
            local ue = require("UEHelpers")
            return ue.GetEngine().GameViewport.World
                .OwningGameInstance.LocalPlayers[1]
        end)
        timed("LocalPlayer.PlayerController", function()
            local ue = require("UEHelpers")
            return ue.GetEngine().GameViewport.World
                .OwningGameInstance.LocalPlayers[1].PlayerController
        end)
        log.say(string.format("  engine-chain misses this session: %d",
            api.pc_fallbacks or -1))
        return "route probe done"
    end

    if verb == "sweeps" then
        local classes = {
            "Texture2D", "UserWidget", "Actor", "PalPlayerController",
            "PalMapObjectItemChestModel", "PalNetworkTransmitter",
            "WidgetTree", "PalIndividualCharacterParameter",
        }
        log.say("FindAllOf cost by class:")
        for _, cls in ipairs(classes) do
            local t0 = os.clock()
            local found
            pcall(function() found = FindAllOf(cls) end)
            local ms = (os.clock() - t0) * 1000
            log.say(string.format("  %-32s %5.1fms  %d object(s)",
                cls, ms, found and #found or 0))
        end
        -- FindFirstOf can stop at the first match. Whether it does is the
        -- difference between the overlay's per-refresh owner check being
        -- free and it being a tenth of the frame budget, ten times a second.
        log.say("FindFirstOf, for comparison:")
        for _, cls in ipairs({ "PalPlayerController", "Texture2D" }) do
            local t0 = os.clock()
            pcall(function() return FindFirstOf(cls) end)
            log.say(string.format("  %-32s %5.1fms",
                cls, (os.clock() - t0) * 1000))
        end

        -- And what the overlay actually does every refresh.
        local t0 = os.clock()
        pcall(function()
            local pc = FindFirstOf("PalPlayerController")
            if pc then return pc:GetFullName() end
        end)
        log.say(string.format("  owner_name() equivalent          %5.1fms",
            (os.clock() - t0) * 1000))

        return "findallof cost measured"
    end

    if verb == "bench" then
        local p = RB.last_prof or {}
        log.say("primitive calls in the last draw:")
        for _, k in ipairs({ "slab", "text", "pic" }) do
            log.say(string.format("  %-5s %d", k, (p[k] and p[k].n) or 0))
        end
        local t = RB.worst_t or {}
        log.say(string.format("  worst draw: slab %.0fms, picture %.0fms",
            (t.slab or 0) * 1000, (t.pic or 0) * 1000))
        log.say(string.format("    of which icons.get %.0fms, apply_texture %.0fms",
            (t.get or 0) * 1000, (t.apply or 0) * 1000))
        RB.worst_t = nil
        if not icons.bench then return "counts above" end
        return icons.bench()
    end

    -- What has no icon, from the inside. Lives here rather than in main.lua's
    -- command table because this module reloads and that one does not.
    if verb == "icons" then
        if not icons.unresolved then return "this build cannot report that" end
        local dead, waiting = icons.unresolved()
        log.say(string.format("icons: %d gave up, %d still loading",
            #dead, #waiting))
        log.say(string.format("  loads: %d, worst %.0fms, average %.1fms",
            icons.loads or 0, icons.worst_load or 0,
            (icons.loads or 0) > 0 and (icons.load_ms / icons.loads) or 0))
        log.say(string.format("  finds: %d, worst %.0fms, average %.2fms, total %.0fms",
            icons.finds or 0, icons.worst_find or 0,
            (icons.finds or 0) > 0 and (icons.find_ms / icons.finds) or 0,
            icons.find_ms or 0))
        for _, id in ipairs(dead) do log.say("  no icon: " .. id) end
        for _, id in ipairs(waiting) do log.say("  waiting: " .. id) end
        return string.format("%d without an icon", #dead)
    end

    -- Read-only reconnaissance for the crafting question.
    --
    -- Answers whether a workbench's production queue is reachable at all
    -- before anything is built on the assumption that it is. Nothing here
    -- changes game state: it sweeps the map objects the stock counter already
    -- sweeps, reports the distinct class names, and for the first station
    -- that looks like a producer it lists property and function NAMES only -
    -- the same "names and types, never values" shape discover.lua uses, for
    -- the same reason.
    --
    -- Lives here because panel.lua hot-reloads and discover.lua does not, so
    -- the probe can be refined without restarting the game.
    if verb == "craft" then
        local seen, order_seen = {}, {}
        local sample = nil

        pcall(function()
            for _, o in ipairs(FindAllOf("PalMapObjectConcreteModelBase") or {}) do
                if alive(o) then
                    local cname
                    pcall(function() cname = o:GetClass():GetFName():ToString() end)
                    if cname then
                        if seen[cname] == nil then
                            seen[cname] = 0
                            order_seen[#order_seen + 1] = cname
                        end
                        seen[cname] = seen[cname] + 1

                        -- Named, or asked for, rather than guessed at.
                        --
                        -- The first version took whichever class matched any
                        -- of product, craft, work or recipe first, and
                        -- "PalMapObjectBaseCampPassiveWorkHardModel" matches
                        -- on "work" - so it probed a passive work station
                        -- while four PalMapObjectProductItemModel benches,
                        -- the things that actually hold a craft queue, sat
                        -- right beside it in the same sweep.
                        local low = cname:lower()
                        local want = rest
                        if want then
                            if sample == nil and low == want:lower() then
                                sample = o
                            end
                        elseif sample == nil and low:find("productitem") then
                            sample = o
                        end
                    end
                end
            end
        end)

        table.sort(order_seen)
        log.say("map object classes in this base:")
        for _, cname in ipairs(order_seen) do
            log.say(string.format("  %-52s x%d", cname, seen[cname]))
        end

        if sample == nil then
            return "no producer-looking map object found"
        end

        local sname
        pcall(function() sname = sample:GetClass():GetFName():ToString() end)
        log.say("looking at " .. tostring(sname) .. ":")

        pcall(function()
            sample:GetClass():ForEachProperty(function(pr)
                local n
                pcall(function() n = pr:GetFName():ToString() end)
                if n then log.say("  prop " .. n) end
            end)
        end)
        pcall(function()
            sample:GetClass():ForEachFunction(function(fn)
                local n
                pcall(function() n = fn:GetFName():ToString() end)
                if n then log.say("  func " .. n) end
            end)
        end)

        -- The inheritance chain is not worth walking; it was, once, and it
        -- answered. PalMapObjectProductItemModel derives from
        -- PalMapObjectConcreteModelBase and then straight from Object, and
        -- neither declares anything matching product, craft, recipe, set or
        -- request. Nothing inherited can change what a bench makes.
        --
        -- That walk also took the game down on 23 August: the loop stopped on
        -- a nil or self-referencing super but never checked the answer was a
        -- VALID object, so one step past Object it called ForEachFunction on
        -- something that was neither. The rule this whole codebase is built
        -- on - validate before you touch - applies to a probe exactly as much
        -- as to a pass.

        -- And whatever the crafting UI actually sends through.
        --
        -- Setting a bench's product is a player action, and every other base
        -- camp action this mod uses turns out to be a RequestX_ToServer on a
        -- native class rather than a call on the model.
        --
        -- Asked of the NATIVE classes by path, not of pc:GetClass(). The
        -- first version did the latter and got an empty list, which reads as
        -- "no such function" and is not: pc:GetClass() is
        -- BP_PalPlayerController_C, and the RPCs are declared on the
        -- /Script/Pal parent it derives from. An enumeration is only as
        -- honest as the thing it enumerates.
        for _, path in ipairs({
            "/Script/Pal.PalPlayerController",
            "/Script/Pal.PalNetworkBaseCampComponent",
            "/Script/Pal.PalPlayerState",
        }) do
            log.say("[" .. path .. "]")
            local hits = 0
            pcall(function()
                local cls = StaticFindObject(path)
                if not api.valid(cls) then
                    log.say("    class not found")
                    return
                end
                cls:ForEachFunction(function(fn)
                    local fname
                    pcall(function() fname = fn:GetFName():ToString() end)
                    if fname then
                        local l = fname:lower()
                        if l:find("product") or l:find("craft")
                            or l:find("recipe") then
                            log.say("    func " .. fname)
                            hits = hits + 1
                        end
                    end
                end)
            end)
            if hits == 0 then log.say("    nothing craft shaped") end
        end

        return "probed " .. tostring(sname)
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
            caps.clear(job, item, mine())
        else
            caps.set(job, item, n, mine())
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
        announce("picking an item, type to filter or click one")
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

    -- The rules list keeps its own page. Sharing the picker's would carry a
    -- position across a tab switch, so opening ADD on page two of the rules
    -- would show page two of the items.
    if what.kind == "rpage" then
        RB.rule_page = RB.rule_page + what.by
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

        -- An item that already has a rule is not clicked to be overwritten.
        --
        -- This wrote LADDER[1] unconditionally, so clicking a row that
        -- visibly says LIMIT SET replaced whatever was there with 100 - one
        -- click, no confirmation, and the only visible state on the row was
        -- "you have already done this". Now it takes you to the rule instead,
        -- which is where changing it belongs.
        local existing = (caps.all(cfg, mine())[work] or {})[what.item]
        if existing ~= nil then
            announce(string.format(
                "%s already stops at %d %s - the RULES tab is where to change it",
                workdefs.label(work), existing, what.item))
            mode = "list"
            want_first_row = true
            return true
        end

        -- Seeded above what the base already holds, not at the bottom rung.
        --
        -- LADDER[1] is 100. Clicking Stone on a base holding twenty thousand
        -- of it set a ceiling of 100 and suspended Mining on the spot, from a
        -- tab whose caption says "click an item to limit it" - which does not
        -- read as "stop this job now". A ceiling one rung above current stock
        -- creates the rule the click asked for and leaves the job running
        -- until the player chooses a real number.
        local have = (stock_totals(cfg) or {})[what.item] or 0
        local seed = LADDER[1]
        for _, n in ipairs(LADDER) do
            if n > have then
                seed = n
                break
            end
            seed = LADDER[#LADDER]
        end

        caps.set(work, what.item, seed, mine())
        announce(string.format("rule added: %s stops at %d %s (%d in storage)",
            workdefs.label(work), seed, what.item, have))
        M.wants_pass = true
        mode = "list"
        want_first_row = true
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

        -- Moving a rule to another job is a clear and then a set, and either
        -- half can refuse. Both answers used to be discarded and the move
        -- announced regardless, which produced two different lies.
        --
        -- A rule from before guild scoping is drawn as an ordinary row,
        -- because merged_for layers the wildcard in - but clear refuses it,
        -- since it belongs to every guild that has not set its own. The set
        -- then succeeded, and the item ended up capped under BOTH jobs while
        -- the panel said it had moved.
        --
        -- On a client the two halves are two separate requests against a
        -- budget of ten per ten seconds. At nine, the clear lands and the set
        -- is dropped: the ceiling is gone entirely and the panel still says it
        -- moved.
        --
        -- The drop branch below already learned this - "This used to discard
        -- it and say 'rule removed' either way" - and this branch was missed.
        if not caps.clear(rule.work, rule.item, mine()) then
            announce(string.format(
                "could not move the limit on %s: it is not your guild's " ..
                "rule, it applies to every guild that has not set its own",
                rule.item))
            return true
        end

        if not caps.set(moved, rule.item, rule.amount, mine()) then
            -- The clear already happened, so the rule is gone rather than
            -- moved. Said plainly, with the number, because re-adding it by
            -- hand is the only way back and the player needs to know both
            -- halves of what to type.
            announce(string.format(
                "the %s limit on %s was removed but could not be set on %s: " ..
                "add it again with a ceiling of %d",
                workdefs.label(rule.work), rule.item,
                workdefs.label(moved), rule.amount))
            M.wants_pass = true
            return true
        end

        if caps.submit then
            announce("asked the server to move the limit on " .. rule.item ..
                " to " .. workdefs.label(moved))
        else
            announce(rule.item .. " is now made by " .. workdefs.label(moved))
        end
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
            announce("Click Remove again to delete the " ..
                workdefs.label(rule.work) .. " limit on " .. rule.item)
            return true
        end

        pending_drop = nil

        -- The answer is read rather than assumed.
        --
        -- This used to discard it and say "rule removed" either way. A rule
        -- inherited from before guild scoping lives under the wildcard, not
        -- under this guild, so clearing it finds nothing and refuses - and
        -- the panel reported success anyway, then redrew the rule still
        -- sitting there. Measured on 23 August: the client said removed, the
        -- server logged nothing, and caps.txt was unchanged.
        if not caps.clear(what.rule.work, what.rule.item, mine()) then
            announce(string.format(
                "could not remove the %s limit on %s: it is not your " ..
                "guild's rule, it applies to every guild that has not set " ..
                "its own",
                workdefs.label(what.rule.work), what.rule.item))
            return true
        end

        -- On a client, caps.clear answers whether the request was SENT, not
        -- whether the server took it - the server decides, and may refuse a
        -- rule this guild does not own. Saying "removed" there would be the
        -- same false claim in a new place, so the wording matches what is
        -- actually known, and the server pushes its rules back either way so
        -- the panel redraws the truth a moment later.
        if caps.submit then
            announce("asked the server to remove the " ..
                workdefs.label(what.rule.work) .. " limit on " ..
                what.rule.item)
        else
            announce("rule removed: " .. workdefs.label(what.rule.work) ..
                " " .. what.rule.item)
        end
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

        -- A step can no longer delete. step() clamps at both ends now, so
        -- nil means the rule has no amount at all rather than "you have gone
        -- past the bottom", and the answer to that is to do nothing. This
        -- branch used to clear the rule outright: every rule the ADD tab
        -- creates starts on the lowest rung, so a single right click removed
        -- it, with no confirmation, while the Remove button beside it asks
        -- twice.
        if next_amount == nil then
            return true
        elseif next_amount == rule.amount then
            announce(string.format(
                "%s %s is already at the %s limit the ladder offers",
                workdefs.label(rule.work), rule.item,
                dir < 0 and "highest" or "lowest"))
        else
            caps.set(rule.work, rule.item, next_amount, mine())
            -- Announced, like every other way a rule can change.
            --
            -- Typing a ceiling says so, removing one says so, and stepping
            -- the ladder said nothing at all - the limit moved and the only
            -- evidence was the number redrawing. That matters most for the
            -- case it hides: these steps are bound to the mouse buttons
            -- globally, with no modifier list, so they fire whenever the
            -- panel is open and the cursor is over a row. A rule that changes
            -- without the player meaning it should at least be traceable.
            announce(string.format("%s %s limit stepped to %d",
                workdefs.label(rule.work), rule.item, next_amount))
        end
        M.wants_pass = true
        return true
    end

    return false
end

return M
