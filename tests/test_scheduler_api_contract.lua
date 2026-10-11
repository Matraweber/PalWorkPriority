-- Integration gates at scheduler's native adapter boundary. These exercise
-- the ACTUAL palapi module against reflection-shaped fixtures, not the game.
package.loaded.log = {count = function() return {ms = 0} end,
    warn = function() end, debug = function() end, say = function() end}
local api = require("palapi")
local function live(fields) fields.IsValid = function() return true end; return fields end
local failures = {}
local function check(name, fn)
    local ok, why = pcall(fn)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(why) end
end

check("unreadable off-list entry is unknown, never all-enabled", function()
    local param = live({SaveParameter = {WorkSuitabilityOptionInfo = {
        OffWorkSuitabilityList = {ForEach = function(_, callback)
            callback(1, {get = function() return nil end})
        end},
    }}})
    assert(api.work_off_set(param) == nil,
        "partial off-list was returned as complete; baseline would permanently save unchecked work as priority 1")
end)

check("global GameMode cannot override current local client evidence", function()
    api.reset()
    local pc = live({Role = 2})
    local world = live({OwningGameInstance = {LocalPlayers = {{PlayerController = pc}}}})
    package.loaded.UEHelpers = {GetEngine = function() return {GameViewport = live({World = world})} end}
    api.cdo = function() return nil end
    FindFirstOf = function() return live({GetFullName = function() return "PalGameMode old-world" end}) end
    assert(api.latch_authority() ~= true,
        "global GameMode authorized server-only Pal reads despite affirmative local client role")
end)

check("unreadable item identity makes storage incomplete", function()
    local slot = {ItemId = {StaticId = {ToString = function() return nil end}}, StackCount = 50}
    local container = live({ItemSlotArray = {slot}, GetFullName = function() return "PalItemContainer storage" end})
    local module = live({TargetContainer = container})
    FindAllOf = function() return {live({
        GetItemContainerModule = function() return module end,
        GetBaseCampIdBelongTo = function() return {A = 1, B = 2, C = 3, D = 4} end,
        GetFullName = function() return "PalMapObjectItemChestModel storage" end,
    })} end
    local _, _, evidence = api.camp_item_totals("1-2-3-4", {exclude = {}})
    assert(evidence.complete == false,
        "unreadable item identity was treated as a known empty slot and could release a legacy ceiling")
end)

check("explicit replication route never searches or falls back", function()
    api.owned_network_component=function() error("unexpected owned lookup") end
    api.network_component=function() error("unexpected global lookup") end
    local sent=0
    local comp=live({RequestReplicateBaseCampWork_ToServer=function(_,id,on)
        assert(id=="camp" and on==true);sent=sent+1
    end})
    assert(api.request_work_replication("camp",true,comp) and sent==1)
    assert(not api.request_work_replication("camp",true,{}))
end)
assert(#failures == 0, table.concat(failures, "\n"))
