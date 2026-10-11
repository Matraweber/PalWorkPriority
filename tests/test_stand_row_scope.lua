-- Native September 13 topology: row-owned HorizontalBox_CheckBox contains the
-- priority cells. Private sanity/task widgets are outside that editing scope.
local tree=require('ui_tree')
local CELL='WBP_WorkSuitabilityPreference_CheckBox_0_C'
local ROW='WBP_WorlSuitabilityPreference_PalList_C'
local failures={}
local function check(name,fn)
    local ok,err=pcall(fn)
    if ok then print('PASS row scope: '..name) else failures[#failures+1]=name..': '..tostring(err) end
end
local function valid(o) return o and o:IsValid()==true end
local function fixture(n)
    local f={objects={},rows={},cells={},private_reads=0}
    function f.node(class,name,children)
        local o={children=children or {},short=name,kind=class}
        local function fresh() assert(not o.dead,'stored wrapper dereferenced') end
        function o:IsValid() fresh(); return true end
        function o:GetFullName() fresh(); return class..' '..name end
        function o:GetFName() fresh(); return {ToString=function() return o.short end} end
        function o:GetChildrenCount() fresh(); assert(not o.bad_children,'missing children'); return #o.children end
        function o:GetChildAt(i) fresh(); return o.children[i+1] end
        f.objects[#f.objects+1]=o
        return o
    end
    local function owned(o,root)
        o.WidgetTree=f.node('WidgetTree',o.short..'.tree'); o.WidgetTree.RootWidget=root
        return o
    end
    f.menu=f.node('WBP_WorkSuitabilityPreferenceMenu_C','menu')
    local roster=f.node('WBP_PalCommonScrollList_C','roster')
    roster.short='WBP_PalCommonScrollList_PalList'
    f.scroll=f.node('ScrollBox','scroll')
    owned(roster,f.scroll); owned(f.menu,f.node('CanvasPanel','menu.root',{roster}))
    for r=1,n do
        local row=f.node(ROW,'row'..r)
        local private=f.node('WBP_EnemyGauge_SAN_C','row'..r..'.san')
        setmetatable(private,{__index=function(_,k)
            if k=='WidgetTree' then f.private_reads=f.private_reads+1; error('unrelated private tree touched') end
        end})
        local box=f.node('HorizontalBox','row'..r..'.box'); box.short='HorizontalBox_CheckBox'
        for c=1,13 do
            local cell=f.node(CELL,'row'..r..'.cell'..c)
            box.children[#box.children+1]=f.node('SizeBox','row'..r..'.slot'..c,{cell})
            f.cells[#f.cells+1]=cell
        end
        local root=f.node('CanvasPanel','row'..r..'.root',{private,box})
        owned(row,root); row.box,row.root,row.private=box,root,private
        f.rows[#f.rows+1]=row; f.scroll.children[#f.scroll.children+1]=row
    end
    return f
end
check('nine rows preserve 117 ordered cells without private traversal',function()
    local f=fixture(9)
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(cells and #cells==117,'scoped roster unavailable')
    for i,c in ipairs(cells) do assert(c==f.cells[i],'row/cell order changed') end
    assert(f.private_reads==0,'unrelated private widget was searched')
    assert(meta.row_scopes==9 and meta.row_fallbacks==0,'row route not used')
    assert(meta.visits<350,'scoped roster exceeded fixture visit bound')
    for _,v in pairs(meta) do assert(type(v)~='table' and type(v)~='userdata','metadata kept wrappers') end
end)
check('duplicate or unreadable checkbox bar refuses the whole roster',function()
    for _,mode in ipairs({'duplicate','identity','owner_children','inner_children'}) do
        local f=fixture(1); local row=f.rows[1]
        if mode=='duplicate' then
            local other=f.node('HorizontalBox','other'); other.short='HorizontalBox_CheckBox'
            row.root.children[#row.root.children+1]=other
        elseif mode=='identity' then function row.box:GetFName() error('unreadable') end
        elseif mode=='owner_children' then row.root.bad_children=true
        else row.box.bad_children=true end
        local cells,meta=tree.stand_cells(f.menu,CELL,valid)
        assert(cells==nil and not meta.complete,'incomplete row accepted: '..mode)
    end
end)
check('scoped and full searches agree on a readable native-shaped fixture',function()
    local f=fixture(9)
    for r,row in ipairs(f.rows) do
        local decorations={}
        for i=1,60 do decorations[i]=f.node('Image','san'..r..'.image'..i) end
        row.private.WidgetTree=f.node('WidgetTree','san'..r..'.tree')
        row.private.WidgetTree.RootWidget=f.node('CanvasPanel','san'..r..'.root',decorations)
    end
    local full,old_meta=tree.cells(f.scroll,CELL,valid)
    local scoped,new_meta=tree.stand_cells(f.menu,CELL,valid)
    assert(full and scoped and #full==#scoped)
    for i,cell in ipairs(full) do assert(scoped[i]==cell,'scope changed the discovered targets') end
    assert(new_meta.visits<old_meta.visits/2,'scope did not reduce fixture visits')
    print(('Fixture traversal visits: full=%d scoped=%d (not native milliseconds)'):format(old_meta.visits,new_meta.visits))
end)
check('private widgets inside the checkbox bar remain subject to completeness',function()
    local f=fixture(1)
    f.rows[1].box.children[#f.rows[1].box.children+1]=f.node('UnknownWidget_C','inside')
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(not cells and not meta.complete and meta.stage=='WidgetTree','unknown inner branch ignored')
end)
check('a nested duplicate checkbox bar cannot supply editable targets',function()
    local f=fixture(1); local row=f.rows[1]
    local nested=f.node('HorizontalBox','nested',{f.node(CELL,'nested.cell')})
    nested.short='HorizontalBox_CheckBox'
    row.box.children[#row.box.children+1]=nested
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(not cells and not meta.complete and meta.stage=='checkbox bar ambiguous',
        'nested duplicate supplied editable targets')
end)
check('missing named bar falls back to the complete row tree',function()
    local f=fixture(1); local row=f.rows[1]
    row.root.children={row.box}; row.box.short='DifferentLayout'
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(cells and #cells==13 and meta.complete,'old complete layout lost')
    assert(meta.row_fallbacks==1,'missing bar did not use fallback')
end)
check('cells outside the named bar force complete-row fallback',function()
    local f=fixture(1); local row=f.rows[1]
    local extra=f.node(CELL,'outside')
    row.root.children={row.box,extra}
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(cells and #cells==14 and cells[14]==extra,'out-of-shape cell silently dropped')
    assert(meta.row_fallbacks==1)
end)
check('fallback cannot bypass nested duplicate or unreadable bar identity',function()
    for _,mode in ipairs({'duplicate','identity'}) do
        local f=fixture(1); local row=f.rows[1]
        row.root.children={row.box,f.node(CELL,'outside')}
        local nested=f.node('HorizontalBox','nested',{f.node(CELL,'nested.cell')})
        nested.short='HorizontalBox_CheckBox'
        if mode=='identity' then function nested:GetFName() error('unreadable nested bar') end end
        row.box.children[#row.box.children+1]=nested
        local cells,meta=tree.stand_cells(f.menu,CELL,valid)
        assert(not cells and not meta.complete,'fallback accepted invalid nested bar: '..mode)
    end
end)
check('replacement names never reuse previous wrappers',function()
    local old=fixture(1)
    assert(tree.stand_cells(old.menu,CELL,valid))
    for _,o in ipairs(old.objects) do o.dead=true end
    local new=fixture(1)
    local cells=tree.stand_cells(new.menu,CELL,valid)
    assert(cells and #cells==13 and cells[1]==new.cells[1])
end)
check('all nested row searches share the roster budget',function()
    local f=fixture(200)
    local cells,meta=tree.stand_cells(f.menu,CELL,valid)
    assert(not cells and meta.budget_exhausted and meta.visits<=4000,'nested row walks escaped budget')
end)
check('completed traversal returns aligned scalar names without retaining targets',function()
    local f=fixture(2)
    local cells,meta,names=tree.stand_cells(f.menu,CELL,valid)
    assert(meta.complete and names and #names==#cells)
    for i,cell in ipairs(cells) do
        assert(type(names[i])=='string' and names[i]==cell:GetFullName())
    end
    for _,o in ipairs(f.objects) do o.dead=true end
    local replacement=fixture(2)
    local fresh,complete,new_names=tree.stand_cells(replacement.menu,CELL,valid)
    assert(complete.complete and fresh[1]~=cells[1] and new_names~=names)
    replacement.rows[1].root.bad_children=true
    local partial,failed,partial_names=tree.stand_cells(replacement.menu,CELL,valid)
    assert(not partial and not failed.complete and not partial_names,'incomplete names escaped')
end)
check('optional phase profiler completes timed samples without changing targets',function()
    local f=fixture(2)
    local log=require('log')
    log.set_perf(true)
    local cells,meta=tree.stand_cells(f.menu,CELL,valid,log)
    assert(meta.complete and #cells==26)
    for label,count in pairs({['menu ownership']=1,['row ownership']=2,
        ['checkbox contents']=2,['roster including rows']=1}) do
        local mark=log.marks['stand tree: '..label]
        assert(mark and mark.timed_n==count,'phase has no completed timings: '..label)
    end
    log.set_perf(false)
end)
assert(#failures==0,table.concat(failures,'\n'))
