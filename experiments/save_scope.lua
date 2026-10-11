-- Development namespace only. Never aliases deployed text files or scratch slots.
-- Inputs are verified persistent storage/guild GUIDs, NOT map or server names.
local M = {}
local function guid(value)
    assert(type(value)=='string' and #value==32 and value:match('^%x+$'),
        'persistent identity must be a 32-digit GUID')
    value=value:lower()
    assert(value~=string.rep('0',32),'unknown GUID cannot identify storage')
    return value
end
function M.new(storage, guild, stream)
    storage,guild=guid(storage),guid(guild)
    assert(stream=='priorities' or stream=='limits','unknown settings stream')
    -- Fixed-width encoding is injective; no truncated hash or caller path.
    -- Each stream contains camp-keyed entries; camps do not share rules merely
    -- because their records use the same guild-owned persistence stream.
    local stem='PWP_AsyncDev_v1_'..storage..'_'..guild..'_'..(stream=='priorities' and 'p' or 'l')
    return {key='PWP-SCOPE-1:'..storage..':'..guild..':'..stream,
        a=stem..'_A',b=stem..'_B',storage=storage,guild=guild,stream=stream}
end
return M
