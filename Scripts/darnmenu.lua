-- Optional DarnMenu integration.
--
-- DarnMenu (ESC > Darn Mod Options) is a settings framework: a mod writes a
-- schema into Mods/shared/, DarnMenu renders it as a page, and the player's
-- edits are saved to Mods/shared/<target>.lua for the mod to read back. It
-- exists so mods stop asking people to hand-edit Lua, which is exactly what
-- config.lua asks today.
--
-- Optional in both directions. With DarnMenu absent the two files this writes
-- sit unread; with the user file absent config.lua is the whole story. Nothing
-- here can stop the mod working, which is the reason to follow the framework's
-- own convention rather than invent one. PerfectPlacement ships this same
-- shape and is the reference this was written against.
--
-- config.lua stays the baseline. A saved option overrides it; one the player
-- never touched is absent from the user file and falls through. Deleting that
-- file restores the shipped defaults exactly.

local M = {}

-- Display labels of the bound hotkeys ("ALT+F1"), by binding name. main.lua
-- fills it as it binds; the panel and the stand legend read it and fall back
-- to the shipped Alt+Fn when a name is missing.
M.labels = {}

local log = require("log")

local SCHEMA_NAME = "PalWorkPriority"
local USER_NAME = "PalWorkPriority_user"

-- Deliberately the scalars only.
--
-- work_priority, pal_overrides and work_caps are tables, and the first and
-- last are already editable in game - priorities on the Monitoring Stand,
-- limits in the Alt+F1 panel - so putting them here would be a second place
-- to set the same thing and a second thing to keep in step. The scalars are
-- the ones with no in-game route at all, which is the gap worth closing.
--
-- live = false throughout, honestly. These are read when config loads, and the
-- pass, the grid and the panel all capture what they need from it, so a change
-- lands on the next launch. Claiming otherwise would put a green "applies now"
-- dot on a setting that quietly does nothing until restart.
local SCHEMA_SOURCE = [==[
return {
  schemaVersion = 2,
  tab = "Pal Work Priority",
  order = 100,
  target = "PalWorkPriority_user",
  note = "Changes here apply after you restart Palworld. Priorities are set on the Monitoring Stand, limits in Production Limits (Alt+F1). On a server only the host's settings count.",
  applyNote = "Saved. Restart Palworld to apply.",
  live = false,
  defaults = {
    enabled = true,
    dry_run = false,
    interval_seconds = 10,
    run_on_world_load = true,
    assignment_mode = "spread",
    max_pals_per_work_type = 3,
    min_suitability_rank = 1,
    leave_unordered_pals_to_game = true,
    item_limits_on_rocks = true,
    storage_scope = "camp",
    log_level = "info",
    key_panel = { key = "F1", modifiers = { "ALT" } },
    key_pass  = { key = "F2", modifiers = { "ALT" } },
    key_stock = { key = "F3", modifiers = { "ALT" } },
    key_mode  = { key = "F10", modifiers = { "ALT" } },
    key_cap   = { key = "F11", modifiers = { "ALT" } },
    key_scope = { key = "F12", modifiers = { "ALT" } },
  },
  sections = {
    {
      title = "Running",
      options = {
        { path = "enabled", label = "Assign Pals to jobs", kind = "bool",
          help = "Off gives every Pal its work back and stops steering." },
        { path = "dry_run", label = "Test mode", kind = "bool",
          dependsOn = "enabled",
          help = "Works everything out and changes nothing. priority.log says what it would have done." },
        { path = "interval_seconds", label = "Seconds between rechecks", kind = "number",
          integer = true, min = 5, max = 300, step = 5, dependsOn = "enabled",
          help = "How often the mod looks at every base again. Lower reacts sooner but costs a little more." },
        { path = "run_on_world_load", label = "Recheck when a world loads", kind = "bool",
          dependsOn = "enabled",
          help = "Rechecks every base as soon as a world has loaded. Off waits for the first timed recheck." },
      },
    },
    {
      title = "How Pals are spread",
      options = {
        { path = "assignment_mode", label = "Assignment", kind = "enum",
          values = {
            { value = "spread", label = "Spread (one Pal per job first)" },
            { value = "fill",   label = "Fill (stack the best job first)" },
          },
          help = "Spread gives every wanted job somebody before doubling up. Fill gives the top job every Pal it can first." },
        { path = "max_pals_per_work_type", label = "Most Pals on one job", kind = "number",
          integer = true, min = 0, max = 20, step = 1, note = "0 for no limit",
          help = "The most Pals the mod puts on the same job." },
        { path = "min_suitability_rank", label = "Lowest work level to dedicate", kind = "number",
          integer = true, min = 1, max = 5, step = 1,
          help = "The Pal's work level for that job (the small number on the job icon), not the 1-5 priority. Below it a Pal is not dedicated to that job, but it may still do it." },
        { path = "leave_unordered_pals_to_game", label = "Leave unranked Pals to the game", kind = "bool",
          help = "A Pal whose jobs all have the same number is not steered; the game picks its work. X and production limits still apply." },
      },
    },
    {
      title = "Production limits",
      options = {
        { path = "storage_scope", label = "Count storage", kind = "enum",
          values = {
            { value = "camp",   label = "Per base" },
            { value = "global", label = "Across every loaded base" },
          },
          help = "Whether a limit is measured at each base on its own or over all of them. A base nobody is near may not be loaded and is then not counted." },
        { path = "item_limits_on_rocks", label = "Mining limits per item", kind = "bool",
          help = "A reached Mining limit stops only the rocks that mainly give that item; other mining goes on. Off: the whole Mining job stops." },
      },
    },
    {
      title = "Hotkeys",
      options = {
        { path = "key_panel", label = "Production Limits panel", kind = "keychord",
          help = "Opens and closes Production Limits, where you set how much of an item a base keeps." },
        { path = "key_pass", label = "Recheck now", kind = "keychord",
          help = "Rechecks every base now instead of waiting for the next timed recheck." },
        { path = "key_stock", label = "Print base storage", kind = "keychord",
          help = "Writes what each container holds to priority.log in the mod folder." },
        { path = "key_mode", label = "Switch spread / fill", kind = "keychord",
          help = "Switches between Spread and Fill until you restart. The saved choice is Assignment above." },
        { path = "key_cap", label = "Cycle most Pals on one job", kind = "keychord",
          help = "Steps Most Pals on one job through 1, 2, 3, 4 and no limit until you restart." },
        { path = "key_scope", label = "Switch Count storage", kind = "keychord",
          help = "Switches Count storage between per base and every loaded base until you restart." },
        { subtitle = "Esc (controller: B) closes Production Limits. On the stand, View opens it." },
      },
    },
    {
      title = "Logging",
      options = {
        { path = "log_level", label = "Log detail", kind = "enum",
          values = { "debug", "info", "warn", "error" },
          help = "How much goes into priority.log. info is the normal amount, debug is a lot." },
      },
    },
  },
}
]==]

-- The schema as a table, for the range checks in M.apply and for the tests.
-- Parsed from the same text DarnMenu reads, so the page and the checks
-- cannot drift apart.
function M.schema()
    local chunk = load(SCHEMA_SOURCE, "=darnmenu schema", "t", {})
    return chunk and chunk() or nil
end

-- Mods/shared/, found from this file rather than hardcoded, so a non-standard
-- install still resolves.
local function shared_dir()
    if debug == nil or debug.getinfo == nil then return nil end
    local src = debug.getinfo(1, "S").source
    if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
    local here = src:sub(2):match("^(.*[\\/])")
    return here and (here .. "..\\..\\shared\\") or nil
end

local function read_table(path)
    -- Text only, and no environment at all.
    --
    -- loadfile defaults to mode "bt", so it will happily load precompiled
    -- BYTECODE - and Lua 5.4's bytecode verifier is not a security boundary,
    -- so crafted bytecode is memory corruption that no pcall can catch. The
    -- chunk also ran with _ENV = _G, reaching io, os.execute and the whole
    -- UE4SS binding surface.
    --
    -- The comment below on KEYS says this file "refuses rather than trusts",
    -- and it does - but only AFTER the file has already run. Both of these are
    -- supposed to be a literal table, so "t" refuses the bytecode outright and
    -- {} means the chunk has nothing to reach even if it tries.
    local chunk = loadfile(path, "t", {})
    if chunk == nil then return nil end
    local ok, value = pcall(chunk)
    return (ok and type(value) == "table") and value or nil
end

-- Only when the bytes differ, so a launch that changes nothing does not
-- rewrite two files for no reason.
local function write_if_changed(path, source)
    local f = io.open(path, "rb")
    if f then
        local had = f:read("*a")
        f:close()
        if had == source then return true end
    end

    -- Temp file then rename, because one of the two files this writes is
    -- SHARED. DarnMenu_schema_index.lua lists every mod that has registered a
    -- settings page, and opening it "wb" truncates it before a single byte is
    -- written - so a failure or a crash in the middle left it empty and took
    -- every other mod's page with it. Ours is the only thing entitled to
    -- break when ours breaks.
    local tmp = path .. ".tmp"
    f = io.open(tmp, "wb")
    if not f then return false end
    local ok = pcall(function() f:write(source) end)
    f:close()

    if not ok then
        os.remove(tmp)
        return false
    end

    -- If the rename cannot happen, put the content back by hand.
    --
    -- os.rename will not replace an existing file on Windows, so the real file
    -- has to go first - and that inverted the very protection this was written
    -- for. M.register treats a PRESENT but unreadable index as "leave it
    -- alone" and an ABSENT one as "start fresh", so dying between the remove
    -- and the rename left the shared index missing, and the next launch
    -- rewrote it containing only this mod. Every other mod's settings page
    -- would have gone - the exact harm the temp file was meant to prevent.
    --
    -- Absent is the one state that must not be left behind, so a failed rename
    -- falls back to writing in place. That is no worse than the old behaviour
    -- and strictly better than a missing file.
    os.remove(path)
    if os.rename(tmp, path) then return true end

    local back = io.open(path, "wb")
    if not back then return false end
    local ok_back = pcall(function() back:write(source) end)
    back:close()
    os.remove(tmp)
    return ok_back
end

local function serialize_index(names)
    local out = { "return {\n" }
    for _, n in ipairs(names) do out[#out + 1] = string.format("  %q,\n", n) end
    out[#out + 1] = "}\n"
    return table.concat(out)
end

-- Write the schema and add ourselves to the index DarnMenu reads.
--
-- The index is re-read every time the menu opens, so a freshly registered page
-- appears without a restart. Failing is not worth shouting about: DarnMenu may
-- simply not be installed, in which case both files are inert.
function M.register()
    local shared = shared_dir()
    if shared == nil then return false end

    local schema = shared .. "DarnMenu_schema_" .. SCHEMA_NAME .. ".lua"
    if not write_if_changed(schema, SCHEMA_SOURCE) then return false end

    local index_path = shared .. "DarnMenu_schema_index.lua"
    local names = read_table(index_path)

    if names == nil then
        -- Present but unreadable is not the same as absent. Overwriting it
        -- would drop every other mod's page, so it is left alone.
        local existing = io.open(index_path, "rb")
        if existing then
            existing:close()
            log.debug("darnmenu: index unreadable, left as it is")
            return false
        end
        names = {}
    end

    for _, n in ipairs(names) do
        if n == SCHEMA_NAME then return true end
    end

    names[#names + 1] = SCHEMA_NAME
    if not write_if_changed(index_path, serialize_index(names)) then
        return false
    end

    log.debug("darnmenu: options registered")
    return true
end

-- Overlay what the player saved on top of config.lua.
--
-- Only keys the schema declares, and only when the type matches. A settings
-- file is player-editable and a malformed value reaching the scheduler is
-- worse than ignoring it, so this refuses rather than trusts.
local KEYS = {
    enabled = "boolean",
    dry_run = "boolean",
    interval_seconds = "number",
    run_on_world_load = "boolean",
    assignment_mode = "string",
    max_pals_per_work_type = "number",
    min_suitability_rank = "number",
    leave_unordered_pals_to_game = "boolean",
    item_limits_on_rocks = "boolean",
    storage_scope = "string",
    log_level = "string",
}

-- A hotkey the player may have rebound, resolved to what RegisterKeyBind wants.
--
-- The stored shape is DarnMenu's keychord: a primary key NAME plus a list of
-- modifier names. Both have to survive a player-edited file, so an unknown key
-- falls back to the shipped default rather than binding nothing - a hotkey that
-- silently does not exist is the worst outcome here, and this mod has already
-- shipped one of those.
--
-- Returns key, modifiers, changed.
local MODS = { CONTROL = true, ALT = true, SHIFT = true }

-- What the player saved, or nil. On M so a test can hand in a file's
-- contents without a Mods/shared/ folder on disk.
function M.user_settings()
    local shared = shared_dir()
    return shared and read_table(shared .. USER_NAME .. ".lua") or nil
end

function M.binding(name, default_key, default_mods)
    local user = M.user_settings()
    local saved = user and user[name] or nil

    local key_name = default_key
    local mod_names = default_mods or {}
    local changed = false

    if type(saved) == "table" and type(saved.key) == "string" then
        if Key ~= nil and Key[saved.key] ~= nil then
            key_name = saved.key
            mod_names = {}
            if type(saved.modifiers) == "table" then
                for _, m in ipairs(saved.modifiers) do
                    if type(m) == "string" and MODS[m] then
                        mod_names[#mod_names + 1] = m
                    end
                end
            end
            changed = true
        else
            log.warn("darnmenu: " .. name .. " is bound to '" ..
                tostring(saved.key) .. "', which this UE4SS has no key for. " ..
                "Using the default.")
        end
    end

    local key = Key and Key[key_name] or nil
    if key == nil then return nil, nil, false end

    local mods = nil
    if #mod_names > 0 and ModifierKey ~= nil then
        mods = {}
        for _, m in ipairs(mod_names) do
            if ModifierKey[m] ~= nil then mods[#mods + 1] = ModifierKey[m] end
        end
        if #mods == 0 then mods = nil end
    end

    -- What to call it in a log line, so a rebound key still reads clearly.
    local label = table.concat(mod_names, "+")
    label = (label ~= "" and (label .. "+") or "") .. key_name

    return key, mods, changed, label
end

-- Why a saved value cannot be used, or nil when it can.
--
-- The schema's own kind, range and values first, then configuration.validate
-- on that one key, which is what decides whether the mod starts at all. Until
-- 2026-10-28 the page offered "Seconds between rechecks" from 2 while validate
-- wanted 5, so a 2 saved here stopped the mod on every launch.
local function refusal(key, value, option, configuration)
    if option and option.kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "not a number"
        end
        if option.integer and math.tointeger(value) == nil then return "not a whole number" end
        if option.min and value < option.min then return "below " .. option.min end
        if option.max and value > option.max then return "above " .. option.max end
    elseif option and option.kind == "enum" then
        local known = false
        for _, entry in ipairs(option.values or {}) do
            if (type(entry) == "table" and entry.value or entry) == value then known = true end
        end
        if not known then return "not one of the choices" end
    end
    -- 0 means "no limit" in the menu, which config spells as nil. The menu has
    -- no way to offer an absent number, so the two vocabularies are translated
    -- in M.apply rather than teaching the scheduler a second one.
    if key == "max_pals_per_work_type" and value == 0 then return nil end
    local ok, valid = pcall(configuration.validate, { [key] = value })
    if not ok or not valid then return "refused by the config check" end
    return nil
end

-- A bad value is skipped with a warning naming it, never passed on: this runs
-- before configuration.validate, and a value that fails there stops the whole
-- mod. The setting then keeps what config.lua says.
function M.apply(cfg)
    if type(cfg) ~= "table" then return 0 end

    local user = M.user_settings()
    if user == nil then return 0 end

    local configuration = require("configuration")
    local options = {}
    for _, section in ipairs((M.schema() or {}).sections or {}) do
        for _, option in ipairs(section.options or {}) do
            if option.path then options[option.path] = option end
        end
    end

    local n = 0
    for key, want in pairs(KEYS) do
        local value = user[key]
        local option = options[key]
        local why = nil
        if value ~= nil and type(value) ~= want then
            why = "not a " .. want
        elseif value ~= nil then
            why = refusal(key, value, option, configuration)
        end
        if why then
            log.warn("darnmenu: ignored \"" .. (option and option.label or key) .. "\" = " ..
                tostring(value) .. " from Mods/shared/" .. USER_NAME .. ".lua (" .. why ..
                "); keeping " .. tostring(cfg[key]) .. " from config.lua")
        elseif value ~= nil then
            if key == "max_pals_per_work_type" and value == 0 then
                value = nil
            end
            if cfg[key] ~= value then
                cfg[key] = value
                n = n + 1
            end
        end
    end

    if n > 0 then
        log.say("DarnMenu options applied, " .. n .. " setting(s) from " ..
            "Mods/shared/" .. USER_NAME .. ".lua")
    end
    return n
end

return M
