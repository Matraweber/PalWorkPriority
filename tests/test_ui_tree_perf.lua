-- Accessor counts are deterministic Lua evidence, never native milliseconds.
local tree=require('ui_tree')
local CELL='WBP_WorkSuitabilityPreference_CheckBox_0_C'
local ROW='WBP_WorlSuitabilityPreference_PalList_C'
local failures={}
local function check(name,fn)
    local ok,err=pcall(fn)
    if ok then print('PASS tree perf: '..name)
    else failures[#failures+1]=name..': '..tostring(err) end
end
local function valid(o) return o~=nil and o:IsValid()==true end
local function scalar_meta(meta)
    for _,v in pairs(meta) do
        assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean')
    end
end
local function fixture()
    local f={objects={},calls={}}
    function f.node(class,name,edges)
        local o={kind=class,short=name,full=class..' '..name,edges=edges,calls={}}
        local function hit(key)
            assert(not o.dead,'previous callback wrapper touched')
            o.calls[key]=(o.calls[key] or 0)+1
            f.calls[key]=(f.calls[key] or 0)+1
        end
        function o:IsValid() hit('valid'); return not o.invalid end
        function o:GetFullName() hit('name'); return o.full end
        function o:GetFName()
            hit('short'); assert(not o.bad_short,'identity unreadable')
            return {ToString=function() return o.short end}
        end
        function o:GetChildrenCount()
            hit('count'); assert(o.edges and not o.bad_count,'no panel contract')
            assert(not o.truncated,'saved topology truncated inside searched scope')
            return o.count_override or #o.edges
        end
        function o:GetChildAt(i)
            hit('child'); assert(not o.bad_child,'child unreadable'); return o.edges[i+1]
        end
        setmetatable(o,{__index=function(_,key)
            if key=='WidgetTree' then
                hit('tree'); assert(o.owned and not o.bad_tree,'no private tree contract')
                return o.owned
            elseif key=='RootWidget' then
                hit('root'); assert(not o.bad_root,'root unreadable'); return o.root
            end
        end})
        f.objects[#f.objects+1]=o
        return o
    end
    function f.own(o,root)
        o.owned=f.node('WidgetTree',o.short..'.tree'); o.owned.root=root
        return o
    end
    function f.cell(name,children)
        local label=f.node('TextBlock',name..'.label')
        local panel=f.node('Overlay',name..'.panel',children or {label})
        return f.own(f.node(CELL,name),panel),label,panel
    end
    function f.stand(rows)
        local roster=f.own(f.node('WBP_PalCommonScrollList_C','roster'),
            f.node('ScrollBox','scroll',rows))
        roster.short='WBP_PalCommonScrollList_PalList'
        return f.own(f.node('UserWidget','menu'),f.node('CanvasPanel','owner',{roster}))
    end
    function f.row(name,children)
        local bar=f.node('HorizontalBox',name..'.bar',children or {})
        bar.short='HorizontalBox_CheckBox'
        local root=f.node('CanvasPanel',name..'.root',{bar})
        return f.own(f.node(ROW,name),root),bar,root
    end
    return f
end

check('exact panels skip unsupported trees and retain every content edge',function()
    local f=fixture()
    local classes={'CanvasPanel','Overlay','VerticalBox','HorizontalBox','GridPanel',
        'UniformGridPanel','WrapBox','ScrollBox','WidgetSwitcher','SizeBox','ScaleBox',
        'Border','Button','SafeZone','RetainerBox','NamedSlot','PanelWidget','ContentWidget','CheckBox'}
    local target=f.node(CELL,'cell')
    local root=target
    for _,class in ipairs(classes) do root=f.node(class,class,{root}) end
    local cells,meta=tree.cells(root,CELL,valid)
    assert(cells and cells[1]==target and meta.complete)
    assert((f.calls.tree or 0)==0,'native panels received failed WidgetTree probes')
    assert(f.calls.count==#classes and f.calls.child==#classes,'panel content omitted')
end)

check('exact UserWidget skips child-count but unknown classes retain both probes',function()
    local f=fixture()
    local target=f.node(CELL,'target')
    local user=f.own(f.node('UserWidget','user'),f.node('CanvasPanel','root',{target}))
    local cells=tree.cells(user,CELL,valid)
    assert(cells and cells[1]==target and (user.calls.count or 0)==0)
    for _,class in ipairs({'UserWidget_C','CanvasPanel_C','PalUIActionWidgetBase','UnknownNative'}) do
        local o=f.node(class,'unknown')
        local result,meta=tree.cells(o,CELL,valid)
        assert(not result and not meta.complete and o.calls.tree==1 and o.calls.count==1)
    end
    user.bad_tree=true
    local result,meta=tree.cells(user,CELL,valid)
    assert(not result and meta.stage=='WidgetTree','missing UserWidget tree became absence')
end)

check('row owner and fallback replay native edges once without skipping private trees',function()
    local f=fixture()
    local cell=f.node(CELL,'cell')
    local row,bar,root=f.row('row',{cell})
    bar.short='OtherLayout'
    local private=f.own(f.node('UnknownWidget_C','private'),f.node('CanvasPanel','private.root',{}))
    root.edges[#root.edges+1]=private
    local cells,meta=tree.stand_cells(f.stand({row}),CELL,valid)
    assert(cells and #cells==1 and meta.row_fallbacks==1)
    assert(root.calls.name==1 and root.calls.count==1 and root.calls.child==2)
    assert(bar.calls.name==1 and bar.calls.short==1 and bar.calls.count==1 and bar.calls.child==1)
    assert(private.calls.tree==1,'fallback reused owner seen-set and skipped private tree')
    private.bad_tree=true
    cells,meta=tree.stand_cells(f.stand({row}),CELL,valid)
    assert(not cells and meta.stage=='WidgetTree','later call reused successful private reads')
end)

check('scoped bar identity is read once and nested duplicates still refuse',function()
    local f=fixture()
    local row,bar=f.row('row',{f.node(CELL,'cell')})
    local menu=f.stand({row})
    local cells=tree.stand_cells(menu,CELL,valid)
    assert(cells and bar.calls.name==1 and bar.calls.short==1 and bar.calls.count==1)
    local nested=f.node('HorizontalBox','nested',{})
    nested.short='HorizontalBox_CheckBox'; bar.edges[#bar.edges+1]=nested
    local failed,meta=tree.stand_cells(menu,CELL,valid)
    assert(not failed and meta.stage=='checkbox bar ambiguous')
end)

check('cyclic owner edges remain bounded and do not repeat native panel reads',function()
    local f=fixture(); local row,bar,root=f.row('row',{f.node(CELL,'cell')})
    bar.short='OtherLayout'; root.edges[#root.edges+1]=root
    local cells,meta=tree.stand_cells(f.stand({row}),CELL,valid)
    assert(cells and #cells==1 and not meta.budget_exhausted)
    assert(root.calls.name==1 and root.calls.count==1 and root.calls.child==2)
end)

local function plain_hint(hint)
    assert(type(hint)=='table' and getmetatable(hint)==nil)
    assert(type(hint.root)=='string' and #hint.root<=2048)
    assert(type(hint.target)=='string' and #hint.target<=2048)
    assert(type(hint.steps)=='table' and #hint.steps<=255 and getmetatable(hint.steps)==nil)
    local keys=0
    for k in pairs(hint) do assert(k=='root' or k=='target' or k=='steps'); keys=keys+1 end
    assert(keys==3)
    for _,step in ipairs(hint.steps) do
        assert(step=='tree' or (type(step)=='number' and step%1==0 and step>=0 and step<=255))
    end
end

check('hint replay reads current owner edges and avoids preceding siblings',function()
    local f=fixture(); local cell,label,panel=f.cell('cell')
    panel.edges={}
    for i=1,100 do panel.edges[i]=f.node('Image','decoration'..i) end
    panel.edges[101]=label
    local found,complete,hint=tree.find(cell,label.full,valid)
    assert(found==label and complete); plain_hint(hint)
    assert(hint.root==cell.full and hint.target==label.full and hint.steps[1]=='tree' and hint.steps[2]==100)
    local full_names,full_children=f.calls.name,f.calls.child
    f.calls.name,f.calls.child=0,0
    local again,done,refreshed=tree.find(cell,label.full,valid,hint)
    assert(again==label and done and refreshed~=hint and refreshed.steps~=hint.steps)
    assert(f.calls.name==2 and f.calls.child==1)
    assert(full_names==103 and full_children==101)
    print(('101-child label fixture: full-name reads %d -> %d, child reads %d -> %d (hint replay)')
        :format(full_names,f.calls.name,full_children,f.calls.child))
    plain_hint(refreshed)

end)

check('moved labels and duplicate short names fall back to exact full-name discovery',function()
    local f=fixture(); local cell,label,panel=f.cell('cell')
    local _,_,hint=tree.find(cell,label.full,valid)
    local same_short=f.node('TextBlock','elsewhere.label'); same_short.short=label.short
    panel.edges={same_short,label}
    local found,done,new_hint=tree.find(cell,label.full,valid,hint)
    assert(found==label and done and new_hint.steps[2]==1,'wrong short-name match accepted')
    panel.edges={same_short} -- the old label still exists but is not currently owned
    local missing,complete,no_hint=tree.find(cell,label.full,valid,new_hint)
    assert(not missing and complete and not no_hint,'detached wrapper was reused')
end)

check('failed hint replay retains every unknown and budget refusal',function()
    for _,mode in ipairs({'tree','root','count','child','name','invalid','unknown','budget'}) do
        local f=fixture(); local cell,label,panel=f.cell('cell')
        local _,_,hint=tree.find(cell,label.full,valid)
        local target=label.full
        if mode=='tree' then cell.bad_tree=true
        elseif mode=='root' then cell.owned.bad_root=true
        elseif mode=='count' then panel.bad_count=true
        elseif mode=='child' then panel.bad_child=true
        elseif mode=='name' then label.full=false
        elseif mode=='invalid' then label.invalid=true
        elseif mode=='unknown' then panel.edges={f.node('UnknownNative','unknown')}
        else
            panel.edges={}
            for i=1,256 do panel.edges[i]=f.node('Image','decoration'..i) end
        end
        local found,complete,new_hint=tree.find(cell,target,valid,hint)
        assert(not found and not complete and not new_hint,'hint failure permitted injection: '..mode)
    end
end)

check('malformed, wrong-owner and wrong-target hints use bounded full search',function()
    local f=fixture(); local cell,label=f.cell('cell')
    local malformed={false,{}, {root='other',target=label.full,steps={}},
        {root=cell.full,target='other',steps={}},
        {root=cell.full,target=label.full,steps={-1}},
        {root=cell.full,target=label.full,steps={256}},
        {root=cell.full,target=label.full,steps={0.5}},
        {root=cell.full,target=label.full,steps={'unsupported'}},
        {root=cell.full,target=label.full,steps={[2]='tree'}},
        {root=cell.full,target=label.full,steps={[256]='tree'}},
        {root=cell.full,target=label.full,steps={{}}},
        setmetatable({},{__index=function() error('untrusted hint indexed') end})}
    for _,hint in ipairs(malformed) do
        local found,complete,new_hint=tree.find(cell,label.full,valid,hint)
        assert(found==label and complete); plain_hint(new_hint)
    end
end)

check('positive current path can skip unknown siblings just like positive find',function()
    local f=fixture(); local cell,label,panel=f.cell('cell')
    panel.edges={f.node('UnknownNative','unknown'),label}
    local found,done,hint=tree.find(cell,label.full,valid)
    assert(found==label and done)
    local prior=panel.edges[1].calls.name
    assert(tree.find(cell,label.full,valid,hint)==label)
    assert(panel.edges[1].calls.name==prior,'positive path scanned unrelated siblings')
end)

check('scalar hints survive replacement while previous callback wrappers are collectable',function()
    local hint,weak
    do
        local f=fixture(); local cell,label=f.cell('same')
        local found,complete
        found,complete,hint=tree.find(cell,label.full,valid)
        assert(found==label and complete); plain_hint(hint)
        weak=setmetatable({cell,label,cell.owned},{__mode='v'})
        for _,o in ipairs(f.objects) do o.dead=true end
    end
    collectgarbage('collect'); collectgarbage('collect')
    assert(next(weak)==nil,'hint retained an old wrapper')
    local f=fixture(); local cell,label=f.cell('same')
    local found,complete,new_hint=tree.find(cell,label.full,valid,hint)
    assert(found==label and complete); plain_hint(new_hint)
    -- Both owner and child wrappers are resolved anew even with reused names.
    assert(cell.calls.tree==1 and cell.owned.calls.root==1 and cell.owned.root.calls.child==1)
end)

check('full search and hints retain exact depth, width and name bounds',function()
    for _,depth in ipairs({255,256}) do
        local f=fixture(); local label=f.node('TextBlock','label'); local root=label
        for i=1,depth do root=f.node('CanvasPanel','node'..i,{root}) end
        local found,complete,hint=tree.find(root,label.full,valid)
        if depth==255 then
            assert(found==label and complete and #hint.steps==255); plain_hint(hint)
            assert(tree.find(root,label.full,valid,hint)==label)
        else assert(not found and not complete and not hint and not label.calls.name) end
    end
    for _,width in ipairs({256,257}) do
        local f=fixture(); local cell,label,panel=f.cell('cell')
        local _,_,hint=tree.find(cell,label.full,valid)
        panel.edges={}
        for i=1,width do panel.edges[i]=f.node('Image','image'..i) end
        panel.edges[width]=label
        local found,complete,new_hint=tree.find(cell,label.full,valid,hint)
        assert(not found and not complete and not new_hint)
    end
    local f=fixture(); local label=f.node('TextBlock',string.rep('x',2049))
    local found,complete,hint=tree.find(label,label.full,valid)
    assert(found==label and complete and not hint,'unbounded scalar name was persisted')
end)

check('unreadable current root refuses before hinted ownership access',function()
    local f=fixture(); local cell,label=f.cell('cell')
    local _,_,hint=tree.find(cell,label.full,valid)
    local prior=cell.calls.tree
    cell.full=false
    local found,complete,new_hint=tree.find(cell,label.full,valid,hint)
    assert(not found and not complete and not new_hint and cell.calls.tree==prior)
end)

check('saved September topology does not turn abbreviated branches into complete absence',function()
    -- The saved dump abbreviates private branches with "...". Those branches
    -- throw if searched; do not fabricate their missing contents or labels.
    local input=io.open(TEST_ROOT..'/test-results/deep-perf-restart-tree-20260913.txt','r')
    if not input then print('SKIP saved local topology unavailable'); return end
    local f,stack,root,active=fixture(),{},nil,false
    local expected={}
    for line in input:lines() do
        if line:find('   widget tree:',1,true) then active=true
        elseif active then
            local spaces,class,name=line:match('^(%s+)([%w_]+) ([^%s]+)')
            if spaces and #spaces>=8 then
                local o=f.node(class,name,{})
                while #stack>0 and stack[#stack].depth>=#spaces do table.remove(stack) end
                if #stack>0 then
                    local parent=stack[#stack].node
                    parent.edges[#parent.edges+1]=o
                else root=o end
                stack[#stack+1]={depth=#spaces,node=o}
                if class==CELL then expected[#expected+1]=o end
            elseif line:find('...',1,true) and #stack>0 then stack[#stack].node.truncated=true
            else break end
        end
    end
    input:close()
    -- Dump short names repeat between private owners; create unique full names
    -- from their saved occurrence, preserving each reflected short identity.
    local nodes={table.unpack(f.objects)}
    for i,o in ipairs(nodes) do
        o.full=o.kind..' /SavedTopology/Node'..i..'.'..o.short
        if o.kind:sub(-2)=='_C' then
            if o.kind~='BP_PalTextBlock_C' then
                assert(#o.edges<=1,'saved UserWidget has multiple roots')
                f.own(o,o.edges[1])
            end
            o.edges=nil
        end
    end
    local menu=f.own(f.node('UserWidget','menu'),root)
    local cells,meta=tree.stand_cells(menu,CELL,valid)
    assert(#expected==117,'saved dump cell inventory changed')
    assert(not cells and not meta.complete and meta.stage=='GetChildrenCount',
        'truncated saved branches were fabricated as complete')
    for _,o in ipairs(nodes) do
        if o.kind=='CanvasPanel' or o.kind=='SizeBox' or o.kind=='HorizontalBox' or o.kind=='Overlay' then
            assert((o.calls.tree or 0)==0,'known panel received WidgetTree probe')
        end
    end
    print('Saved topology: 117 visible cells; abbreviated owner branches correctly remain unknown')
    scalar_meta(meta)
end)

assert(#failures==0,table.concat(failures,'\n'))
