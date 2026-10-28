-- Actual ui.lua / pad.lua / session.lua integration with a small native tree.
-- These tests exercise Lua routing and state transitions, not Unreal lifetime
-- safety, reflection compatibility, geometry, or measured frame-time costs.
local failures, passed = {}, 0
local production_cycle = require('store').cycle
local function check(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print('PASS stand integration: ' .. name)
    else failures[#failures+1] = name .. ': ' .. tostring(err) end
end

local function fixture(keys)
    for _, name in ipairs({'ui','pad','session','ui_tree','ui_render','stand_input','stand_pointer','stand_lifecycle','measurement'}) do
        package.loaded[name] = nil
    end
    local f = {authority=false, viewport=true, objects={}, menus={}, rows={}, cells={},
        writes={}, pending={}, hooks={}, bindings={}, buttons={}, warnings={}, rank_calls=0,
        stale_calls=0, serial=0, cfg={}, counts={}, timings={}}
    local function noop() end
    package.loaded.log = {perf=false, count=function(label)
        f.counts[label]=(f.counts[label] or 0)+1; return {ms=0}
    end, around=function(label,fn,...)
        f.timings[label]=(f.timings[label] or 0)+1; return fn(...)
    end,
        say=noop, info=noop, debug=noop, warn=function(s) f.warnings[#f.warnings+1]=s end}
    package.loaded.clock = {every=noop, cancel=noop}
    local function object(class, name)
        local o = {class=class, name=class .. ' ' .. name, children={}, visibility=0, Font={Size=14}}
        local function fresh()
            if o.dead then f.stale_calls=f.stale_calls+1; error('stale wrapper: '..o.name) end
        end
        function o:IsValid() fresh(); return true end
        function o:GetFullName() fresh(); return self.name end
        function o:GetClass()
            fresh(); return {GetFName=function() return {ToString=function() return class end} end,
                GetFullName=function() return class=='WBP_WorkSuitabilityPreferenceMenu_C'
                    and 'WidgetBlueprintGeneratedClass /Game/Pal/Blueprint/UI/UserInterface/IngameMenu/WorkSuitabilityPreference/WBP_WorkSuitabilityPreferenceMenu.WBP_WorkSuitabilityPreferenceMenu_C'
                    or 'Class /Script/Test.'..class end}
        end
        function o:GetFName() fresh(); return {ToString=function() return name end} end
        function o:GetChildrenCount() fresh(); if self.fail_children then error('tree unavailable') end; return #self.children end
        function o:GetChildAt(i) fresh(); return self.children[i+1] end
        -- Actual native leaves have no panel child API. Blueprint text is still
        -- terminal despite its _C suffix; it has no UserWidget child tree either.
        if class=='TextBlock' or class=='CheckBox' or class=='BP_PalTextBlock_C' then
            o.GetChildrenCount=nil; o.GetChildAt=nil
        end
        function o:GetParent() fresh(); return self.parent end
        function o:GetOuter() fresh(); return self.outer end
        function o:IsVisible() fresh(); if self.fail_visibility then error('visibility unavailable') end; return self.visibility==0 end
        function o:IsHovered() fresh(); return self.hovered==true end
        function o:HasAnyUserFocus() fresh(); return f.focus==self end
        function o:HasFocusedDescendants() fresh(); return self==f.menu and f.menu_focus~=false end
        function o:SetKeyboardFocus() fresh(); f.focus=self end
        function o:GetVisibility() fresh(); return self.visibility end
        function o:SetVisibility(v) fresh(); self.visibility=v end
        function o:SetText(v)
            fresh(); self.text_writes=(self.text_writes or 0)+1
            if self.fail_text then error('text write failed') end; self.text=v
        end
        function o:SetColorAndOpacity(v) fresh(); self.colour=v end
        function o:SetBrushColor(v) fresh(); self.brush=v end
        function o:SetToolTipText(v) fresh(); self.tooltip=v end
        function o:SetFont(v) fresh(); self.Font=v end
        function o:SetJustification() fresh() end
        function o:SetShadowOffset() fresh() end
        function o:AddChild(child)
            fresh(); if self.reject_child then return nil end
            child.parent=self; self.children[#self.children+1]=child
            local slot=object('CanvasPanelSlot', name..'.slot'..#self.children)
            child.Slot=slot
            return slot
        end
        for _, field in ipairs({'Anchors','Position','Size','Alignment','ZOrder','Padding',
            'HorizontalAlignment','VerticalAlignment','AutoSize'}) do
            o['Get'..field]=function() fresh(); return field=='ZOrder' and 0 or {} end
            o['Set'..field]=function() fresh() end
        end
        f.objects[#f.objects+1]=o
        return o
    end
    f.object=object
    local pc=object('PalPlayerController','pc')
    function pc:IsInputKeyDown(key) return f.buttons[key.KeyName]==true end
    package.loaded.palapi = {
        has_viewport=function() return f.viewport end,
        has_authority=function() return f.authority end,
        local_player_controller=function() return pc end,
        as_int=math.tointeger, instance_key=function(id) return id.test_key end,
        pal_name=function() return 'Mock Pal' end, pal_species=function() return 'Mock' end,
        suitability_rank=function(_, work)
            f.rank_calls=f.rank_calls+1
            assert(f.authority==true, 'native rank read on a client')
            return work==1 and 1 or 0
        end,
        cdo=function(path)
            if path=='/Script/UMG.Default__WidgetBlueprintLibrary' then return f.widget_lib end
            if path=='/Script/AssetRegistry.Default__AssetRegistryHelpers' then return f.registry end
            return {path=path}
        end,
    }
    f.net={status='ready', pals={}, pals_gen=1, pending_gen=0, PREFIX='PWP:', to_server=function() return false end}
    function f.net.pending_priority(key,work)
        local row=f.pending[key]
        if row and row[work]~=nil then return row[work],true,'pending' end
        return nil,false
    end
    package.loaded.net=f.net
    package.loaded.store={decided=true, flush=noop,
        effective=function(_,pal,_,work) return f.net.pals[pal.key].prios[work] end,
        cycle=production_cycle,
        set=function(key,work,value)
            f.writes[#f.writes+1]={key=key,work=work,value=value}
            f.pending[key]=f.pending[key] or {}; f.pending[key][work]=value
            -- Matches main.lua's net.on_edit invalidation contract.
            if f.ui then f.ui.edit_status(key,work,'pending'); f.ui.detach() end
            return true
        end,
    }
    FName=function(s) return s end
    FText=function(s) return s end
    local input_class=object('WidgetBlueprintGeneratedClass','input class')
    f.registry=object('AssetRegistryHelpers','registry')
    function f.registry:GetAsset(data)
        assert(data.PackageName=='/Game/Mods/PalWorkPriority/UI/WBP_StandInput')
        assert(data.AssetName=='WBP_StandInput_C')
        if f.registry_asset then return input_class end
    end
    EFindName={FNAME_Add=1}
    f.widget_lib=object('WidgetBlueprintLibrary','widget library')
    function f.widget_lib:Create()
        f.serial=f.serial+1
        local surface=object('WBP_StandInput_C','input'..f.serial)
        surface.PWP_Contract=2; surface.PWP_Target=''
        surface.WidgetTree=object('WidgetTree',surface.name..'.tree')
        surface.WidgetTree.RootWidget=object('Border',surface.name..'.root')
        return surface
    end
    LoadAsset=function(path)
        if path:find('WBP_StandInput',1,true) and f.native_asset~=false then return input_class end
    end
    Key={LEFT_MOUSE_BUTTON='leftmouse',RIGHT_MOUSE_BUTTON='rightmouse'}
    RegisterKeyBind=function(key, fn) f.bindings[key]=fn end
    f.pre_hooks={}
    RegisterHook=function(name, fn, post) f.hooks[name]=post or fn; if post then f.pre_hooks[name]=fn end end
    FindAllOf=function(class)
        if class=='WBP_WorkSuitabilityPreferenceMenu_C' then return f.menus end
        if class=='WBP_WorkSuitabilityPreference_CheckBox_0_C' then return f.cells end
        return {}
    end
    StaticConstructObject=function(class,tree)
        f.serial=f.serial+1
        if class and class.path=='/Script/UMG.Border' then
            return object('Border',tree.name..'.PWPBox'..f.serial)
        end
        local text=object('TextBlock',tree.name..'.PWP'..f.serial)
        text.fail_text=f.fail_new_text
        return text
    end
    f.ui=require('ui'); f.session=require('session'); f.pad=require('pad')
    f.session.begin('test world')
    f.menu=object(f.ui.MENU_CLASS,'menu')
    f.root=object('VerticalBox','menu.root')
    f.menu.WidgetTree=object('WidgetTree','menu.tree')
    f.menu.WidgetTree.RootWidget=f.root
    -- Captured September menu: its own tree owns a named roster UserWidget.
    -- Rows live inside that widget's tree, not directly in the menu root.
    f.roster_widget=object('WBP_PalCommonScrollList_C','WBP_PalCommonScrollList_PalList')
    f.roster_widget.WidgetTree=object('WidgetTree','roster.tree')
    f.roster=object('ScrollBox','ScrollBox_0')
    f.roster_widget.WidgetTree.RootWidget=f.roster
    f.root:AddChild(f.roster_widget)
    f.menus[1]=f.menu
    function f.add_row(key)
        local row=object(f.ui.ROW_CLASS,'menu.row'..(#f.rows+1))
        f.roster:AddChild(row)
        -- A real stand row is a nested UserWidget with its own WidgetTree.
        row.WidgetTree=object('WidgetTree',row.name..'.tree')
        row.WidgetTree.RootWidget=object('HorizontalBox',row.name..'.root')
        row.WidgetTree.RootWidget.outer=row
        local cell=object(f.ui.CELL_CLASS,row.name..'.cell1')
        row.WidgetTree.RootWidget:AddChild(cell)
        cell.BindedSuitability=1
        cell.WidgetTree=object('WidgetTree',cell.name..'.tree')
        cell.WidgetTree.RootWidget=object('CanvasPanel',cell.name..'.canvas')
        local cb=object('CheckBox',cell.name..'.checkbox')
        cell.WidgetTree.RootWidget:AddChild(cb)
        cell.PalCheckBox=cb
        f.rows[#f.rows+1]=row; f.cells[#f.cells+1]=cell
        f.net.pals[key]={ranks={[1]=1},prios={[1]=3}}
        row.key=key
        return row,cell
    end
    for _, key in ipairs(keys or {'a'}) do f.add_row(key) end
    -- Register the real BindFromSlot closure, then deliver fresh native args.
    f.ui.refresh(f.cfg)
    function f.bind(row,key)
        row.key=key or row.key
        local param=object('PalIndividualCharacterParameter','param')
        local handle=object('PalIndividualCharacterHandle','handle')
        function handle:GetIndividualID()
            return {test_key=row.key,PlayerUId={A=1,B=0,C=0,D=0},InstanceId={A=2,B=0,C=0,D=0}}
        end
        function handle:TryGetIndividualParameter() return param end
        local slot=object('PalSlot','slot'); slot.Handle=handle
        local delivered=false
        for name,fn in pairs(f.hooks) do
            if name:find(':BindFromSlot',1,true) then
                fn({get=function() return row end},{get=function() return slot end}); delivered=true
            end
        end
        assert(delivered,'BindFromSlot hook was not installed')
    end
    for _,row in ipairs(f.rows) do f.bind(row) end
    -- The stand legends in a root: each is a Border we own holding one TextBlock.
    function f.legends(root)
        local out={}
        for _,w in ipairs((root or f.root).children) do
            if w.class=='Border' and w.children[1] and w.children[1].class=='TextBlock' then
                out[#out+1]=w.children[1]
            end
        end
        return out
    end
    function f.texts(cell)
        local out={}
        for _,w in ipairs(cell.WidgetTree.RootWidget.children) do
            if w.class=='TextBlock' then out[#out+1]=w end
        end
        return out
    end
    function f.pointer(cell,dir)
        for _,w in ipairs(cell.WidgetTree.RootWidget.children) do
            if w.class=='WBP_StandInput_C' then
                w.PWP_Direction=dir
                f.hooks[require('stand_pointer').path..':PWP_Dispatch']({get=function() return w end})
                return
            end
        end
        return false -- an unavailable cell has no native edit receiver
    end
    function f.click(dir)
        -- Synthetic native hit-test dispatch at event time, not queue drain.
        for _,cell in ipairs(f.cells) do if cell.hovered then f.pointer(cell,dir); return end end
    end
    function f.key(cell,value)
        for _,w in ipairs(cell.WidgetTree.RootWidget.children) do
            if w.class=='WBP_StandInput_C' then
                w.PWP_Priority=value==false and 0 or value
                f.hooks[require('stand_pointer').path..':PWP_KeyDispatch']({get=function() return w end})
                return
            end
        end
    end
    function f.focus_cell(cell)
        for _,w in ipairs(cell.WidgetTree.RootWidget.children) do
            if w.class=='WBP_StandInput_C' then f.focus=w; return end
        end
    end
    function f.direct(_,value)
        f.ui.bind_mouse(function() return f.cfg end)
        local target=f.cells[1]
        for i,cell in ipairs(f.cells) do
            if (f.ui.selection and f.rows[i].key==f.ui.selection.key) or cell.hovered then target=cell end
        end
        f.focus_cell(target)
        local before=#f.writes
        f.key(target,value); f.session.drain(error)
        return #f.writes>before
    end
    return f
end

check('native number keeps event-time hover despite later pointer and focus changes',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.cells[1].hovered=true; f.key(f.cells[1],false)
    f.cells[1].hovered=false; f.cells[2].hovered=true; f.focus_cell(f.cells[2])
    f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='a' and f.writes[1].value==false)
end)

check('unfocused or blocked number events cannot acquire permission after queueing',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local blocked=false
    f.ui.bind_mouse(function() return f.cfg end,nil,function() return blocked end)
    f.cells[1].hovered=true; f.focus=nil; f.key(f.cells[1],2)
    f.focus_cell(f.cells[1]); f.session.drain(error); assert(#f.writes==0)
    blocked=true; f.key(f.cells[1],2); blocked=false; f.session.drain(error); assert(#f.writes==0)
    f.key(f.cells[1],2); blocked=true; f.session.drain(error); assert(#f.writes==0)
    assert(not f.ui.direct(f.cfg,2),'raw direct call acquired a later hover')
end)

check('number edits cannot cross row rebinds, session changes, or receiver replacement',function()
    for _,change in ipairs({'row','session','receiver'}) do
        local f=fixture(); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
        f.focus_cell(f.cells[1]); f.key(f.cells[1],5)
        if change=='row' then
            f.net.pals.b={ranks={[1]=1},prios={[1]=3}}
            f.bind(f.rows[1],'b')
        elseif change=='session' then f.session.begin('replacement world')
        else f.focus.PWP_Target='replacement' end
        f.session.drain(error); assert(#f.writes==0,change..' accepted old intent')
    end
end)

check('rapid native numbers preserve order including X and reject invalid values',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.key(f.cells[1],5); f.key(f.cells[1],false); f.key(f.cells[1],1)
    f.key(f.cells[1],14); f.key(f.cells[1],1.5); f.session.drain(error)
    assert(#f.writes==3 and f.writes[1].value==5 and f.writes[2].value==false and f.writes[3].value==1)
end)

check('controller codes on the stand: LB steps toward 1, RB toward X, View opens the panel',function()
    -- StandInput contract 3 (2026-10-22): 11 = LB, 12 = RB, 13 = View. Steps
    -- cycle from the pending value, like Enter and the mouse buttons.
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    local opened=0
    f.ui.open_panel=function() opened=opened+1 end
    f.focus_cell(f.cells[1]); f.key(f.cells[1],5); f.key(f.cells[1],11); f.key(f.cells[1],11)
    f.key(f.cells[1],12); f.key(f.cells[1],13); f.session.drain(error)
    assert(#f.writes==4,'expected four writes, got '..#f.writes)
    assert(f.writes[1].value==5 and f.writes[2].value==4 and f.writes[3].value==3 and f.writes[4].value==4,
        'LB/RB did not step from the pending value')
    assert(opened==1,'View did not ask for the panel exactly once')
    f.ui.open_panel=false
end)

check('navigation cannot take focus from another menu or an unknown focus owner',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.menu_focus=false
    assert(not f.ui.nav(f.cfg,'enter') and #f.writes==0 and f.focus==nil)
    function f.menu:HasAnyUserFocus() error('focus unavailable') end
    assert(not f.ui.nav(f.cfg,'down') and f.ui.selection==nil)
end)

check('failed focus transfer cannot advertise a different selected cell',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.ui.selection={key='a',work=1}
    for _,w in ipairs(f.cells[2].WidgetTree.RootWidget.children) do
        if w.class=='WBP_StandInput_C' then function w:SetKeyboardFocus() end end
    end
    assert(not f.ui.nav(f.cfg,'down') and f.ui.selection.key=='a')
    f.key(f.cells[1],2); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='a')
end)

check('native arrow then number uses new focus without a duplicate raw move',function()
    local f=fixture({'a','b','c'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.key(f.cells[1],7)
    assert(f.ui.selection.key=='b','native Down did not navigate synchronously')
    assert(not f.ui.raw_nav(f.cfg,'down'),'raw observer duplicated native Down')
    f.key(f.cells[2],2); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='b' and f.ui.selection.key=='b')
end)

check('queued hovered number preserves a later native navigation selection',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.cells[1].hovered=true; f.key(f.cells[1],2)
    f.cells[1].hovered=false; f.key(f.cells[1],7); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='a' and f.ui.selection.key=='b')
end)

check('native Enter captures its source before later navigation and ignores pointer hover',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.cells[2].hovered=true; f.key(f.cells[1],10)
    f.key(f.cells[1],7); assert(not f.ui.raw_nav(f.cfg,'enter')); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='a' and f.writes[1].value==2 and f.ui.selection.key=='b')
end)

check('queued mouse edits preserve newer navigation and native Enter target',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    f.focus_cell(f.cells[1]); f.pointer(f.cells[1],1); f.key(f.cells[1],7)
    f.key(f.cells[2],10); f.session.drain(error)
    assert(#f.writes==2 and f.writes[1].key=='a' and f.writes[2].key=='b' and f.ui.selection.key=='b')
end)

check('controller mutations follow queued numbers and stop behind a blocking panel',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); local blocked=false
    f.ui.bind_mouse(function() return f.cfg end,nil,function() return blocked end)
    f.focus_cell(f.cells[1]); f.key(f.cells[1],false); assert(f.ui.nav(f.cfg,'raise'))
    assert(#f.writes==0,'controller mutation overtook pending number')
    f.session.drain(error)
    assert(#f.writes==2 and f.writes[1].value==false and f.writes[2].value==5)
    assert(f.ui.nav(f.cfg,'raise')); blocked=true; f.session.drain(error)
    assert(#f.writes==2)
end)

check('unreadable or ambiguous hover never falls back to editing the focused cell',function()
    for _,mode in ipairs({'unknown','ambiguous'}) do
        local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
        f.focus_cell(f.cells[1])
        if mode=='unknown' then f.cells[2].IsHovered=function() error('unreadable') end
        else f.cells[1].hovered=true; f.cells[2].hovered=true end
        f.key(f.cells[1],2); f.session.drain(error); assert(#f.writes==0)
    end
end)

check('native click keeps its event target after pointer moves',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end)
    f.cells[1].hovered=true; f.click(1)
    f.cells[1].hovered=false; f.cells[2].hovered=true
    f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].key=='a' and f.writes[1].value==4)
end)

check('raw callback without a native target cannot acquire later hover',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end)
    f.bindings.rightmouse(); f.cells[2].hovered=true; f.session.drain(error)
    assert(#f.writes==0)
    f.pointer(f.cells[2],1); f.bindings.rightmouse(); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].value==4,'raw and native paths duplicated an edit')
end)

check('native intent is rejected after surface replacement or blocking overlay',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local blocked=false
    f.ui.bind_mouse(function() return f.cfg end,nil,function() return blocked end)
    f.pointer(f.cells[1],1); blocked=true; f.session.drain(error)
    assert(#f.writes==0)
    f.pointer(f.cells[1],1); blocked=false; f.session.drain(error)
    assert(#f.writes==0,'blocked event survived overlay close')
    f.pointer(f.cells[1],1)
    for _,w in ipairs(f.cells[1].WidgetTree.RootWidget.children) do
        if w.class=='WBP_StandInput_C' then w.PWP_Target='replacement' end
    end
    f.session.drain(error); assert(#f.writes==0,'replacement surface accepted old token')
end)

check('missing input asset preserves numbers but never revives raw hover editing',function()
    local f=fixture(); f.native_asset=false; assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='3')
    f.ui.bind_mouse(function() return f.cfg end)
    f.cells[1].hovered=true; f.bindings.rightmouse(); f.session.drain(error)
    assert(#f.writes==0 and require('stand_pointer').created==0)
end)

check('mounted mod class loads through asset registry when LoadAsset cannot find it',function()
    local f=fixture(); f.native_asset=false; f.registry_asset=true
    assert(f.ui.refresh(f.cfg)); assert(require('stand_pointer').created==1)
    f.ui.bind_mouse(function() return f.cfg end); f.pointer(f.cells[1],1); f.session.drain(error)
    assert(#f.writes==1)
end)

check('native FString property wrappers are reduced to scalars inside each callback',function()
    local f=fixture(); local create=f.widget_lib.Create
    function f.widget_lib:Create(...)
        local result=create(self,...); local value=result.PWP_Target; result.PWP_Target=nil
        setmetatable(result,{
            __index=function(_,key)
                if key=='PWP_Target' then return {ToString=function() return value end} end
            end,
            __newindex=function(t,key,v)
                if key=='PWP_Target' then value=v else rawset(t,key,v) end
            end})
        return result
    end
    assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end); f.pointer(f.cells[1],1); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].value==4)
end)

check('failed native arming reuses its unarmed receiver on retry',function()
    local f=fixture()
    local create=f.widget_lib.Create
    function f.widget_lib:Create(...)
        local result=create(self,...); result.PWP_Contract=0; return result
    end
    assert(f.ui.refresh(f.cfg))
    local pointer=require('stand_pointer'); assert(pointer.created==1)
    f.ui.detach(); assert(f.ui.refresh(f.cfg)); assert(pointer.created==1)
    for _,w in ipairs(f.cells[1].WidgetTree.RootWidget.children) do
        if w.class=='WBP_StandInput_C' then w.PWP_Contract=2 end
    end
    f.ui.detach(); assert(f.ui.refresh(f.cfg)); assert(pointer.created==1)
    f.ui.bind_mouse(function() return f.cfg end); f.pointer(f.cells[1],1); f.session.drain(error)
    assert(#f.writes==1)
end)

check('unreadable new receiver name cannot leave an attached untracked widget',function()
    local f=fixture(); local create=f.widget_lib.Create
    function f.widget_lib:Create(...)
        local result=create(self,...)
        result.GetFullName=function() error('name unavailable') end
        return result
    end
    assert(f.ui.refresh(f.cfg)); f.ui.detach(); assert(f.ui.refresh(f.cfg))
    for _,w in ipairs(f.cells[1].WidgetTree.RootWidget.children) do
        assert(w.class~='WBP_StandInput_C','untracked receiver attached')
    end
    f.widget_lib.Create=create
    f.ui.detach(); assert(f.ui.refresh(f.cfg)); assert(require('stand_pointer').created==1)
end)

check('client and unknown authority never read native ranks',function()
    local f=fixture()
    assert(f.ui.refresh(f.cfg)==true,'healthy client failed to paint')
    f.authority=nil; f.net.pals={}; f.bind(f.rows[1])
    f.ui.refresh(f.cfg)
    assert(f.rank_calls==0,'client/undecided BindFromSlot reached native rank getter')
end)

check('real stand-binding callback is measured without per-call messages',function()
    local f=fixture()
    local label='hook: stand row binding'
    assert(f.counts[label]==1 and f.timings[label]==nil,'off-mode binding must count without timing')
    package.loaded.log.perf=true
    local before=#f.warnings
    f.bind(f.rows[1])
    assert(f.timings[label]==1,'binding callback bypassed inclusive timing wrapper')
    assert(#f.warnings==before,'measuring a normal binding emitted a warning')
end)

check('pending X and rapid clicks use pending rather than confirmed values',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.cells[1].hovered=true
    assert(f.direct(f.cfg,false))
    assert(f.writes[1].value==false,'X was converted into missing or numeric data')
    assert(f.texts(f.cells[1])[1].text=='X*','hovered number input added navigation brackets')
    assert(f.ui.bind_mouse(function() return f.cfg end)==2)
    f.click(-1); f.click(-1); f.session.drain(error)
    assert(f.writes[2].value==5 and f.writes[3].value==4,'rapid edits cycled from old confirmed 3')
end)

check('hovered number and mouse input clear the old navigation marker immediately',function()
    for _,mode in ipairs({'number','mouse','wrapping mouse'}) do
        local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
        f.ui.selection={key='a',work=1}; f.ui.detach(); assert(f.ui.refresh(f.cfg))
        assert(f.texts(f.cells[1])[1].text=='[3]')
        f.cells[2].hovered=true
        if mode=='wrapping mouse' then f.net.pals.b.prios[1]=1 end
        if mode=='number' then assert(f.direct(f.cfg,1))
        else
            f.ui.bind_mouse(function() return f.cfg end)
            f.click(-1); f.session.drain(error)
        end
        assert(f.ui.selection==nil,mode..' retained navigation focus')
        assert(f.texts(f.cells[1])[1].text=='3',mode..' left stale brackets on another cell')
        assert(not f.texts(f.cells[2])[1].text:find('[',1,true),mode..' bracketed hovered cell')
    end
end)

check('number input without hover retains the navigation focus marker',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    assert(f.ui.nav(f.cfg,'down'))
    assert(f.direct(f.cfg,1))
    assert(f.texts(f.cells[1])[1].text=='[1*]' and f.ui.selection.key=='a')
end)

check('native key capture and apply each resolve the owned roster once',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
    for _,action in ipairs({'hovered number','navigation','selected number'}) do
        local before=f.counts['ui: cells via tree'] or 0
        f.cells[1].hovered=action=='hovered number'
        if action=='navigation' then assert(f.ui.nav(f.cfg,'down'))
        else assert(f.direct(f.cfg,1)) end
        assert(f.counts['ui: cells via tree']==before+(action=='navigation' and 1 or 2),action..' repeated the roster within one stage')
    end
end)

check('a queued wrapping left then right is replayed in order',function()
    local f=fixture(); f.net.pals.a.prios[1]=1; assert(f.ui.refresh(f.cfg))
    f.cells[1].hovered=true; f.ui.bind_mouse(function() return f.cfg end)
    f.click(-1); f.click(1); f.session.drain(error)
    assert(#f.writes==2 and f.writes[1].value==false and f.writes[2].value==1,
        'opposite directions must visit pending X before returning to 1')
end)

check('controller raise and lower wrap through pending X in order',function()
    local f=fixture(); f.net.pals.a.prios[1]=1; assert(f.ui.refresh(f.cfg))
    assert(f.ui.nav(f.cfg,'down'))
    assert(f.ui.nav(f.cfg,'raise')); assert(f.ui.nav(f.cfg,'lower'))
    f.session.drain(error)
    assert(#f.writes==2 and f.writes[1].value==false and f.writes[2].value==1,
        'controller wraparound must use the latest pending choice')
end)

check('an input action only repaints its target and the previous focus',function()
    local f=fixture({'a','b','unrelated'}); assert(f.ui.refresh(f.cfg))
    f.ui.selection={key='a',work=1}; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    local untouched=f.texts(f.cells[3])[1]; local writes=untouched.text_writes
    f.cells[2].hovered=true; assert(f.direct(f.cfg,1))
    assert(untouched.text_writes==writes,'one edit redrew an unrelated Pal')
    assert(f.texts(f.cells[1])[1].text=='3' and f.texts(f.cells[2])[1].text=='1*')
end)

check('failed immediate input paint leaves the full refresh pending for recovery',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.cells[1].hovered=true
    local tb=f.texts(f.cells[1])[1]; tb.fail_text=true
    assert(f.direct(f.cfg,1),'a paint failure must not discard an accepted edit')
    assert(f.ui.wants_repaint() and f.pending.a[1]==1)
    assert(f.cells[1].PalCheckBox.visibility==0 and tb.visibility==2)
    tb.fail_text=false; assert(f.ui.refresh(f.cfg))
    assert(tb.text=='1*' and f.cells[1].PalCheckBox.visibility==2)
end)

check('session and panel-close cancellation drop queued stand mouse actions',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.cells[1].hovered=true
    f.ui.bind_mouse(function() return f.cfg end)
    f.click(1); f.session.invalidate_ui(); f.session.drain(error)
    assert(#f.writes==0,'panel-close invalidation did not cancel queued stand click')
    f.click(1); f.session.begin('new world'); f.session.drain(error)
    assert(#f.writes==0,'session transition did not cancel queued stand click')
end)

check('a skipped-only refresh cannot consume the painted generation',function()
    local f=fixture(); f.net.pals.a.ranks={}
    assert(f.ui.refresh(f.cfg)==false,'skipped cells counted as painted')
    assert(f.ui.wants_repaint(),'unpainted generation consumed')
    assert(f.warnings[#f.warnings]:find('painted no cells',1,true),'zero paint was not identified')
end)

check('native blueprint text leaves permit painting and current-tree label reuse',function()
    local f=fixture()
    local label=f.object('BP_PalTextBlock_C','native.header')
    f.root:AddChild(label)
    local cell_label=f.object('BP_PalTextBlock_C','native.cell.label')
    f.cells[1].WidgetTree.RootWidget:AddChild(cell_label)
    assert(label.GetChildrenCount==nil and label.WidgetTree==nil)
    assert(f.ui.refresh(f.cfg),'native terminal blueprint blocked the complete menu tree')
    assert(f.ui.refresh(f.cfg),'native terminal blueprint blocked the existing label lookup')
    assert(#f.texts(f.cells[1])==1 and f.texts(f.cells[1])[1].text=='3')
    assert(f.cells[1].PalCheckBox.visibility==2 and f.stale_calls==0)
end)

check('tree refusal warning names the first failure once without claiming rows were found',function()
    local f=fixture()
    local unknown=f.object('UnverifiedWidget_C','native.unknown')
    unknown.GetChildrenCount=nil
    f.roster:AddChild(unknown)
    assert(not f.ui.refresh(f.cfg))
    local warning=f.warnings[#f.warnings]
    assert(warning:find('incomplete tree',1,true) and warning:find('UnverifiedWidget_C',1,true)
        and warning:find('WidgetTree',1,true) and warning:find('visits=',1,true),warning)
    assert(not warning:find('found rows',1,true),warning)
    local n=#f.warnings
    assert(not f.ui.refresh(f.cfg) and #f.warnings==n,'same refusal flooded the log')
end)

check('stand dump completes with current tree counts and incomplete-tree reasons',function()
    local f=fixture()
    local label=f.object('BP_PalTextBlock_C','native.header'); f.root:AddChild(label)
    local function dump()
        local sink={parts={}}
        function sink:write(s) self.parts[#self.parts+1]=s end
        f.ui.dump(sink) -- Actual diagnostic entry point, no filesystem or native calls.
        return table.concat(sink.parts)
    end
    local output=dump()
    assert(output:find('tree cells: 1',1,true) and output:find('cell instances: 1',1,true),output)
    assert(output:find('row=',1,true) and not output:find('cells_under',1,true),output)
    local unknown=f.object('UnverifiedWidget_C','native.unknown')
    unknown.GetChildrenCount=nil; f.roster:AddChild(unknown)
    output=dump()
    assert(output:find('tree cells: unavailable',1,true) and output:find('WidgetTree',1,true),output)
    assert(output:find('UnverifiedWidget_C',1,true) and output:find('cell instances: 1',1,true),output)
    f.roster.children={}
    output=dump()
    assert(output:find('tree cells: 0',1,true),'empty complete tree confused with refusal')
end)

check('native input prompt outside the owned roster cannot block its grid',function()
    local f=fixture()
    local prompt=f.object('WBP_PalKeyGuideIcon_C','native.prompt')
    prompt.WidgetTree=f.object('WidgetTree','prompt.tree')
    prompt.WidgetTree.RootWidget=f.object('PalUIActionWidgetBase','prompt.action')
    prompt.WidgetTree.RootWidget.GetChildrenCount=nil
    table.insert(f.root.children,1,prompt)
    assert(f.ui.refresh(f.cfg),'unrelated input-prompt subtree blocked the roster')
    assert(f.texts(f.cells[1])[1].text=='3' and f.cells[1].PalCheckBox.visibility==2)
    f.cells[1].hovered=true; assert(f.direct(f.cfg,2))
    assert(#f.writes==1 and f.writes[1].key=='a')
end)

check('unknown native widget inside roster still blocks painting and edits',function()
    local f=fixture()
    local unknown=f.object('PalUIActionWidgetBase','roster.unknown')
    unknown.GetChildrenCount=nil; f.roster:AddChild(unknown)
    assert(not f.ui.refresh(f.cfg))
    f.cells[1].hovered=true; f.direct(f.cfg,2)
    assert(#f.writes==0 and #f.texts(f.cells[1])==0)
end)

check('missing or ambiguous owned roster never falls back to other menu cells',function()
    local f=fixture()
    f.root.children={f.rows[1]}
    assert(not f.ui.refresh(f.cfg),'missing roster imported loose/global cells')
    f.cells[1].hovered=true; f.direct(f.cfg,2); assert(#f.writes==0)
    local duplicate=f.object('WBP_PalCommonScrollList_C','WBP_PalCommonScrollList_PalList')
    duplicate.name=duplicate.name..'.other-owner'
    duplicate.WidgetTree=f.roster_widget.WidgetTree
    f.root.children={f.roster_widget,duplicate}
    assert(not f.ui.refresh(f.cfg),'ambiguous roster supplied editable cells')
end)

check('a foreign nested roster is excluded and fresh owned scope replaces old wrappers',function()
    local f=fixture({'a','foreign'})
    local nested=f.object('WBP_OtherMenu_C','foreign.menu')
    nested.WidgetTree=f.object('WidgetTree','foreign.tree')
    local foreign=f.object('WBP_PalCommonScrollList_C','WBP_PalCommonScrollList_PalList')
    foreign.name=foreign.name..'.foreign'
    foreign.WidgetTree=f.object('WidgetTree','foreign.roster.tree')
    foreign.WidgetTree.RootWidget=f.rows[2]
    nested.WidgetTree.RootWidget=foreign
    f.roster.children={f.rows[1]}; table.insert(f.root.children,1,nested)
    assert(f.ui.refresh(f.cfg))
    assert(#f.texts(f.cells[1])==1 and #f.texts(f.cells[2])==0,'foreign cells entered owned roster')
    local old=f.roster_widget
    local replacement=f.object('WBP_PalCommonScrollList_C','WBP_PalCommonScrollList_PalList')
    replacement.WidgetTree=old.WidgetTree
    f.root.children={replacement}; old.dead=true
    assert(f.ui.refresh(f.cfg) and f.stale_calls==0,'scope cache touched a stale wrapper')
end)

check('same-name replacement resolves fresh text without dereferencing old wrapper',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local old=f.texts(f.cells[1])[1]
    local replacement=f.object('TextBlock','replacement'); replacement.name=old.name
    local children=f.cells[1].WidgetTree.RootWidget.children
    for i,w in ipairs(children) do if w==old then children[i]=replacement end end
    old.dead=true
    assert(f.ui.refresh(f.cfg),'fresh replacement did not paint')
    assert(f.stale_calls==0,'cached wrapper was dereferenced before fresh tree lookup')
    assert(replacement.text=='3','replacement did not receive text')
end)

check('hide/reopen of a surviving menu does not duplicate injected text',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    assert(#f.texts(f.cells[1])==1)
    f.menu.visibility=2; assert(f.ui.refresh(f.cfg)==false)
    f.menu.visibility=0; f.bind(f.rows[1]); assert(f.ui.refresh(f.cfg))
    assert(#f.texts(f.cells[1])==1,'hidden live text was forgotten and a second control attached')
end)

check('queued mouse edit is cancelled when its row rebinds before drain',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.cells[1].hovered=true
    f.ui.bind_mouse(function() return f.cfg end)
    f.click(1)
    f.net.pals.b={ranks={[1]=1},prios={[1]=3}}
    f.bind(f.rows[1],'b')
    f.session.drain(error)
    assert(#f.writes==0,'queued click edited replacement Pal '..tostring(f.writes[1] and f.writes[1].key))
end)

check('same-Pal row rebind cancels old input even without a hidden-menu poll',function()
    for _,kind in ipairs({'mouse','number','controller'}) do
        local f=fixture(); assert(f.ui.refresh(f.cfg))
        f.ui.bind_mouse(function() return f.cfg end)
        f.focus_cell(f.cells[1])
        if kind=='mouse' then f.pointer(f.cells[1],1)
        elseif kind=='number' then f.key(f.cells[1],5)
        else assert(f.ui.nav(f.cfg,'raise')) end
        -- Close/reopen can recycle the exact same names and Pal identity
        -- between polls. Native BindFromSlot is the boundary we did observe.
        f.menu.visibility=2; f.menu.visibility=0
        f.bind(f.rows[1])
        f.session.drain(error)
        assert(#f.writes==0,kind..' survived same-Pal rebind')
        assert(f.ui.refresh(f.cfg))
        f.pointer(f.cells[1],1); f.session.drain(error)
        assert(#f.writes==1 and f.writes[1].value==4,'fresh input did not recover')
        assert(#f.texts(f.cells[1])==1,'rebind duplicated text')
    end
end)

check('native reconstruction cancels all stand edit routes without a bind or poll',function()
    for _,kind in ipairs({'mouse','number','controller'}) do
        local f=fixture(); assert(f.ui.refresh(f.cfg))
        f.ui.bind_mouse(function() return f.cfg end); f.focus_cell(f.cells[1])
        if kind=='mouse' then f.pointer(f.cells[1],1)
        elseif kind=='number' then f.key(f.cells[1],5)
        else assert(f.ui.nav(f.cfg,'raise')) end
        local epoch=f.session.ui_epoch
        local other_ran=false; f.session.enqueue(function() other_ran=true end,true)
        local callback
        for name,fn in pairs(f.hooks) do if name:match('PreferenceMenu_C:Construct$') then callback=fn end end
        assert(callback,'native reconstruction hook missing')({get=function() return f.menu end})
        f.session.drain(error)
        assert(f.session.ui_epoch==epoch and other_ran,'unrelated UI action was cancelled')
        assert(#f.writes==0,kind..' survived native reconstruction')
        assert(f.ui.refresh(f.cfg)); f.pointer(f.cells[1],1); f.session.drain(error)
        assert(#f.writes==1 and f.writes[1].value==4,'fresh input failed')
        assert(#f.texts(f.cells[1])==1,'reconstruction duplicated labels')
    end
end)

check('late destruction cannot cancel fresh edits and native reconstruction wakes discovery',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.ui.bind_mouse(function() return f.cfg end)
    local construct,destruct
    for name,fn in pairs(f.hooks) do
        if name:match('PreferenceMenu_C:Construct$') then construct=fn end
        if name:match('PreferenceMenu_C:Destruct$') then destruct=fn end
    end
    local context={get=function() return f.menu end}
    f.menu.visibility=2; assert(not f.ui.refresh(f.cfg)); assert(not f.ui.is_open())
    construct(context); f.menu.visibility=0
    assert(f.ui.is_open() and f.ui.refresh(f.cfg),'reconstruction did not wake discovery')
    f.pointer(f.cells[1],1); destruct(context); f.session.drain(error)
    assert(#f.writes==1,'late destruction cancelled new edit')
end)

check('unrelated or unreadable native lifecycle contexts cannot revoke stand input',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local lifecycle=require('stand_lifecycle'); local generation=lifecycle.generation
    local callback
    for name,fn in pairs(f.hooks) do if name:match('PreferenceMenu_C:Construct$') then callback=fn end end
    callback({get=function() return f.cells[1] end})
    callback({get=function() error('unreadable') end})
    assert(lifecycle.generation==generation)
    f.session.begin('next'); generation=lifecycle.generation
    callback({get=function() return f.menu end})
    assert(lifecycle.generation==generation,'unarmed new world accepted old callback')
end)

check('two visible stands cannot authorize an arbitrary first-menu edit',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end)
    f.pointer(f.cells[1],1)
    local duplicate=f.object(f.ui.MENU_CLASS,'second.menu')
    duplicate.WidgetTree=f.menu.WidgetTree
    f.menus[2]=duplicate
    f.session.drain(error)
    assert(#f.writes==0,'first visible menu won an ambiguous query')
    assert(not f.ui.refresh(f.cfg),'ambiguous menus counted as painted')
    duplicate.visibility=2
    assert(f.ui.refresh(f.cfg),'single visible menu failed to recover')
end)

check('unknown second-menu visibility refuses edits and retries without rebinding',function()
    for _,unknown in ipairs({'throw','nil'}) do
        local f=fixture(); assert(f.ui.refresh(f.cfg))
        f.ui.bind_mouse(function() return f.cfg end)
        f.pointer(f.cells[1],1)
        local other=f.object(f.ui.MENU_CLASS,'second.menu')
        other.WidgetTree=f.menu.WidgetTree
        local visible=other.IsVisible
        function other:IsVisible()
            if unknown=='throw' then error('visibility not available') end
            return nil
        end
        f.menus[2]=other
        f.session.drain(error)
        assert(#f.writes==0,unknown..' visibility authorized first menu')
        assert(not f.ui.refresh(f.cfg))
        other.IsVisible=visible; other.visibility=2
        assert(f.ui.refresh(f.cfg),'readable query did not recover')
        f.pointer(f.cells[1],1); f.session.drain(error)
        assert(#f.writes==1,'fresh input unavailable after query recovery')
    end
end)

check('vertical navigation follows native child order rather than reverse DFS order',function()
    local f=fixture({'top','middle','bottom'}); assert(f.ui.refresh(f.cfg))
    f.ui.selection={key='middle',work=1}
    assert(f.ui.nav(f.cfg,'down'))
    assert(f.ui.selection.key=='bottom','Down selected '..f.ui.selection.key..' above the current row')
end)

check('stand controller repeat observes the caller 16ms interval',function()
    local f=fixture({'top','middle','bottom'}); assert(f.ui.refresh(f.cfg))
    local nav=f.ui.nav; local events=0
    f.ui.nav=function(...) events=events+1; return nav(...) end
    f.buttons.Gamepad_DPad_Down=true
    -- main.lua calls this at 16ms. First press fires; repeats wait ~340ms.
    for _=1,4 do f.ui.pad_tick(f.cfg) end
    assert(events==1,'held D-pad fired '..events..' times in four 16ms callbacks')
end)

check('unattached text cannot count as a rendered cell',function()
    local f=fixture()
    f.cells[1].WidgetTree.RootWidget.reject_child=true
    assert(f.ui.refresh(f.cfg)==false,'AddChild returned nil but refresh reported successful paint')
    assert(f.ui.wants_repaint(),'unattached cell consumed its generation')
end)

check('partial paint failure leaves the generation pending',function()
    local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
    f.texts(f.cells[1])[1].fail_text=true
    f.net.pals_gen=f.net.pals_gen+1
    f.ui.refresh(f.cfg)
    assert(f.ui.wants_repaint(),'one successful cell consumed a generation containing a failed cell')
    local warning=f.warnings[#f.warnings]
    assert(warning:find('paint incomplete',1,true) and warning:find('1 cells rendered',1,true),warning)
    assert(not warning:find('painted no cells',1,true),'partial paint misreported as zero paint')
end)

check('unknown menu visibility cannot authorize an edit',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.cells[1].hovered=true
    f.menu.visibility=2; f.menu.fail_visibility=true
    f.direct(f.cfg,2)
    assert(#f.writes==0,'failed IsVisible treated as a visible editable menu')
end)

check('failed paint restores vanilla control and a later retry recovers',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local text=f.texts(f.cells[1])[1]
    text.fail_text=true; f.net.pals_gen=f.net.pals_gen+1
    assert(not f.ui.refresh(f.cfg))
    assert(f.cells[1].PalCheckBox.visibility==0,'failed paint left the vanilla checkbox hidden')
    assert(text.visibility==2,'failed text remained over the vanilla checkbox')
    text.fail_text=false
    assert(f.ui.refresh(f.cfg))
    assert(text.visibility==3 and f.cells[1].PalCheckBox.visibility==2)
end)

check('incomplete current tree never imports hidden-menu input targets',function()
    local f=fixture({'a','hidden'}); assert(f.ui.refresh(f.cfg))
    f.roster.children={f.rows[1]}
    f.roster.fail_children=true
    f.ui.selection={key='a',work=1}
    f.ui.nav(f.cfg,'down'); f.ui.nav(f.cfg,'enter')
    assert(#f.writes==0,'failed menu tree fell back to global editable cells')
end)

check('incomplete named search does not duplicate an existing label',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.cells[1].WidgetTree.RootWidget.fail_children=true
    assert(not f.ui.refresh(f.cfg))
    assert(#f.texts(f.cells[1])==1,'failed lookup was interpreted as missing text')
end)

check('a different menu discovered while draining cannot receive the old edit',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg)); f.cells[1].hovered=true
    f.ui.bind_mouse(function() return f.cfg end)
    f.click(1)
    -- The key callback has no engine calls. Discovery must reject this change
    -- even when no intervening BindFromSlot notification reached Lua.
    f.menu.name=f.ui.MENU_CLASS..' replacement-menu'
    f.session.drain(error)
    assert(#f.writes==0,'current queued action survived its own menu-generation change')
end)

check('pending values have colour, explanatory tooltip and one visible legend',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local tb=f.texts(f.cells[1])[1]; local normal=tb.colour.SpecifiedColor
    f.pending.a={[1]=1} -- Transport owns the pending value, including before notification.
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(tb.text=='1*','optimistic pending value looked confirmed')
    assert(tb.colour.SpecifiedColor~=normal,'pending value kept confirmed colour')
    assert(f.cells[1].tooltip:find('Sending',1,true),'cell lacks readable pending explanation')
    local legends=f.legends()
    assert(#legends==1 and legends[1].text==f.ui.EDIT_LEGEND and legends[1].visibility==3,
        'visible legend not attached to current menu')
    -- Readable over the world (audit E, 2026-10-28): a dark backing behind
    -- 14 pt near-white text, and the backing takes no clicks.
    local box=legends[1].parent
    assert(box.class=='Border' and box.visibility==3,'legend has no hit-test-invisible backing')
    assert(box.brush and box.brush.A>=0.8 and box.brush.R<0.05 and box.brush.G<0.05 and box.brush.B<0.05,
        'legend backing is not dark enough')
    assert(legends[1].Font.Size==14,'legend is not 14 pt')
    local c=legends[1].colour.SpecifiedColor
    assert(c.R>0.85 and c.G>0.85 and c.B>0.85,'legend text is not light on the dark backing')
    assert(legends[1].text:find('X off',1,true) and legends[1].text:find('! not saved',1,true))
    -- One line: the mouse first, then the marks and the panel key. A second
    -- line ran into the game's "unused Stat Points" bar (in game, 2026-10-22).
    assert(legends[1].text:find('Left click: toward 1',1,true) and legends[1].text:find('Right click: toward X',1,true))
    assert(not legends[1].text:find('\n',1,true),'stand legend must stay one line')
    assert(legends[1].text:find('ALT+F1: Production Limits',1,true),'legend lost the panel key')
    -- A rebound panel key is named as bound; an absent label keeps the default.
    local dm=package.loaded.darnmenu
    package.loaded.darnmenu={labels={key_panel='ALT+F7'}}
    assert(f.ui.edit_legend():find('ALT+F7: Production Limits',1,true) and not f.ui.edit_legend():find('F1',1,true))
    package.loaded.darnmenu={labels={}}
    assert(f.ui.edit_legend()==f.ui.EDIT_LEGEND)
    package.loaded.darnmenu=dm
    f.menu.visibility=2; f.ui.refresh(f.cfg)
    f.menu.visibility=0; f.bind(f.rows[1]); assert(f.ui.refresh(f.cfg))
    assert(#f.legends()==1 and f.legends()[1].text==f.ui.EDIT_LEGEND,'reopening duplicated the footer legend')
end)

check('unsaved X survives snapshot, acknowledgement and retry until durable acceptance',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.net.pals.a.prios[1]=false
    f.net.status='applied_unsaved' -- File error preserves negotiated data; it is not a disconnect.
    assert(f.ui.edit_status('a',1,'applied_unsaved','save_failed'))
    assert(f.ui.refresh(f.cfg)); local tb=f.texts(f.cells[1])[1]
    assert(tb.text=='X!','applied-but-unsaved X looked durable')
    assert(f.cells[1].tooltip:find('could not save',1,true),'save_failed leaked as a code or was hidden')
    f.ui.detach(); f.net.pals_gen=f.net.pals_gen+1; assert(f.ui.refresh(f.cfg))
    assert(tb.text=='X!','snapshot cleared durability error')
    for _,state in ipairs({'pending','acknowledged','applied'}) do
        f.ui.edit_status('a',1,state); assert(f.ui.refresh(f.cfg))
        assert(tb.text=='X!','non-durable '..state..' cleared the error')
    end
    f.ui.edit_status('a',1,'accepted'); assert(f.ui.refresh(f.cfg))
    assert(tb.text=='X','durable acceptance did not clear marker')
    assert(not f.cells[1].tooltip:find('could not save',1,true),'accepted cell retained stale error tooltip')
end)

check('rejection and timeout mark confirmed value without retaining failed optimistic value',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.pending.a={[1]=false}; f.ui.edit_status('a',1,'pending'); f.ui.refresh(f.cfg)
    f.pending.a=nil; f.ui.edit_status('a',1,'rejected','not_authorized')
    assert(f.ui.refresh(f.cfg)); assert(f.texts(f.cells[1])[1].text=='3!')
    f.ui.edit_status('a',1,'pending'); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3!','retry hid rejection')
    f.ui.edit_status('a',1,'timed_out','ack_timeout'); f.ui.refresh(f.cfg)
    assert(f.cells[1].tooltip:find('did not acknowledge',1,true))
    f.ui.edit_status('a',1,'accepted'); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3')
end)

check('connecting and missing priorities show unknown without fabricating X',function()
    local f=fixture(); f.net.status='connecting'; f.net.pals={}
    assert(f.ui.refresh(f.cfg)); assert(f.texts(f.cells[1])[1].text=='?')
    assert(f.cells[1].tooltip:find('Connecting',1,true)); assert(f.rank_calls==0)
    f.net.status='ready'; f.net.pals.a={ranks={[1]=1},prios={}}
    f.ui.detach(); assert(f.ui.refresh(f.cfg)); assert(f.texts(f.cells[1])[1].text=='?')
    f.cells[1].hovered=true; f.ui.bind_mouse(function() return f.cfg end)
    f.click(1); f.session.drain(error)
    assert(#f.writes==0,'cycling unknown priority invented a new value')
end)

-- Audit A5 (2026-10-28): a server that never completes the handshake used to
-- leave "?" in every cell and the checkbox hidden for the whole session.
local function receiver_of(cell)
    for _,w in ipairs(cell.WidgetTree.RootWidget.children) do
        if w.class=='WBP_StandInput_C' then return w end
    end
end
local function no_unknown(f)
    for _,cell in ipairs(f.cells) do
        for _,tb in ipairs(f.texts(cell)) do
            if tostring(tb.text or ''):find('?',1,true) then return false end
        end
    end
    return true
end
for _,case in ipairs({
    {status='incompatible',reason='server_requires_matching_mod',says='different Pal Work Priority version'},
    {status='incompatible',reason='schema_or_work_width',says='until both match'},
    {status='connecting',reason='handshake_timeout',says='does not run Pal Work Priority'},
    {status='unavailable',reason='settings_recovering',says='works as in the base game'},
}) do
    check('server without a finished handshake gives the stand back: '..case.status..'/'..case.reason,function()
        local f=fixture({'a','b'}); assert(f.ui.refresh(f.cfg))
        f.ui.bind_mouse(function() return f.cfg end)
        assert(f.cells[1].PalCheckBox.visibility==2 and receiver_of(f.cells[1]).visibility==0)
        -- The server's data goes with the session; nothing is left to draw.
        f.net.status,f.net.status_reason=case.status,case.reason; f.net.pals={}
        f.net.pals_gen=f.net.pals_gen+1
        assert(f.ui.refresh(f.cfg),'a vanilla stand left its generation unpainted')
        assert(not f.ui.wants_repaint(),'a vanilla stand would repaint every beat')
        for _,cell in ipairs(f.cells) do
            assert(cell.PalCheckBox.visibility==0,'vanilla checkbox stayed hidden')
            assert(f.texts(cell)[1].text=='','a number or mark stayed over the checkbox')
            local r=receiver_of(cell)
            assert(r.visibility==2 and r.PWP_Target=='','the stand receiver stayed armed')
            assert(cell.tooltip=='','vanilla cell kept a tooltip of ours')
        end
        assert(no_unknown(f),'"?" drawn on a server that will not answer')
        assert(f.ui.legend_text():find(case.says,1,true),f.ui.legend_text())
        assert(f.legends()[1].text==f.ui.legend_text(),'the legend did not say why')
        -- No edit can start: pointer, number key, navigation.
        f.cells[1].hovered=true; f.click(-1); f.key(f.cells[1],2); f.session.drain(error)
        assert(#f.writes==0)
        assert(not f.ui.capture_direct() and not f.ui.nav(f.cfg,'raise') and not f.ui.nav(f.cfg,'here'))
        -- A later refresh keeps it that way rather than flickering.
        f.ui.detach(); assert(f.ui.refresh(f.cfg)); assert(no_unknown(f))
    end)
end

check('the vanilla legend names this version and the incompatible case',function()
    local f=fixture()
    local file=assert(io.open(TEST_ROOT..'/Scripts/main.lua','rb'))
    local main=file:read('a'); file:close()
    local version=main:match('local%s+VERSION%s*=%s*"([^"]+)"')
    assert(version and f.ui.MOD_VERSION==version,'ui.MOD_VERSION is not main.lua VERSION '..tostring(version))
    assert(f.ui.VANILLA_ABSENT=='This server does not run Pal Work Priority '..version
        ..'. The stand works as in the base game.')
    assert(f.ui.VANILLA_INCOMPATIBLE=='This server runs a different Pal Work Priority version. '
        ..'The stand works as in the base game until both match.')
end)

check('brief connecting stays unknown; the handshake timeout latches until a Welcome or new session',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.net.local_nonce='n1'; f.net.server_nonce=nil
    f.net.status,f.net.status_reason='connecting','awaiting_handshake'; f.net.pals={}
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='?','a normal join lost its brief unknown state')
    assert(f.cells[1].PalCheckBox.visibility==2)
    assert(f.cells[1].tooltip:find('Connecting',1,true))
    assert(f.ui.legend_text()==f.ui.EDIT_LEGEND)
    f.net.status_reason='handshake_timeout'; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.cells[1].PalCheckBox.visibility==0 and f.texts(f.cells[1])[1].text=='')
    -- The next Hello that cannot be sent reports transport_unavailable for a
    -- beat; the stand must not flicker back to "?".
    f.net.status_reason='transport_unavailable'; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.cells[1].PalCheckBox.visibility==0 and f.texts(f.cells[1])[1].text=='','latch lost on a send failure')
    assert(f.ui.legend_text()==f.ui.VANILLA_ABSENT)
    -- A late Welcome: the mod is there after all; "?" until the snapshots arrive.
    f.net.server_nonce='srv'; f.net.status_reason='awaiting_snapshots'
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='?' and f.cells[1].PalCheckBox.visibility==2)
    f.net.status,f.net.status_reason='ready',nil; f.net.pals.a={ranks={[1]=1},prios={[1]=3}}
    f.net.pals_gen=f.net.pals_gen+1; assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='3' and receiver_of(f.cells[1]).visibility==0,'grid did not come back')
    -- A new session (new nonce) starts unknown again, not latched.
    f.net.server_nonce=nil; f.net.local_nonce='n2'
    f.net.status,f.net.status_reason='connecting','transport_unavailable'; f.net.pals={}
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='?','a new session inherited the old timeout')
end)

check('vanilla stand keeps its reason in the tooltip when the root takes no legend',function()
    local f=fixture(); local inner=f.root
    local root=f.object('SizeBox','single-child-root'); root:AddChild(inner)
    f.menu.WidgetTree.RootWidget=root
    assert(f.ui.refresh(f.cfg)); assert(f.ui.legend_mode=='tooltip')
    f.net.status='incompatible'; f.net.pals={}; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.cells[1].tooltip==f.ui.VANILLA_INCOMPATIBLE)
    assert(f.cells[1].PalCheckBox.visibility==0)
end)

check('controller does not take the focus from a vanilla stand',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    package.loaded.palapi.input_is_gamepad=function() return true end
    f.net.status='incompatible'; f.net.pals={}; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    local nav=f.ui.nav; local asked=0
    f.ui.nav=function(...) asked=asked+1; return nav(...) end
    f.ui.pad_tick(f.cfg)
    f.ui.nav=nav; package.loaded.palapi.input_is_gamepad=nil
    assert(asked==0 and f.focus==nil,'controller handover ran on a vanilla stand')
end)

check('every stand legend fits one 1280x720 line and names controller buttons',function()
    local f=fixture()
    for _,text in ipairs({f.ui.EDIT_LEGEND,f.ui.PAD_LEGEND,f.ui.VANILLA_ABSENT,f.ui.VANILLA_INCOMPATIBLE,
        f.ui.PAK_MISSING,'Server settings are locked. The host must restart the game or server before editing can resume.'
            ..f.ui.VANILLA_LOCKED}) do
        assert(#text<=f.ui.LEGEND_MAX_CHARS,'legend too wide at 14 pt: '..#text..' '..text)
        assert(not text:find('\n',1,true),'stand legend must stay one line')
    end
    assert(f.ui.PAD_LEGEND:find('X button: set X',1,true) and not f.ui.PAD_LEGEND:find('X: off',1,true))
    assert(f.ui.PAD_LEGEND:find('View button: Production Limits',1,true))
    local api=package.loaded.palapi; api.last_input_type=1
    assert(f.ui.legend_text()==f.ui.PAD_LEGEND); api.last_input_type=nil
end)

check('a Pal with the same number on every job is told the game picks',function()
    local f=fixture({'same','mixed'})
    -- Two capable jobs each; only the first has a cell on this stand, and the
    -- hint reads the Pal's whole row from the data.
    f.net.pals.same={ranks={[1]=1,[2]=1},prios={[1]=3,[2]=3}}
    f.net.pals.mixed={ranks={[1]=1,[2]=1},prios={[1]=3,[2]=1}}
    f.ui.detach(); f.net.pals_gen=f.net.pals_gen+1; assert(f.ui.refresh(f.cfg))
    assert(f.cells[1].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true),'same-number Pal got no hint')
    assert(not f.cells[2].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true),'steered Pal got the hint')
    -- X is not a number: 3 and X leaves one numbered job, nothing to choose.
    f.net.pals.same.prios[2]=false; f.net.pals_gen=f.net.pals_gen+1; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(not f.cells[1].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true),'one numbered job got the hint')
    f.net.pals.same.prios[2]=3; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.cells[1].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true))
    -- An edit repaints with the new answer, not a memo from the last grid.
    f.cells[1].hovered=true; f.ui.bind_mouse(function() return f.cfg end)
    f.click(-1); f.session.drain(error)
    assert(#f.writes==1 and f.writes[1].value==2)
    assert(not f.cells[1].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true),'input paint reused a stale answer')
    -- Off in config: the scheduler steers equal numbers, so no hint.
    f.pending.same=nil; f.cfg.leave_unordered_pals_to_game=false; f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(not f.cells[1].tooltip:find(f.ui.SAME_NUMBER_HINT,1,true))
end)

check('edit history resets on session change and explicit UI reset',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.ui.edit_status('a',1,'rejected'); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3!')
    f.session.begin('replacement world'); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3','session retained previous error')
    f.ui.edit_status('a',1,'rejected'); f.ui.refresh(f.cfg)
    f.net.local_nonce='reconnected-to-restarted-server'; f.ui.detach(); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3','transport reset in the same world retained previous error')
    f.ui.edit_status('a',1,'applied_unsaved','save_failed'); f.ui.refresh(f.cfg)
    -- Simulate the new native tree after reset; old widgets no longer belong to it.
    f.ui.reset(); f.cells[1].WidgetTree.RootWidget.children={f.cells[1].PalCheckBox}
    f.root.children={f.roster_widget}; f.roster.children={f.rows[1]}
    f.bind(f.rows[1]); assert(f.ui.refresh(f.cfg))
    assert(f.texts(f.cells[1])[1].text=='3','UI reset retained previous error')
end)

check('128-entry history is bounded and eviction cannot masquerade as acceptance',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.ui.edit_status('a',1,'applied_unsaved','save_failed')
    for i=1,150 do
        local ok,n=f.ui.edit_status('key'..i,1,'pending',string.rep('x',500))
        assert(ok and n<=128,'edit history exceeded 128 entries')
    end
    assert(f.ui.refresh(f.cfg)); assert(f.texts(f.cells[1])[1].text=='3?','evicted error looked accepted')
    local ok,n=f.ui.edit_status('a',1,'accepted')
    assert(ok and n==128); f.ui.refresh(f.cfg)
    assert(f.texts(f.cells[1])[1].text=='3','explicit acceptance did not resolve bounded-history unknown')
    assert(not f.ui.edit_status({},1,'pending'))
    assert(not f.ui.edit_status('a',{},'pending'))
    assert(not f.ui.edit_status('a',1,'fabricated'))
end)

check('legend refresh resolves replacement wrapper in the current root',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    local old,index
    for i,w in ipairs(f.root.children) do if w.class=='Border' then old,index=w,i end end
    assert(old and old.children[1] and old.children[1].text==f.ui.EDIT_LEGEND,'legend absent')
    -- Same names, new wrappers: both the backing and its text are resolved again.
    local replacement=f.object('Border','newlegendbox'); replacement.name=old.name
    replacement.Slot=f.object('VerticalBoxSlot','newlegendslot')
    local text=f.object('TextBlock','newlegend'); text.name=old.children[1].name
    replacement:AddChild(text)
    f.root.children[index]=replacement; old.dead=true; old.children[1].dead=true
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(f.stale_calls==0 and text.text==f.ui.EDIT_LEGEND and replacement.brush)
    -- A backing whose text never attached is filled, not duplicated.
    replacement.children={}
    f.ui.detach(); assert(f.ui.refresh(f.cfg))
    assert(#replacement.children==1 and replacement.children[1].text==f.ui.EDIT_LEGEND)
    assert(#f.legends()==1,'retry added a second legend')
end)

check('unknown root uses tooltip legend without replacing native content',function()
    local f=fixture(); local inner=f.root
    local root=f.object('SizeBox','single-child-root'); root:AddChild(inner)
    f.menu.WidgetTree.RootWidget=root
    assert(f.ui.refresh(f.cfg))
    assert(#root.children==1 and root.children[1]==inner,'legend replaced native single-child content')
    assert(f.ui.legend_mode=='tooltip')
    assert(f.cells[1].tooltip:find(f.ui.EDIT_LEGEND,1,true),'fallback lost the help legend')
end)

check('row recycling clears another Pals tooltip on incapable vanilla cells',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.ui.edit_status('a',1,'applied_unsaved','save_failed'); f.ui.refresh(f.cfg)
    assert(f.cells[1].tooltip:find('could not save',1,true))
    f.net.pals.b={ranks={},prios={}}; f.bind(f.rows[1],'b'); f.ui.refresh(f.cfg)
    assert(f.cells[1].tooltip=='' and f.texts(f.cells[1])[1].text=='',
        'recycled incapable cell retained another Pals warning')
end)

check('settings fence explains recovery and terminal closure, blocks queued edits',function()
    local f=fixture(); assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function() return f.cfg end)
    f.cells[1].hovered=true
    f.focus_cell(f.cells[1]); f.key(f.cells[1],4)
    local gate=require('settings_gate');local token=assert(gate.acquire())
    assert(f.ui.refresh(f.cfg))
    assert(f.ui.legend_text():find('Loading saved settings',1,true))
    assert(f.texts(f.cells[1])[1].text=='?')
    assert(f.cells[1].tooltip:find('temporarily locked',1,true))
    f.session.drain(error); assert(#f.writes==0)
    assert(not f.ui.capture_direct() and not f.ui.nav(f.cfg,'raise'))
    assert(gate.require_restart(token)); assert(f.ui.refresh(f.cfg))
    assert(f.ui.legend_text():find('Restart the game',1,true))
    assert(f.cells[1].tooltip:find('Restart the game',1,true))
    assert(f.legends()[1].text==f.ui.legend_text(),'footer did not change on closure')
    f.key(f.cells[1],false); f.session.drain(error); assert(#f.writes==0)
    assert(gate.release(token));assert(f.ui.refresh(f.cfg))
    assert(f.ui.legend_text()==f.ui.EDIT_LEGEND)
    assert(f.texts(f.cells[1])[1].text~='?')
end)

check('server settings fence explains host action and cancels queued input',function()
    local f=fixture();assert(f.ui.refresh(f.cfg))
    f.ui.bind_mouse(function()return f.cfg end)
    f.cells[1].hovered=true;f.focus_cell(f.cells[1]);f.key(f.cells[1],4)
    f.net.status='unavailable';f.net.status_reason='settings_restart_required'
    assert(f.ui.refresh(f.cfg))
    -- The server's scheduler is fenced too, so its stand is the game's again
    -- (audit A5): checkbox back, no "?", the legend says why.
    assert(f.texts(f.cells[1])[1].text=='','fenced server still drew a priority cell')
    assert(f.cells[1].PalCheckBox.visibility==0,'fenced server kept the vanilla checkbox hidden')
    assert(f.ui.legend_text():find('host must restart',1,true))
    assert(f.ui.legend_text():find('works as in the base game',1,true))
    assert(f.legends()[1].text==f.ui.legend_text())
    assert(f.cells[1].tooltip=='','vanilla cell kept a tooltip of ours')
    assert(not f.ui.capture_direct() and not f.ui.nav(f.cfg,'raise'))
    f.session.drain(error);assert(#f.writes==0)
    local _,label,detail=require('panel_status').save({view_status=function()
        return f.net.status,f.net.status_reason
    end})
    assert(label=='Settings unavailable' and detail:find('host must restart',1,true))
    f.net.status_reason='settings_recovering';assert(f.ui.refresh(f.cfg))
    assert(f.ui.legend_text():find('server is loading',1,true))
    f.net.status='ready';f.net.status_reason=nil;assert(f.ui.refresh(f.cfg))
    assert(f.ui.legend_text()==f.ui.EDIT_LEGEND)
    assert(f.texts(f.cells[1])[1].text=='3' and f.cells[1].PalCheckBox.visibility==2,'grid did not come back')
end)

print(string.format('Stand integration: %d passed, %d failed',passed,#failures))
assert(#failures==0,table.concat(failures,'\n'))
