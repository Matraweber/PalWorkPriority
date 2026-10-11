-- Synchronous diagnostic call. No authority grant, IO, or retained wrappers.
-- Native caller supplies the ORIGINAL reflected FPalInstanceID, never a Lua
-- table constructed from its words. The pure fixture uses table stand-ins.
local M={}
function M.read(engine,expected,id,utility)
    assert(type(expected)=='table' and getmetatable(expected)==nil)
    local wanted={}
    for _,k in ipairs({'world_address','state_address','instance_address','manager_address'})do
        local n=rawget(expected,k);assert(math.type(n)=='integer' and n>0);wanted[k]=n
    end
    local function address(o)
        assert(o and o:IsValid()==true)
        local n=o:GetAddress();assert(math.type(n)=='integer' and n>0);return n
    end
    local function world()
        address(engine)
        local viewport=engine.GameViewport;address(viewport)
        local w=viewport.World;assert(address(w)==wanted.world_address)
        assert(address(w.GameState)==wanted.state_address)
        local inst=w.OwningGameInstance;assert(address(inst)==wanted.instance_address)
        assert(address(engine.GameInstance)==wanted.instance_address)
        assert(address(inst.SaveGameManager)==wanted.manager_address)
        return w
    end
    local w=world();address(utility)
    -- SDK PalUtility.h: BlueprintPure, WorldContext, const FPalInstanceID& input.
    local parameter=utility:GetIndividualCharacterParameterByIstanceID(w,id)
    world() -- a changed chain invalidates even a non-nil native result
    return parameter
end
return M
