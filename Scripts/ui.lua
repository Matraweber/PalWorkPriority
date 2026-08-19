-- A read-only panel on the Monitoring Stand.
--
-- Shows what the last pass decided: which pal is on which work, the mode and
-- cap in force, and the summary counts. Nothing here is editable yet — the
-- point is to see the scheduler's reasoning where the work actually is,
-- instead of reading UE4SS.log after the fact.
--
-- Injection technique verified against PalPriority's UI mod on this build:
-- Blueprint classes need the _C suffix for FindAllOf, a widget is built with
-- StaticConstructObject against /Script/UMG.TextBlock owned by the menu's
-- WidgetTree, and FText construction has two possible paths depending on the
-- UE4SS build.

local log = require("log")
local api = require("palapi")

local M = {}

-- The work-suitability preference menu, which is what the Monitoring Stand
-- opens. Blueprint-generated, so the _C suffix is required or FindAllOf
-- silently returns nothing.
M.MENU_CLASS = "WBP_WorkSuitabilityPreferenceMenu_C"

local panel = nil          -- our TextBlock while the menu is open
local panel_menu = nil     -- the menu instance it belongs to
local last_text = nil
local ftext_mode = nil     -- "direct" | "kismet"
local warned = {}

local function warn_once(key, message)
    if warned[key] then return end
    warned[key] = true
    log.warn(message)
end

-- Dropped whenever the menu closes or the world changes: a widget reference
-- must never outlive the tree that owns it.
function M.detach()
    panel = nil
    panel_menu = nil
    last_text = nil
end

function M.reset()
    M.detach()
    ftext_mode = nil
    warned = {}
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

local function make_ftext(str)
    if ftext_mode == "direct" or ftext_mode == nil then
        local ft
        local ok = pcall(function() ft = FText(str) end)
        if ok and ft then
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

    warn_once("ftext", "no working FText path on this build — the stand panel cannot render")
    return nil
end

-- ---------------------------------------------------------------------------
-- Finding somewhere to put it
-- ---------------------------------------------------------------------------

local function find_menu()
    local found
    pcall(function()
        for _, m in ipairs(FindAllOf(M.MENU_CLASS) or {}) do
            if api.valid(m) and found == nil then found = m end
        end
    end)
    return found
end

-- Adds the widget to whatever the menu root will accept. The three calls are
-- different UMG container APIs; which one applies depends on what the
-- Blueprint used for its root, and that is not something to assume.
local function add_to_root(root, widget)
    local slot
    if pcall(function() slot = root:AddChildToCanvas(widget) end) and slot then
        -- Anchored top-left with a small inset. Auto-size so the block grows
        -- with the number of assignments rather than clipping them.
        pcall(function()
            slot:SetAutoSize(true)
            slot:SetPosition({ X = 40.0, Y = 40.0 })
        end)
        return "canvas"
    end

    if pcall(function() slot = root:AddChildToOverlay(widget) end) and slot then
        pcall(function()
            slot:SetHorizontalAlignment(0)
            slot:SetVerticalAlignment(0)
        end)
        return "overlay"
    end

    local ok = pcall(function() root:AddChild(widget) end)
    if ok then return "plain" end

    return nil
end

local function attach(menu)
    local tree
    pcall(function() tree = menu.WidgetTree end)
    if not api.valid(tree) then
        warn_once("tree", "stand menu has no readable WidgetTree — panel unavailable")
        return false
    end

    local root
    pcall(function() root = tree.RootWidget end)
    if not api.valid(root) then
        warn_once("root", "stand menu has no readable RootWidget — panel unavailable")
        return false
    end

    local cls = api.cdo("/Script/UMG.TextBlock")
    if not cls then
        warn_once("tbclass", "UMG.TextBlock not found — panel unavailable")
        return false
    end

    local tb
    pcall(function() tb = StaticConstructObject(cls, tree) end)
    if not api.valid(tb) then
        warn_once("construct", "could not construct the panel TextBlock")
        return false
    end

    local how = add_to_root(root, tb)
    if not how then
        warn_once("add", "nothing on the stand menu root accepted a child — " ..
            "run '!pwp discover' for a widget tree dump")
        return false
    end

    -- HitTestInvisible: the panel must never eat a click meant for the menu
    -- underneath it.
    pcall(function() tb:SetVisibility(3) end)
    pcall(function()
        tb:SetColorAndOpacity({
            SpecifiedColor = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
            ColorUseRule = 0,
        })
    end)

    panel = tb
    panel_menu = menu
    last_text = nil
    log.debug("stand panel attached via " .. how)
    return true
end

-- ---------------------------------------------------------------------------
-- Content
-- ---------------------------------------------------------------------------

local function pad(s, n)
    s = tostring(s)
    if #s >= n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

-- Builds the panel text from the last pass. Kept deliberately plain: this is
-- for reading the scheduler's decisions, not for decoration.
function M.compose(cfg, report)
    local out = {}

    out[#out + 1] = string.format("PAL WORK PRIORITY   %s   %s   cap %s",
        cfg.enabled and (cfg.dry_run and "DRY RUN" or "LIVE") or "OFF",
        cfg.assignment_mode,
        cfg.max_pals_per_work_type and tostring(cfg.max_pals_per_work_type) or "-")

    if not report or not report.lines then
        out[#out + 1] = ""
        out[#out + 1] = "no pass has run yet"
        return table.concat(out, "\n")
    end

    out[#out + 1] = ""

    if #report.lines == 0 then
        out[#out + 1] = "nothing assigned this pass"
    else
        for _, e in ipairs(report.lines) do
            out[#out + 1] = string.format("%s p%d  %s r%s",
                pad(e.label, 22), e.prio, pad(e.pal, 18), tostring(e.rank))
        end
    end

    if report.summary and report.summary ~= "" then
        out[#out + 1] = ""
        out[#out + 1] = report.summary
    end

    return table.concat(out, "\n")
end

-- Attaches if the menu is open, updates the text if it changed. Returns true
-- while the panel is live. Cheap enough to call on a short timer, and does
-- nothing at all when the stand is closed.
function M.refresh(cfg, report)
    local menu = find_menu()
    if not menu then
        if panel_menu ~= nil then M.detach() end
        return false
    end

    if panel_menu ~= menu or not api.valid(panel) then
        M.detach()
        if not attach(menu) then return false end
    end

    local text = M.compose(cfg, report)
    if text == last_text then return true end

    local ft = make_ftext(text)
    if not ft then return false end

    local ok = pcall(function() panel:SetText(ft) end)
    if ok then last_text = text end
    return ok
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Walks the open menu's widget tree. Only useful when injection failed and
-- the root turned out to be something none of the three add calls accept.
function M.dump(f)
    f:write("=== monitoring stand menu (" .. M.MENU_CLASS .. ")\n")

    local menu = find_menu()
    if not menu then
        f:write("  menu not open — open the Monitoring Stand and dump again\n")
        return
    end

    local tree, root
    pcall(function() tree = menu.WidgetTree end)
    pcall(function() if tree then root = tree.RootWidget end end)

    f:write("  tree: " .. tostring(api.valid(tree)) ..
        "  root: " .. tostring(api.valid(root)) .. "\n")
    if not api.valid(root) then return end

    pcall(function() f:write("  root class: " .. root:GetFullName() .. "\n") end)

    local function walk(widget, depth)
        if depth > 6 or not api.valid(widget) then return end
        local n = 0
        pcall(function() n = widget:GetChildrenCount() end)
        for i = 0, n - 1 do
            pcall(function()
                local child = widget:GetChildAt(i)
                if api.valid(child) then
                    local name = "?"
                    pcall(function() name = child:GetFullName() end)
                    f:write(string.rep("  ", depth + 1) .. name .. "\n")
                    walk(child, depth + 1)
                end
            end)
        end
    end

    walk(root, 1)
end

return M
