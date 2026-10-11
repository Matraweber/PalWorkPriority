-- Native Slate reconstruction is an input boundary even when a menu's
-- UObject, names and rows survive. Observed on this runtime: the stand
-- derives directly from UUserWidget and owns Construct/Destruct overrides.
-- Destruct is diagnostic only: deferred old Slate cleanup must not cancel
-- fresh input after a new construction. No wrapper or name proves lifetime.
local session = require('session')
local M = {generation=0, constructs=0, destructs=0}
local PATH='/Game/Pal/Blueprint/UI/UserInterface/IngameMenu/WorkSuitabilityPreference/'
    ..'WBP_WorkSuitabilityPreferenceMenu.WBP_WorkSuitabilityPreferenceMenu_C'
local hooks, errors, retry_at = {}, {}, -math.huge
local armed_world, invalidate

local function receive(event, context)
    if armed_world~=session.epoch then return end
    local ok,kind=pcall(function()
        return context:get():GetClass():GetFullName()
    end)
    if not ok or kind~='WidgetBlueprintGeneratedClass '..PATH then return end
    if event=='Construct' then
        M.constructs=M.constructs+1
        M.generation=M.generation+1
        if invalidate then invalidate('open') end
    else M.destructs=M.destructs+1 end
end

function M.configure(fn) invalidate=fn end

function M.observe(menu)
    if not menu then return end
    armed_world=session.epoch
    if os.clock()<retry_at then return end
    retry_at=os.clock()+10
    for _,event in ipairs({'Construct','Destruct'}) do
        if not hooks[event] then
            local ok,why=pcall(RegisterHook,PATH..':'..event,function(context) receive(event,context) end)
            hooks[event]=ok
            errors[event]=not ok and tostring(why) or nil
        end
    end
end

function M.reset() armed_world=nil; M.generation=M.generation+1 end

function M.report()
    return string.format('stand lifecycle: construct_hook=%s destruct_hook=%s constructs=%d destructs=%d generation=%d errors=%s/%s',
        tostring(hooks.Construct==true),tostring(hooks.Destruct==true),M.constructs,M.destructs,M.generation,
        tostring(errors.Construct),tostring(errors.Destruct))
end
return M
