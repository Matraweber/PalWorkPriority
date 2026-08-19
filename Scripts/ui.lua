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

-- FindAllOf turns up every object of the class still in memory: the class
-- default object, and any instance the game has finished with but not yet
-- collected. Only one of them is the live menu, and the rest answer
-- WidgetTree with nothing — which is what the first field run hit, taking
-- the first valid object and giving up when it had no tree.
--
-- So pick by usability rather than by being first, and return the tree and
-- root along with it since they had to be resolved anyway.
local function usable_menu()
    local menu, tree, root
    local rejected, total = 0, 0

    pcall(function()
        for _, m in ipairs(FindAllOf(M.MENU_CLASS) or {}) do
            total = total + 1

            if menu == nil and api.valid(m) then
                local name = ""
                pcall(function() name = m:GetFullName() end)

                if name:find("Default__", 1, true) then
                    rejected = rejected + 1
                else
                    local t, r
                    pcall(function() t = m.WidgetTree end)
                    if api.valid(t) then
                        pcall(function() r = t.RootWidget end)
                    end

                    if api.valid(t) and api.valid(r) then
                        menu, tree, root = m, t, r
                    else
                        rejected = rejected + 1
                    end
                end
            end
        end
    end)

    return menu, tree, root, total, rejected
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

local function attach(menu, tree, root)
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
    local menu, tree, root, total, rejected = usable_menu()

    if not menu then
        if panel_menu ~= nil then M.detach() end
        -- Instances existed but none was usable: that is a real problem worth
        -- naming, unlike the ordinary case of the stand simply being shut.
        if total > 0 then
            warn_once("nousable", string.format(
                "found %d stand menu object(s) but none had a usable WidgetTree " ..
                "(%d rejected) — open the stand and run '!pwp discover'", total, rejected))
        end
        return false
    end

    if panel_menu ~= menu or not api.valid(panel) then
        M.detach()
        if not attach(menu, tree, root) then return false end
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

    -- Every instance, not just the one picked, with why each was passed over.
    -- "found a menu but it had no tree" is only diagnosable if the rejects
    -- are visible next to the keeper.
    local instances = {}
    pcall(function()
        for _, m in ipairs(FindAllOf(M.MENU_CLASS) or {}) do
            instances[#instances + 1] = m
        end
    end)

    f:write("  instances: " .. #instances .. "\n")
    for i, m in ipairs(instances) do
        local name, t, r = "?", nil, nil
        pcall(function() name = m:GetFullName() end)
        pcall(function() t = m.WidgetTree end)
        if api.valid(t) then pcall(function() r = t.RootWidget end) end

        f:write(string.format("   [%d] tree=%s root=%s  %s\n",
            i, tostring(api.valid(t)), tostring(api.valid(r)), name))
    end

    local menu, tree, root = usable_menu()
    if not menu then
        f:write("  no usable instance. If the stand was shut when this ran, open it\n")
        f:write("  and dump again — the live menu only exists while the menu is up.\n")
        return
    end

    pcall(function() f:write("  root class: " .. root:GetFullName() .. "\n") end)

    -- What the root will actually accept decides how the panel attaches.
    for _, fn in ipairs({ "AddChildToCanvas", "AddChildToOverlay", "AddChild",
                          "GetChildrenCount", "AddChildToVerticalBox" }) do
        local present = false
        pcall(function() present = (root[fn] ~= nil) end)
        f:write(string.format("   root has %-22s %s\n", fn, tostring(present)))
    end

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
