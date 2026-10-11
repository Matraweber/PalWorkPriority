-- Differential oracle: the unchanged eager walker remains used by generic
-- cells/find. Redirect only the stand call sites to it for the before result.
local input=assert(io.open(TEST_ROOT..'/Scripts/ui_tree.lua','r'))
local source=input:read('*a'); input:close()
local split=assert(source:find('local function stand_roster_cells',1,true))
local before_source=source:sub(1,split-1)..source:sub(split):gsub('stand_walk%(', 'walk(')
local before=assert(load(before_source,'@stand-eager-oracle'))()
local after=require('ui_tree')
local CELL='WBP_WorkSuitabilityPreference_CheckBox_0_C'
local ROW='WBP_WorlSuitabilityPreference_PalList_C'
local failures={}
local function check(name,fn)
    local ok,err=pcall(fn)
    if ok then print('PASS streaming: '..name)
    else failures[#failures+1]=name..': '..tostring(err) end
end
local function valid(o) return o~=nil and o:IsValid()==true end
local function fixture(n,shaped)
    local f={objects={},calls={},rows={},expected={}}
    function f.node(kind,name,edges)
        local o={kind=kind,short=name,full=kind..' '..name,edges=edges,calls={}}
        local function hit(key)
            assert(not o.dead,'previous callback wrapper touched: '..key)
            o.calls[key]=(o.calls[key] or 0)+1
            f.calls[key]=(f.calls[key] or 0)+1
        end
        function o:IsValid() hit('valid'); return not o.invalid end
        function o:GetFullName() hit('name'); assert(not o.bad_name); return o.full end
        function o:GetFName()
            hit('short'); assert(not o.bad_short)
            return {ToString=function() return o.short end}
        end
        function o:GetChildrenCount()
            hit('count'); assert(o.edges and not o.bad_count)
            if o.on_count then o.on_count() end
            return o.count_override or #o.edges
        end
        function o:GetChildAt(i)
            hit('child'); assert(i~=o.bad_child)
            if i==o.nil_child then return nil end
            return o.edges[i+1]
        end
        setmetatable(o,{__index=function(_,key)
            if key=='WidgetTree' then hit('tree'); assert(o.owned and not o.bad_tree); return o.owned
            elseif key=='RootWidget' then hit('root'); assert(not o.bad_root); return o.root end
        end})
        f.objects[#f.objects+1]=o
        return o
    end
    function f.own(o,root)
        o.owned=f.node('WidgetTree',o.short..'.tree'); o.owned.root=root
        return o
    end
    f.scroll=f.node('ScrollBox','scroll',{})
    f.roster=f.own(f.node('WBP_PalCommonScrollList_C','roster'),f.scroll)
    f.roster.short='WBP_PalCommonScrollList_PalList'
    f.owner=f.node('CanvasPanel','owner',{f.roster})
    f.menu=f.own(f.node('UserWidget','menu'),f.owner)
    if shaped then
        for i=1,75 do f.owner.edges[#f.owner.edges+1]=f.node('Image','owner.image'..i) end
        for i=1,7 do f.scroll.edges[#f.scroll.edges+1]=f.node('Image','scroll.image'..i) end
    end
    for r=1,n do
        local prefix='row'..r
        local private=f.node('UnknownWidget_C',prefix..'.private')
        local bar=f.node('HorizontalBox',prefix..'.bar',{})
        bar.short='HorizontalBox_CheckBox'
        local root=f.node('CanvasPanel',prefix..'.root',{private})
        if shaped then
            for i=1,39 do root.edges[#root.edges+1]=f.node('Image',prefix..'.image'..i) end
        end
        root.edges[#root.edges+1]=bar
        local row=f.own(f.node(ROW,prefix),root)
        row.bar,row.root,row.private=bar,root,private
        for c=1,13 do
            local cell=f.node(CELL,prefix..'.cell'..c)
            bar.edges[c]=f.node('SizeBox',prefix..'.slot'..c,{cell})
            f.expected[#f.expected+1]=cell
        end
        f.scroll.edges[#f.scroll.edges+1]=row; f.rows[r]=row
    end
    return f
end
local function run(module,f)
    local cells,meta=module.stand_cells(f.menu,CELL,valid)
    for _,v in pairs(meta) do
        assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean','wrapper in metadata')
    end
    return cells,meta
end
local function differential(build,complete)
    local a,b=build(),build()
    local ac,am=run(before,a); local bc,bm=run(after,b)
    assert(am.complete==complete and bm.complete==complete,'completeness changed')
    if complete then
        assert(ac and bc and #ac==#bc)
        for i,c in ipairs(ac) do assert(c.full==bc[i].full,'target/order changed') end
        for _,key in ipairs({'visits','owner_visits','row_scopes','row_fallbacks','budget_exhausted'}) do
            assert(am[key]==bm[key],'metadata changed: '..key)
        end
    else assert(not ac and not bc,'partial targets escaped') end
    return a,b,am,bm
end

check('nine rows retain 117 ordered cells and 639/77 visits',function()
    local a,b,am,bm=differential(function() return fixture(9,true) end,true)
    assert(am.visits==639 and am.owner_visits==77 and bm.matched_cells==117)
    assert(bm.row_scopes==9 and bm.row_fallbacks==0)
    for _,key in ipairs({'name','short','count','child','tree','root'}) do
        assert(a.calls[key]==b.calls[key],'native reads changed: '..key)
    end
    print(('BEFORE/AFTER 639+77 visits: IsValid %d -> %d; saved %d; other accessors unchanged (not native ms)')
        :format(a.calls.valid,b.calls.valid,a.calls.valid-b.calls.valid))
    assert(a.calls.valid-b.calls.valid>=680,'duplicate validity calls not removed')
end)

check('failures at first middle and last child never yield targets',function()
    for _,position in ipairs({1,7,13}) do
        for _,mode in ipairs({'read','nil','invalid','name','count','tree'}) do
            differential(function()
                local f=fixture(1); local bar=f.rows[1].bar; local slot=bar.edges[position]
                if mode=='read' then bar.bad_child=position-1
                elseif mode=='nil' then bar.nil_child=position-1
                elseif mode=='invalid' then slot.invalid=true
                elseif mode=='name' then slot.bad_name=true
                elseif mode=='count' then slot.bad_count=true
                else bar.edges[position]=f.node('UnknownWidget_C','unreadable') end
                return f
            end,false)
        end
    end
end)

check('duplicate scopes and nested bars still refuse',function()
    for _,mode in ipairs({'roster','roster_identity','sibling','nested','identity','owner'}) do
        differential(function()
            local f=fixture(1); local row=f.rows[1]
            if mode=='roster' or mode=='roster_identity' then
                local other=f.node('WBP_PalCommonScrollList_C','other')
                other.short=f.roster.short; other.bad_short=mode=='roster_identity'
                f.owner.edges[#f.owner.edges+1]=other
            elseif mode=='identity' then row.bar.bad_short=true
            elseif mode=='owner' then f.owner.bad_count=true
            else
                local other=f.node('HorizontalBox','other',{}); other.short=row.bar.short
                local edges=mode=='nested' and row.bar.edges or row.root.edges
                edges[#edges+1]=other
            end
            return f
        end,false)
    end
end)

check('complete-row fallback follows private trees and revalidates cached edges',function()
    for _,module in ipairs({before,after}) do
        local f=fixture(1); local row=f.rows[1]
        row.bar.short='OtherLayout'
        f.own(row.private,f.node('CanvasPanel','private.root',{}))
        local cells,meta=run(module,f)
        assert(cells and #cells==13 and meta.row_fallbacks==1 and row.private.calls.tree==1)
        assert(row.root.calls.count==1 and row.root.calls.child==2,'owner edges read twice')

        f=fixture(1); row=f.rows[1]; row.bar.short='OtherLayout'
        -- Owner traversal reads private first. A later owner edge invalidates
        -- it; fallback must validate it again before using its cached name.
        row.bar.on_count=function() row.private.invalid=true end
        cells,meta=run(module,f)
        assert(not cells and not meta.complete and meta.stage=='IsValid')
        assert(not row.private.calls.tree,'invalid cached wrapper dereferenced')
    end
    differential(function()
        local f=fixture(1); local row=f.rows[1]
        f.own(row.private,f.node('CanvasPanel','private.root',{}))
        row.root.edges[#row.root.edges+1]=f.node(CELL,'outside')
        return f
    end,true)
end)

check('cycles and shared children retain order and bounded visits',function()
    differential(function()
        local f=fixture(1); local row=f.rows[1]
        row.root.edges[#row.root.edges+1]=row.root
        row.bar.edges[#row.bar.edges+1]=row.bar.edges[1]
        row.bar.edges[#row.bar.edges+1]=row.bar
        return f
    end,true)
end)

check('owner and shared roster budgets retain exact boundaries',function()
    for _,scope in ipairs({'owner','roster'}) do
        for _,over in ipairs({0,1}) do
            local limit=scope=='owner' and 512 or 4000
            local _,_,am,bm=differential(function()
                local f=fixture(0)
                local edges=scope=='owner' and f.owner.edges or f.scroll.edges
                for i=1,limit-2+over do edges[#edges+1]=f.node('Image','image'..i) end
                return f
            end,over==0)
            assert(am.budget_exhausted==(over==1) and bm.budget_exhausted==(over==1))
            if over==1 then assert(am.visits==limit and bm.visits==limit) end
        end
    end
    differential(function() return fixture(200) end,false)
    differential(function()
        local f=fixture(1); f.rows[1].bar.count_override=4001; return f
    end,false)
    for _,depth in ipairs({3997,3998}) do
        differential(function()
            local f=fixture(0); local child=f.node(CELL,'deep.cell')
            for i=1,depth do child=f.node('CanvasPanel','deep'..i,{child}) end
            f.scroll.edges={child}; return f
        end,depth==3997) -- roster + scroll + panels + cell = 4000 at the boundary
    end
end)

check('same-name replacement never touches or retains old wrappers',function()
    local weak
    do
        local f=fixture(9); assert(run(after,f))
        weak=setmetatable({table.unpack(f.objects)},{__mode='v'})
        for _,o in ipairs(f.objects) do o.dead=true end
        local replacement=fixture(9); local cells=assert(run(after,replacement))
        for i,c in ipairs(cells) do assert(c==replacement.expected[i]) end
    end
    collectgarbage('collect'); collectgarbage('collect')
    assert(next(weak)==nil,'collector retained wrappers between calls')
end)

assert(#failures==0,table.concat(failures,'\n'))
