-- Direct production ui.refresh integration. Reuse only the existing fixture
-- definition; do not rewrite ui.lua or run the unrelated integration scenarios.
local file=assert(io.open(TEST_ROOT..'/tests/test_ui_integration.lua','r'))
local source=file:read('*a'); file:close()
local boundary=assert(source:find("\ncheck('",1,true),'fixture boundary changed')
local fixture=assert(load(source:sub(1,boundary-1)..'\nreturn fixture',
    '@stand-integration-fixture','t',_ENV))()
local mode='nil'
local f, current
local queries, remembers, sweeps=0,0,0
package.loaded.widget_lookup={
    stands=function()
        queries=queries+1
        if mode=='nil' then return nil end
        if mode=='empty' then return {} end
        if mode=='hidden' then
            local hidden=f.object(f.ui.MENU_CLASS,'hidden'); hidden.visibility=2
            return {hidden}
        end
        if mode=='mixed' then
            local default=f.object(f.ui.MENU_CLASS,'Default__Stand')
            local hidden=f.object(f.ui.MENU_CLASS,'hidden'); hidden.visibility=2
            local broken=f.object(f.ui.MENU_CLASS,'broken')
            return {default,hidden,broken,current}
        end
        return {current}
    end,
    remember_stand=function(menu)
        -- Fixture setup may resolve a menu before it returns f.
        assert(menu:IsValid() and menu:IsVisible())
        if f then assert(menu==current,'learned class from an unchosen menu') end
        remembers=remembers+1
        return true
    end,
}
local keys={}
for i=1,9 do keys[i]='pal'..i end
f=fixture(keys); current=f.menu
-- Expand the fixture's nine bound rows to the native 9 x 13 cell inventory.
for _,row in ipairs(f.rows) do
    local data=f.net.pals[row.key]
    for work=1,13 do data.ranks[work]=1; data.prios[work]=3 end
    for work=2,13 do
        local cell=f.object(f.ui.CELL_CLASS,row.name..'.cell'..work)
        row.WidgetTree.RootWidget:AddChild(cell)
        cell.BindedSuitability=work
        cell.WidgetTree=f.object('WidgetTree',cell.name..'.tree')
        cell.WidgetTree.RootWidget=f.object('CanvasPanel',cell.name..'.canvas')
        cell.PalCheckBox=f.object('CheckBox',cell.name..'.checkbox')
        cell.WidgetTree.RootWidget:AddChild(cell.PalCheckBox)
        f.cells[#f.cells+1]=cell
    end
end
assert(#f.cells==117)
local fallback_mode='valid'
FindAllOf=function(class)
    assert(class==f.ui.MENU_CLASS,'global cell lookup bypassed the owned roster')
    sweeps=sweeps+1
    if fallback_mode=='throw' then error('global lookup unavailable') end
    if fallback_mode=='closed' then
        local default=f.object(f.ui.MENU_CLASS,'Default__Stand')
        local hidden=f.object(f.ui.MENU_CLASS,'hidden'); hidden.visibility=2
        return {default,hidden}
    end
    return {current}
end
local function rendered()
    local n=0
    for _,cell in ipairs(f.cells) do
        local texts=f.texts(cell)
        assert(#texts==1,'duplicated or missing injected cell text')
        assert(texts[1].text=='3' and texts[1].visibility==3,'cell not painted')
        assert(cell.PalCheckBox.visibility==2,'vanilla control not replaced')
        n=n+1
    end
    assert(n==117 and f.stale_calls==0)
end
local function draw(state,expected_global)
    mode=state
    local q,s,r=queries,sweeps,remembers
    local global=f.counts['ui: menu via global lookup'] or 0
    local typed=f.counts['ui: menu via typed query'] or 0
    f.ui.detach()
    assert(f.ui.refresh(f.cfg),'refresh failed in '..state)
    assert(queries==q+1,'refresh did not reacquire current candidates')
    assert(sweeps==s+expected_global,state..': wrong global fallback count')
    assert(remembers==r+1,'chosen current menu did not teach its class')
    assert((f.counts['ui: menu via global lookup'] or 0)==global+expected_global)
    assert((f.counts['ui: menu via typed query'] or 0)==typed+1-expected_global)
    rendered()
end
-- Real wired contract: nil AND empty preserve fresh global discovery.
draw('nil',1)
draw('empty',1)
draw('good',0)
mode='mixed'
assert(not f.ui.refresh(f.cfg),'visible but unreadable second tree authorized a menu')
assert(f.ui.is_open(),'incomplete discovery was mistaken for a proven close')
draw('good',0) -- recover without another native BindFromSlot

-- Replace menu, tree and every tree object with new wrappers carrying the same
-- native names. Poison all old wrappers (including IsValid) before the next
-- refresh. Only scalar ownership caches may survive this boundary.
local function replace_wrappers()
    local originals={table.unpack(f.objects)}
    local replacements={}
    for _,old in ipairs(originals) do
        replacements[old]=f.object(old.class,old.name:sub(#old.class+2))
    end
    local seen={}
    local function copy(value)
        if type(value)~='table' then return value end
        if replacements[value] then return replacements[value] end
        if seen[value] then return seen[value] end
        local result={}; seen[value]=result
        for k,v in pairs(value) do result[copy(k)]=copy(v) end
        return result
    end
    for _,old in ipairs(originals) do
        local replacement=replacements[old]
        for k,v in pairs(old) do
            if type(v)~='function' then replacement[k]=copy(v) end
        end
    end
    current=replacements[current]
    for _,key in ipairs({'menu','root','roster_widget','roster','rows','cells','menus'}) do
        f[key]=copy(f[key])
    end
    for _,old in ipairs(originals) do old.dead=true end
end
replace_wrappers()
draw('good',0)
-- Fallback also has to consume fresh wrappers rather than the previous typed
-- result, even when the full menu name has not changed.
replace_wrappers()
draw('nil',1)
replace_wrappers()
draw('empty',1)

for _,state in ipairs({'nil','empty'}) do
    mode=state; fallback_mode='closed'
    local before=sweeps
    assert(not f.ui.refresh(f.cfg),'closed stand resurrected a previous menu')
    assert(sweeps==before+1 and not f.ui.is_open() and f.stale_calls==0)
    fallback_mode='valid'
    -- A real fresh row bind wakes the closed stand on reopening.
    f.bind(f.rows[1]); draw('good',0)
end
mode='hidden'
local before=sweeps
assert(not f.ui.refresh(f.cfg),'hidden typed menu was treated as visible')
assert(sweeps==before,'nonempty hidden typed result triggered global fallback')
f.bind(f.rows[1]); draw('good',0)
mode='nil'; fallback_mode='throw'
assert(not f.ui.refresh(f.cfg),'failed fallback resurrected a previous menu')
assert(f.stale_calls==0)
print('Direct typed stand integration: 117 cells; fresh fast route; nil/empty fallback; close/reopen')
