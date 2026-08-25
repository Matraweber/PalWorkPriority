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

local log = require("log")

local SCHEMA_NAME = "PalWorkPriority"
local USER_NAME = "PalWorkPriority_user"

-- Deliberately the scalars only.
--
-- work_priority, pal_overrides and work_caps are tables, and the first and
-- last are already editable in game - priorities on the Monitoring Stand,
-- ceilings in the Alt+F1 panel - so putting them here would be a second place
-- to set the same thing and a second thing to keep in step. The scalars are
-- the ones with no in-game route at all, which is the gap worth closing.
--
-- live = false throughout, honestly. These are read when config loads, and the
-- pass, the grid and the panel all capture what they need from it, so a change
-- lands on the next launch. Claiming otherwise would put a green "applies now"
-- dot on a setting that quietly does nothing until restart.
local SCHEMA_SOURCE = [==[
return {
  schemaVersion = 1,
  tab = "Pal Work Priority",
  order = 100,
  target = "PalWorkPriority_user",
  note = "config.lua stays the default. Anything set here overrides it. Priorities are set on the Monitoring Stand and ceilings in the Alt+F1 panel, so neither is repeated here.",
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
    storage_scope = "camp",
    log_level = "info",
  },
  sections = {
    {
      title = "Running",
      options = {
        { path = "enabled", label = "Assign Pals to jobs", kind = "bool",
          help = "Off leaves every Pal exactly as the game left it." },
        { path = "dry_run", label = "Test mode", kind = "bool",
          dependsOn = "enabled",
          help = "Works everything out and writes nothing. The log says what it would have done." },
        { path = "interval_seconds", label = "Seconds between passes", kind = "number",
          integer = true, min = 2, max = 300, step = 5, dependsOn = "enabled" },
        { path = "run_on_world_load", label = "Run a pass on world load", kind = "bool",
          dependsOn = "enabled" },
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
          help = "Spread gives every wanted job somebody before doubling up." },
        { path = "max_pals_per_work_type", label = "Most Pals on one job", kind = "number",
          integer = true, min = 0, max = 20, step = 1, note = "0 for no limit" },
        { path = "min_suitability_rank", label = "Lowest rank worth dedicating", kind = "number",
          integer = true, min = 1, max = 5, step = 1,
          help = "Stops the mod dedicating a rank 1 Pal to a job a specialist should have. It does not stop that Pal working." },
      },
    },
    {
      title = "Ceilings",
      options = {
        { path = "storage_scope", label = "Count storage", kind = "enum",
          values = {
            { value = "camp",   label = "Per base" },
            { value = "global", label = "Across every loaded base" },
          },
          help = "Whether a limit is measured at each base on its own or over all of them." },
      },
    },
    {
      title = "Logging",
      options = {
        { path = "log_level", label = "Log detail", kind = "enum",
          values = { "debug", "info", "warn", "error" },
          help = "info is the normal amount. debug is loud." },
      },
    },
  },
}
]==]

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
    local chunk = loadfile(path)
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
    f = io.open(path, "wb")
    if not f then return false end
    local ok = pcall(function() f:write(source) end)
    f:close()
    return ok
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
    storage_scope = "string",
    log_level = "string",
}

function M.apply(cfg)
    if type(cfg) ~= "table" then return 0 end

    local shared = shared_dir()
    if shared == nil then return 0 end

    local user = read_table(shared .. USER_NAME .. ".lua")
    if user == nil then return 0 end

    local n = 0
    for key, want in pairs(KEYS) do
        local value = user[key]
        if type(value) == want then
            -- 0 means "no limit" in the menu, which config spells as nil. The
            -- menu has no way to offer an absent number, so the two
            -- vocabularies are translated here rather than teaching the
            -- scheduler a second one.
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
