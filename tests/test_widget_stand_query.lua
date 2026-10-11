local class_name='WBP_WorkSuitabilityPreferenceMenu_C'
local class_full='WidgetBlueprintGeneratedClass /Game/UI/Menu.'..class_name
local pc, lib={},{}
local local_view=true
local queries,loads=0,0
local last_class
local mode='good'
package.loaded.palapi={
    valid=function(w) return type(w)=='table' and not w.dead end,
    unwrap=function(w) return w end,
    has_viewport=function() return local_view end,
    local_player_controller=function() return pc end,
    cdo=function() return lib end,
}
local function widget(name)
    return {GetFullName=function(self) assert(not self.dead); return name end,
        GetClass=function() return {GetFullName=function() return class_full end} end}
end
LoadAsset=function(path)
    assert(path=='/Game/UI/Menu.'..class_name)
    loads=loads+1
    if last_class then last_class.dead=true end
    last_class=widget(mode=='wrong_class' and 'Class /Other' or class_full)
    return last_class
end
function lib:GetAllWidgetsOfClass(context,out,kind,top)
    queries=queries+1
    assert(context==pc and kind==last_class and not kind.dead and top==false)
    if mode=='error' then error('native query unavailable') end
    local entries={widget(class_name..' /Current.Stand')}
    if mode=='wrong_widget' then entries[2]=widget('Other /Current.Other') end
    if mode=='overflow' then for i=2,33 do entries[i]=widget(class_name..' /Current.'..i) end end
    if mode=='empty' then entries={} end
    if mode=='flat' then for k,v in pairs(entries) do out[k]=v end
    else out.FoundWidgets=entries end
end
local lookup=require('widget_lookup')
assert(lookup.stands()==nil and loads==0 and queries==0)
assert(not lookup.remember_stand(widget('Other /Bad')))
assert(lookup.remember_stand(widget(class_name..' /Current.Stand')))
local a=assert(lookup.stands())[1]
a.dead=true
local b=assert(lookup.stands())[1]
assert(a~=b and loads==2 and queries==2,'retained class or widget wrapper')
mode='flat'; assert(#lookup.stands()==1)
mode='empty'; assert(#lookup.stands()==0)
for _,state in ipairs({'wrong_class','error','wrong_widget','overflow'}) do
    mode=state; assert(lookup.stands()==nil,state..' became a complete result')
end
local_view=false
local before=loads
assert(lookup.stands()==nil and loads==before,'headless context loaded UI')
