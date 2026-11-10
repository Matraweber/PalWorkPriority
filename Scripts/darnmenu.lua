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
-- 0.5.1: the page covers config.lua as far as it can, so nothing has to be
-- hand-edited (user's request 2026-11-10). work_priority's per-job default
-- (1-5 or X) and chat_prefix joined the scalars. The stand sets one Pal's
-- numbers and the Production Limits panel the limits; pal_overrides and the
-- container class lists stay in config.lua. The page shows what config.lua
-- says (M.register(base)), and a value saved here wins over it, as before.
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
  note = "Applies after you restart Palworld. Set priorities on the Monitoring Stand, limits in Production Limits (its key is under Hotkeys). In co-op the host's settings count; a dedicated server uses its own config.lua.",
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
    use_work_priority_for_new_pals = false,
    new_pal_priority_Transport = "1",
    new_pal_priority_ProductMedicine = "1",
    new_pal_priority_Cool = "2",
    new_pal_priority_GenerateElectricity = "2",
    new_pal_priority_Collection = "2",
    new_pal_priority_Handcraft = "3",
    new_pal_priority_EmitFlame = "3",
    new_pal_priority_Watering = "3",
    new_pal_priority_Seeding = "3",
    new_pal_priority_Deforest = "4",
    new_pal_priority_Mining = "4",
    new_pal_priority_OilExtraction = "4",
    new_pal_priority_MonsterFarm = "5",
    item_limits_on_rocks = true,
    storage_scope = "camp",
    log_level = "info",
    chat_prefix = "!pwp",
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
          help = "Off gives back every job the mod switched off and stops steering. Jobs set to X stay off." },
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
          help = "The Pal's work level for that job (the small number on the job icon), not the 1-5 priority. Ranked Pals only: a job below this level is switched off for them. Pals with equal numbers are left to the game." },
        { path = "leave_unordered_pals_to_game", label = "Leave Pals with equal numbers to the game", kind = "bool",
          help = "A Pal whose jobs all have the same number is not steered; the game picks its work. X and production limits still apply." },
        { path = "use_work_priority_for_new_pals", label = "New Pals use default numbers", kind = "bool",
          help = "A Pal the mod has not saved yet gets the numbers below. The first time this is on, Pals whose jobs all have the same number get them too, even ones you set equal. After that the stand's numbers are kept. A Pal whose jobs all end up equal is still left to the game." },
        { subtitle = "Default numbers for new Pals (1 first, 5 last, X never)",
          help = "These start as config.lua's work_priority. A value saved here replaces config.lua's." },
        { path = "new_pal_priority_Transport", label = "Transporting", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Transporting while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_ProductMedicine", label = "Medicine Production", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Medicine Production while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Cool", label = "Cooling", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Cooling while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_GenerateElectricity", label = "Generating Electricity", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Generating Electricity while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Collection", label = "Gathering", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Gathering while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Handcraft", label = "Handiwork", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Handiwork while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_EmitFlame", label = "Kindling", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Kindling while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Watering", label = "Watering", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Watering while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Seeding", label = "Planting", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Planting while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Deforest", label = "Lumbering", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Lumbering while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_Mining", label = "Mining", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Mining while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_OilExtraction", label = "Oil Extraction", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Oil Extraction while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
        { path = "new_pal_priority_MonsterFarm", label = "Farming", kind = "enum", values = { "1", "2", "3", "4", "5", "X" },
          help = "The number a new Pal gets for Farming while New Pals use default numbers is on. X: no new Pal does it. On a fresh install a Pal saved while it is X keeps X; change those on the stand." },
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
          help = "A reached Mining limit stops only the rocks that mainly give that item; other mining goes on while it is still wanted. Off: the whole Mining job stops." },
      },
    },
    {
      title = "Hotkeys",
      options = {
        { path = "key_panel", label = "Production Limits panel", kind = "keychord",
          help = "Opens and closes Production Limits, where you set when Pals stop making an item." },
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
      title = "Logging and chat",
      options = {
        { path = "log_level", label = "Log detail", kind = "enum",
          values = { "debug", "info", "warn", "error" },
          help = "How much goes into priority.log. info is the normal amount, debug is a lot." },
        { path = "chat_prefix", label = "Chat command prefix", kind = "text", maxLen = 32,
          help = "!pwp by default. Typed in front of the mod's chat commands, as in \"!pwp help\"." },
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
-- install still resolves. On M so a test can point it at a stubbed folder.
function M.shared_dir()
    if debug == nil or debug.getinfo == nil then return nil end
    local src = debug.getinfo(1, "S").source
    if type(src) ~= "string" or src:sub(1, 1) ~= "@" then return nil end
    local here = src:sub(2):match("^(.*[\\/])")
    return here and (here .. "..\\..\\shared\\") or nil
end

-- The whole file, or nil. Every failure is nil: a half-read file must never
-- be mistaken for the shared index.
local function read_all(path)
    local ok, f = pcall(io.open, path, "rb")
    if not ok or not f then return nil end
    local read_ok, text = pcall(f.read, f, "*a")
    local close_ok, closed = pcall(f.close, f)
    if not read_ok or type(text) ~= "string" or not close_ok or not closed then return nil end
    return text
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
    --
    -- Read with io and loaded as text, so a leading UTF-8 byte order mark (an
    -- editor's, which loadfile skips and load does not) is dropped first.
    local text = read_all(path)
    if text == nil then return nil end
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end
    local chunk = load(text, "=" .. path, "t", {})
    if chunk == nil then return nil end
    local ok, value = pcall(chunk)
    return (ok and type(value) == "table") and value or nil
end

-- Written, flushed by close, and both results checked. file:write returns
-- nil, err on a full disk instead of raising, so a pcall alone saw success.
local function write_checked(path, source)
    local ok, f = pcall(io.open, path, "wb")
    if not ok or not f then return false end
    local write_ok, wrote = pcall(f.write, f, source)
    local close_ok, closed = pcall(f.close, f)
    return write_ok and wrote ~= nil and close_ok and closed ~= nil and closed ~= false
end

-- Only when the bytes differ, so a launch that changes nothing does not
-- rewrite two files for no reason.
--
-- One of the two files is SHARED: DarnMenu_schema_index.lua lists every mod
-- that has registered a settings page. Ours is the only thing entitled to
-- break when ours breaks, so (review round 2):
--   1. the new bytes go to .tmp and are read back and compared;
--   2. the old file is renamed to .bak, never removed (os.rename will not
--      replace a file on Windows, so it has to move first);
--   3. .tmp is renamed into place; if that fails, .bak is moved back.
--   4. .bak is removed once the new file is in place (review round 3: a kept
--      .bak brought back the names of mods removed since, the next time the
--      index went missing).
-- A crash between 2 and 3 leaves .tmp and .bak, and M.register recovers the
-- index from them. At no point is the only copy of the old list deleted.
local function write_if_changed(path, source)
    local had = read_all(path)
    if had == source then return true end

    local tmp, bak = path .. ".tmp", path .. ".bak"
    if not write_checked(tmp, source) or read_all(tmp) ~= source then
        pcall(os.remove, tmp)
        return false
    end

    if had ~= nil then
        pcall(os.remove, bak)
        local ok, moved = pcall(os.rename, path, bak)
        if not ok or not moved then
            pcall(os.remove, tmp)
            return false
        end
    end

    local ok, renamed = pcall(os.rename, tmp, path)
    if ok and renamed then
        pcall(os.remove, bak)
        return true
    end

    -- Put the old file back. Should that fail too, .tmp and .bak both stay
    -- for the next register to recover from.
    if had ~= nil then
        local back_ok, back = pcall(os.rename, bak, path)
        if back_ok and back then pcall(os.remove, tmp) end
    end
    return false
end

-- A plain list of names, or nil. Anything else in the table (a non-string,
-- a key outside the list) would be lost by a rewrite, so it is not a list.
local function names_of(value)
    if type(value) ~= "table" then return nil end
    local out, count = {}, 0
    for _ in pairs(value) do count = count + 1 end
    for _, n in ipairs(value) do
        if type(n) ~= "string" then return nil end
        out[#out + 1] = n
    end
    return #out == count and out or nil
end

-- The index is absent: an interrupted write leaves .tmp (the new list) and
-- .bak (the old one). Both are merged, so no other mod's page is lost.
local function recover_index(index_path)
    local merged, seen, found = {}, {}, false
    for _, suffix in ipairs({ ".tmp", ".bak" }) do
        local names = names_of(read_table(index_path .. suffix))
        if names then
            found = true
            for _, n in ipairs(names) do
                if not seen[n] then seen[n] = true; merged[#merged + 1] = n end
            end
        end
    end
    if found then log.warn("darnmenu: options index was missing, rebuilt from its .tmp/.bak copy") end
    return merged
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
function M.register(base)
    local shared = M.shared_dir()
    if shared == nil then return false end

    local schema = shared .. "DarnMenu_schema_" .. SCHEMA_NAME .. ".lua"
    if not write_if_changed(schema, M.schema_text(base)) then return false end

    local index_path = shared .. "DarnMenu_schema_index.lua"
    local names, recovered = names_of(read_table(index_path)), false

    if names == nil then
        -- Present but unreadable is not the same as absent. Overwriting it
        -- would drop every other mod's page, so it is left alone.
        local existing = io.open(index_path, "rb")
        if existing then
            existing:close()
            log.debug("darnmenu: index unreadable, left as it is")
            return false
        end
        names, recovered = recover_index(index_path), true
    end

    local listed = false
    for _, n in ipairs(names) do
        if n == SCHEMA_NAME then listed = true end
    end
    if listed and not recovered then return true end
    if not listed then names[#names + 1] = SCHEMA_NAME end
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
    use_work_priority_for_new_pals = "boolean",
    item_limits_on_rocks = "boolean",
    storage_scope = "string",
    log_level = "string",
    chat_prefix = "string",
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

-- The jobs whose default number the page offers, in page order. Anyone is
-- inert (nothing resolves work to it), so it is not offered.
M.NEW_PAL_JOBS = { "Transport", "ProductMedicine", "Cool", "GenerateElectricity", "Collection", "Handcraft", "EmitFlame", "Watering", "Seeding", "Deforest", "Mining", "OilExtraction", "MonsterFarm" }

-- What the player saved, or nil. On M so a test can hand in a file's
-- contents without a Mods/shared/ folder on disk. A file that is there but
-- does not read as a table is said once (review round 3): silently, an
-- option the player had switched off came back on.
local said_unreadable = false
function M.user_settings()
    local shared = M.shared_dir()
    if shared == nil then return nil end
    local path = shared .. USER_NAME .. ".lua"
    local saved = read_table(path)
    if saved == nil and not said_unreadable and read_all(path) ~= nil then
        said_unreadable = true
        log.warn("darnmenu: Mods/shared/" .. USER_NAME .. ".lua is damaged and was ignored, so config.lua " ..
            "and the default hotkeys apply. Fix or delete that file.")
    end
    return saved
end

function M.binding(name, default_key, default_mods)
    local user = M.user_settings()
    local saved = user and user[name] or nil

    local key_name = default_key
    local mod_names = default_mods or {}
    local changed = false

    if type(saved) == "table" and type(saved.key) == "string" then
        -- An unknown modifier is refused as a whole, never dropped: dropping
        -- it turned Alt+F1 into a plain F1 (review round 2).
        local wanted, unknown = {}, nil
        if saved.modifiers ~= nil and type(saved.modifiers) ~= "table" then
            unknown = tostring(saved.modifiers)
        end
        for _, m in ipairs(type(saved.modifiers) == "table" and saved.modifiers or {}) do
            if type(m) == "string" and MODS[m] and ModifierKey ~= nil and ModifierKey[m] ~= nil then
                wanted[#wanted + 1] = m
            else
                unknown = unknown or tostring(m)
            end
        end
        if unknown ~= nil then
            log.warn("darnmenu: " .. name .. " uses the modifier '" .. unknown ..
                "', which this UE4SS has no key for. Using the default.")
        elseif Key ~= nil and Key[saved.key] ~= nil then
            key_name = saved.key
            mod_names = wanted
            changed = true
        else
            log.warn("darnmenu: " .. name .. " is bound to '" ..
                tostring(saved.key) .. "', which this UE4SS has no key for. " ..
                "Using the default.")
        end
    end

    local key = Key and Key[key_name] or nil
    if key == nil then return nil, nil, false end

    -- A default modifier this UE4SS lacks binds nothing rather than a plain
    -- key; main.lua then warns that the action has no hotkey.
    local mods = nil
    if #mod_names > 0 then
        mods = {}
        for _, m in ipairs(mod_names) do
            local value = ModifierKey ~= nil and ModifierKey[m] or nil
            if value == nil then return nil, nil, false end
            mods[#mods + 1] = value
        end
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

    -- The jobs' default numbers: "1"-"5" or "X", or a number typed into the
    -- file by hand. They replace config.lua's work_priority entry like any
    -- other saved value; the numbers only rank with the setting on.
    for _, job in ipairs(M.NEW_PAL_JOBS) do
        local key = "new_pal_priority_" .. job
        local value = user[key]
        if value ~= nil then
            local prio
            if value == "X" then prio = false
            elseif type(value) == "string" or type(value) == "number" then
                prio = math.tointeger(tonumber(value))
                if prio ~= nil and (prio < 1 or prio > 5) then prio = nil end
            end
            local current = type(cfg.work_priority) == "table" and cfg.work_priority[job] or nil
            if prio == nil then
                log.warn("darnmenu: ignored \"" .. (options[key] and options[key].label or key) .. "\" = " ..
                    tostring(value) .. " from Mods/shared/" .. USER_NAME .. ".lua (not 1-5 or X); keeping " ..
                    tostring(current) .. " from config.lua")
            elseif current ~= prio then
                -- A copy: the table may be shared with what config.lua loaded.
                local copy = {}
                for k, v in pairs(type(cfg.work_priority) == "table" and cfg.work_priority or {}) do copy[k] = v end
                copy[job] = prio
                cfg.work_priority = copy
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

-- The page with its defaults taken from config.lua (base: config.lua as
-- loaded, before the menu's own values). Before 0.5.1 the page always showed
-- the shipped values, so a player with Transport = 5 in config.lua saw 1
-- (review 2026-11-10). A value the checks refuse keeps the shipped default.
-- The menu's saved values are untouched: they still win over these.
local function literal(value)
    if type(value) == "boolean" then return tostring(value) end
    if math.type(value) == "integer" then return string.format("%d", value) end
    if type(value) == "string" then return string.format("%q", value) end
    return nil
end
function M.schema_text(base)
    if type(base) ~= "table" then return SCHEMA_SOURCE end
    local configuration = require("configuration")
    local text = SCHEMA_SOURCE
    local function put(key, value)
        local shown = literal(value)
        if shown == nil then return end
        local pattern = "\n    " .. key .. " = [^\n]-,\n"
        local found = text:find(pattern)
        if not found then return end
        text = text:gsub(pattern, function() return "\n    " .. key .. " = " .. shown .. ",\n" end, 1)
    end
    -- The same check M.apply uses, so the page never offers a value it
    -- would refuse (re-review P3-2: validate alone let 600 seconds through
    -- a 5-300 range). config.lua spells "no limit" as nil or false.
    local options = {}
    for _, section in ipairs((M.schema() or {}).sections or {}) do
        for _, option in ipairs(section.options or {}) do
            if option.path then options[option.path] = option end
        end
    end
    for key, want in pairs(KEYS) do
        local value = base[key]
        if key == "max_pals_per_work_type" and (value == nil or value == false) then value = 0 end
        if value ~= nil and type(value) == want then
            local ok, why = pcall(refusal, key, value, options[key], configuration)
            if ok and why == nil then put(key, value) end
        end
    end
    local wp = type(base.work_priority) == "table" and base.work_priority or {}
    for _, job in ipairs(M.NEW_PAL_JOBS) do
        local prio = wp[job]
        if prio == false then put("new_pal_priority_" .. job, "X")
        elseif math.tointeger(prio) and prio >= 1 and prio <= 5 then
            put("new_pal_priority_" .. job, string.format("%d", prio))
        end
    end
    return text
end

return M
