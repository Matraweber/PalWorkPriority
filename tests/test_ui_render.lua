local draw=require('ui_render')
local result=draw.collect({1,2,3,4},function(i)
    if i==1 then return 'rendered' end
    if i==2 then return end
    if i==3 then return 'skipped' end
    error('bad widget')
end)
assert(result.rendered==1 and result.skipped==2 and result.failed==1)
local text='old'
local widget={SetText=function(_,v) text=v end,SetColorAndOpacity=function() error('destroyed') end}
assert(draw.write(widget,'new',{})=='failed','failed colour write committed render')
widget.SetColorAndOpacity=function() end
assert(draw.write(widget,'new',{})=='rendered')
-- UE void setters return nil on success; an explicit false is a refusal.
local text_refused=draw.write({SetText=function() return false end,
    SetColorAndOpacity=function() end},'new',{})
local colour_refused=draw.write({SetText=function() end,
    SetColorAndOpacity=function() return false end},'new',{})
assert(text_refused=='failed' and colour_refused=='failed',
    'non-throwing failure committed render: text='..text_refused..', colour='..colour_refused)
local outcomes=draw.collect({'text','colour','void'},function(which)
    return draw.write({SetText=function() if which=='text' then return false end end,
        SetColorAndOpacity=function() if which=='colour' then return false end end},'new',{})
end)
assert(outcomes.failed==2 and outcomes.rendered==1 and outcomes.skipped==0,
    'refused setters counted as painted cells, or nil void success was rejected')
local tree=require('ui_tree')
local stale=setmetatable({}, {__index=function() error('stale wrapper touched') end})
local current={IsValid=function() return true end,GetFullName=function() return 'reused-name' end}
assert(tree.find(current,'reused-name',function(o) return o and o:IsValid() end)==current)
-- The old wrapper is intentionally never passed to the resolver.
assert(stale~=current)

-- Tree contracts use native-shaped objects: leaves have neither a WidgetTree
-- nor GetChildrenCount. These are Lua regressions, not native lifetime proof.
local function node(class,name,children,calls)
    local function count(method)
        if calls then calls[method]=(calls[method] or 0)+1 end
    end
    local o={IsValid=function() return true end,
        GetFullName=function() count('GetFullName'); return class..' '..name end,
        GetClass=function() count('GetClass'); return {GetFName=function()
            count('ClassGetFName'); return {ToString=function()
                count('ClassToString'); return class end} end} end}
    -- UCheckBox is a UContentWidget: even an empty one has a child-count API.
    if children or class=='CheckBox' then
        children=children or {}
        function o:GetChildrenCount() return #children end
        function o:GetChildAt(i) return children[i+1] end
    end
    return o
end
local function valid(o) return o~=nil and o:IsValid() end
local function scalars_only(value)
    for _,v in pairs(value) do
        assert(type(v)=='string' or type(v)=='number' or type(v)=='boolean',
            'tree metadata retained an object or nested state')
    end
end
local leaf_touches=0
local label=setmetatable(node('BP_PalTextBlock_C','native-label'),{__index=function()
    leaf_touches=leaf_touches+1; error('terminal widget queried as a container') end})
local cell=node('StandCell','cell')
local found,meta=tree.cells(node('CanvasPanel','root',{label,cell}),'StandCell',valid)
assert(found and #found==1,'native blueprint text leaf made the cell tree unavailable')
assert(meta.complete and meta.visits==3 and meta.budget==4000 and not meta.budget_exhausted)
assert(meta.stage==nil and leaf_touches==0,'terminal contract did not precede tree/child probes')
scalars_only(meta)

-- CheckBox may be a content widget. The pre-existing leaf classification
-- tolerates a missing child API but must still traverse it when it succeeds.
local content_checkbox=node('CheckBox','with-content',{cell})
local checkbox_cells=tree.cells(content_checkbox,'StandCell',valid)
local checkbox_target,checkbox_complete=tree.find(content_checkbox,'StandCell cell',valid)
assert(checkbox_cells and #checkbox_cells==1 and checkbox_cells[1]==cell,
    'CheckBox content was pruned from cell discovery')
assert(checkbox_target==cell and checkbox_complete,'CheckBox content was pruned from named lookup')

local broken=node('CanvasPanel','broken') -- known container with unreadable child API
local unknown=node('UnverifiedWidget_C','unknown') -- suffix alone cannot establish a leaf
found,meta=tree.cells(node('CanvasPanel','root',{cell,broken,unknown}),'StandCell',valid)
assert(found==nil and not meta.complete and meta.stage=='GetChildrenCount')
assert(meta.class=='CanvasPanel' and meta.name=='CanvasPanel broken',
    'a later refusal replaced the first failed container')
assert(meta.visits==4 and meta.refusal_visit==3 and not meta.budget_exhausted)
scalars_only(meta)
for _,case in ipairs({{'UnverifiedWidget_C','WidgetTree'},
    {'WBP_WorlSuitabilityPreference_PalList_C','WidgetTree'},
    {'PalUIActionWidgetBase','GetChildrenCount'}}) do
    found,meta=tree.cells(node(case[1],'unverified'),'StandCell',valid)
    assert(found==nil and meta.class==case[1] and meta.stage==case[2],
        'missing genuine tree or unverified native class was accepted: '..case[1])
end
local missing_root=node('UserWidget','missing-root')
missing_root.WidgetTree=node('WidgetTree','tree')
found,meta=tree.cells(missing_root,'StandCell',valid)
assert(found==nil and meta.stage=='RootWidget')
local partial=node('CanvasPanel','partial',{cell,cell})
function partial:GetChildAt(i) if i==0 then return cell end end
found,meta=tree.cells(partial,'StandCell',valid)
assert(found==nil and meta.stage=='GetChildAt','unreadable child silently established completeness')

local long_unknown=node(string.rep('A',150)..'_C',string.rep('n',500)..'\nmore')
found,meta=tree.cells(long_unknown,'StandCell',valid)
assert(found==nil and #meta.class<=96 and #meta.name<=256 and not meta.name:find('%c'),
    'refusal metadata was unbounded or allowed multiline names')
scalars_only(meta)

local many={}
for i=1,3999 do many[i]=node('StandCell','cell'..i) end
found,meta=tree.cells(node('CanvasPanel','at-limit',many),'StandCell',valid)
assert(found and #found==3999 and meta.visits==4000 and meta.complete,
    'exactly-budgeted complete tree was refused')
many[4000]=node('StandCell','beyond-limit')
found,meta=tree.cells(node('CanvasPanel','over-limit',many),'StandCell',valid)
assert(found==nil and meta.visits==4000 and meta.budget_exhausted and meta.stage=='budget',
    'walk exceeded the hard visit limit or hid its refusal')
scalars_only(meta)
local too_wide=node('CanvasPanel','too-wide')
function too_wide:GetChildrenCount() return 4001 end
function too_wide:GetChildAt() error('oversized child count must not be traversed') end
found,meta=tree.cells(too_wide,'StandCell',valid)
assert(found==nil and meta.visits==1 and meta.budget_exhausted and meta.stage=='GetChildrenCount')

local empty
empty,meta=tree.cells(node('CanvasPanel','empty',{}),'StandCell',valid)
assert(empty and #empty==0 and meta.complete,'complete absence became a refusal')
-- A named search may succeed after an unrelated refusal. Its two return values
-- retain their old meaning and no old wrapper is needed to find a replacement.
local resolved,complete=tree.find(node('CanvasPanel','root',{unknown,cell}),'StandCell cell',valid)
assert(resolved==cell and complete)
resolved,complete=tree.find(node('CanvasPanel','root',{unknown}),'StandCell missing',valid)
assert(resolved==nil and not complete)

-- Stand ownership scoping: native-shaped menu -> named list -> rows. All
-- objects stay local to this test/call; an unknown internal child still fails.
local function roster()
    local r=node('WBP_PalCommonScrollList_C','roster')
    function r:GetFName() return {ToString=function() return 'WBP_PalCommonScrollList_PalList' end} end
    r.WidgetTree=node('WidgetTree','roster.tree')
    r.WidgetTree.RootWidget=node('ScrollBox','scroll',{cell})
    return r
end
local function menu(content)
    local m=node('WBP_WorkSuitabilityPreferenceMenu_C','menu')
    m.WidgetTree=node('WidgetTree','menu.tree')
    m.WidgetTree.RootWidget=node('CanvasPanel','menu.root',content)
    return m
end
local owned=roster()
found,meta=tree.stand_cells(menu({owned}),'StandCell',valid)
assert(found and #found==1 and meta.scope=='Pal roster' and meta.owner_visits==2)
scalars_only(meta)
-- A missing candidate FName cannot establish unique ownership.
local private_reads=0
local native=setmetatable(node('NativeUserWidget','other-owner',{}),{__index=function(_,k)
    if k=='WidgetTree' then private_reads=private_reads+1; error('private tree read') end
end})
found,meta=tree.stand_cells(menu({native,owned}),'StandCell',valid)
assert(found and #found==1 and private_reads==0,'owner pass read a native private tree')
native.GetChildrenCount=nil
found,meta=tree.stand_cells(menu({native,owned}),'StandCell',valid)
assert(found==nil and meta.stage=='GetChildrenCount' and private_reads==0,
    'unknown native owner contract was accepted or its private tree inspected')
local unreadable=roster()
function unreadable:GetFullName() return 'WBP_PalCommonScrollList_C unreadable-roster' end
function unreadable:GetFName() error('identity unavailable') end
found,meta=tree.stand_cells(menu({owned,unreadable}),'StandCell',valid)
assert(found==nil and meta.stage=='roster identity')
scalars_only(meta)
found,meta=tree.stand_cells(menu({owned,node('CanvasPanel','broken-owner') }),'StandCell',valid)
assert(found==nil and meta.scope=='menu owner' and meta.stage=='GetChildrenCount',
    'positive scope match accepted an incomplete owner search')
-- Two distinct widgets with the same short name are ambiguous.
local second=roster()
function second:GetFullName() return 'WBP_PalCommonScrollList_C other-roster' end
found,meta=tree.stand_cells(menu({owned,second}),'StandCell',valid)
assert(found==nil and meta.stage=='roster ambiguous')
local wide={owned}
for i=1,512 do wide[#wide+1]=node('Image','decoration'..i) end
found,meta=tree.stand_cells(menu(wide),'StandCell',valid)
assert(found==nil and meta.budget_exhausted and meta.visits<=512,
    'owner search ignored its independent hard budget')
scalars_only(meta)

-- Count real accessor invocations in these Lua fixtures, not elapsed time.
-- Run each regression independently so the before-change failures are visible.
local failures={}
local function check(name,fn)
    local ok,err=pcall(fn)
    if ok then print('PASS tree fullname: '..name)
    else failures[#failures+1]=name..': '..tostring(err) end
end
local function no_class_calls(calls)
    assert((calls.GetClass or 0)==0 and (calls.ClassGetFName or 0)==0
        and (calls.ClassToString or 0)==0,
        ('redundant class calls: GetClass=%d, class GetFName=%d, class ToString=%d')
        :format(calls.GetClass or 0,calls.ClassGetFName or 0,calls.ClassToString or 0))
end

check('complete stand accessor counts',function()
    -- Synthetic topology with the recorded 77 owner / 909 roster visits and
    -- 117 cells. This matches visit totals, not the native tree or its timing.
    local calls,rows,expected={},{},{}
    for i=1,790 do
        local classes={'Image','BP_PalTextBlock_C','CheckBox'}
        rows[#rows+1]=node(classes[(i-1)%#classes+1],'decoration'..i,nil,calls)
    end
    for i=1,117 do
        expected[i]=node('StandCell','cell'..i,nil,calls)
        rows[#rows+1]=expected[i]
    end
    local list=node('WBP_PalCommonScrollList_C','roster',nil,calls)
    function list:GetFName()
        calls.RosterGetFName=(calls.RosterGetFName or 0)+1
        return {ToString=function()
            calls.RosterToString=(calls.RosterToString or 0)+1
            return 'WBP_PalCommonScrollList_PalList'
        end}
    end
    list.WidgetTree=node('WidgetTree','roster.tree')
    list.WidgetTree.RootWidget=node('ScrollBox','scroll',rows,calls)
    local owner={list}
    for i=1,75 do owner[#owner+1]=node('Image','owner'..i,nil,calls) end
    local m=menu(owner)
    m.WidgetTree.RootWidget=node('CanvasPanel','menu.root',owner,calls)
    local cells,info=tree.stand_cells(m,'StandCell',valid)
    assert(cells and #cells==117 and info.complete and info.owner_visits==77 and info.visits==909)
    for i,expected_cell in ipairs(expected) do assert(cells[i]==expected_cell,'cell order changed') end
    assert(calls.GetFullName==986,'walk omitted or repeated full-name reads')
    assert(calls.RosterGetFName==1 and calls.RosterToString==1,'roster identity was not verified once')
    no_class_calls(calls)
    scalars_only(info)
end)

check('standard full names need no reflected class',function()
    for _,class in ipairs({'TextBlock','BP_PalTextBlock_C','CheckBox'}) do
        local calls={}
        local o=node(class,'/Engine/Transient.Game:WidgetTree.Label_12',nil,calls)
        function o:GetClass() calls.GetClass=(calls.GetClass or 0)+1; error('reflection unavailable') end
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(cells and #cells==0 and info.complete,'full-name leaf unavailable: '..class)
        local target,done=tree.find(o,'StandCell missing',valid)
        assert(target==nil and done,'full-name leaf made absence unknown: '..class)
        assert(calls.GetFullName==2,'full name was cached between calls')
        no_class_calls(calls)
    end
end)

check('unfamiliar full names retain reflected fallback',function()
    for _,name in ipairs({'legacy-name','','TextBlock','TextBlock ',
        ' TextBlock path','TextBlock  path','TextBlock\tpath','TextBlock path with spaces',
        'TextBlock path\nmore','TextBlock\1 path','TextBlock \0path',
        '/Script/UMG.TextBlock path','1TextBlock path'}) do
        local calls={}
        local o=node('CanvasPanel','fallback',{cell},calls)
        function o:GetFullName() return name end
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(cells and #cells==1 and cells[1]==cell and info.complete,'fallback lost panel content')
        assert(calls.GetClass==1 and calls.ClassGetFName==1 and calls.ClassToString==1,
            'unfamiliar name skipped reflected fallback: '..string.format('%q',name))
    end
    for _,case in ipairs({{'TextBlock',nil},{'BP_PalTextBlock_C',nil},
        {'CanvasPanel','GetChildrenCount'},{'UnknownNative','GetChildrenCount'},
        {'UnverifiedWidget_C','WidgetTree'}}) do
        local o=node(case[1],'fallback')
        function o:GetFullName() return 'TextBlock ' end -- not a verified leaf prefix
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(info.complete==(case[2]==nil) and info.stage==case[2],'fallback changed class contract')
        if case[2] then
            assert(cells==nil and info.class==case[1],'malformed name hid a failed or unknown container')
        else assert(cells and #cells==0) end
    end
end)

check('failed reflected fallback cannot prove absence',function()
    for _,failure in ipairs({'GetClass','GetFName','ToString','non-string'}) do
        local o=node('TextBlock','fallback')
        function o:GetFullName() return 'TextBlock ' end
        function o:GetClass()
            if failure=='GetClass' then error('class unavailable') end
            return {GetFName=function()
                if failure=='GetFName' then error('class name unavailable') end
                return {ToString=function()
                    if failure=='ToString' then error('class string unavailable') end
                    return false
                end}
            end}
        end
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(cells==nil and not info.complete and info.stage=='GetChildrenCount' and info.class=='?',
            'unreadable reflected class established absence: '..failure)
        local target,done=tree.find(o,'StandCell missing',valid)
        assert(target==nil and not done,'failed fallback allowed replacement injection')
        scalars_only(info)
    end
end)

check('unreadable full name refuses before class or child queries',function()
    for _,failure in ipairs({'throw','nil','number','boolean'}) do
        local touches=0
        local o=node('TextBlock','unreadable')
        function o:GetFullName()
            if failure=='throw' then error('full name unavailable') end
            if failure=='number' then return 42 end
            if failure=='boolean' then return false end
        end
        function o:GetClass() touches=touches+1; error('unexpected class query') end
        function o:GetChildrenCount() touches=touches+1; error('unexpected child query') end
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(cells==nil and not info.complete and info.stage=='GetFullName' and info.visits==1)
        assert(touches==0,'unreadable full name fell through to reflection or children')
    end
end)

check('unknown standard classes remain incomplete',function()
    for _,case in ipairs({{'UnverifiedWidget_C','WidgetTree'},
        {'UnknownNative','GetChildrenCount'},{'CanvasPanel','GetChildrenCount'}}) do
        local calls={}
        local o=node(case[1],'unreadable',nil,calls)
        local cells,info=tree.cells(o,'StandCell',valid)
        assert(cells==nil and not info.complete and info.class==case[1] and info.stage==case[2])
        no_class_calls(calls)
    end
end)

check('cycles and named lookup preserve current-call reads',function()
    local calls,edges={},{}
    local root=node('CanvasPanel','cycle',edges,calls)
    local label=node('TextBlock','label',nil,calls)
    edges[1],edges[2],edges[3]=root,label,cell
    local target,done=tree.find(root,'StandCell cell',valid)
    assert(target==cell and done and calls.GetFullName==3,'cycle or lookup order changed')
    local cells,info=tree.cells(root,'StandCell',valid)
    assert(cells and #cells==1 and info.visits==4 and calls.GetFullName==6,
        'a later traversal reused its seen-set or full names')
    no_class_calls(calls)
end)

check('replacement wrappers and names are fresh on the next call',function()
    local calls={}
    local old_cell=node('StandCell','reused-cell',nil,calls)
    local old_root=node('CanvasPanel','reused-root',{old_cell},calls)
    local first=tree.cells(old_root,'StandCell',valid)
    assert(first and first[1]==old_cell)
    local function retired() error('previous-call wrapper touched') end
    for _,o in ipairs({old_cell,old_root}) do
        o.IsValid,o.GetFullName,o.GetClass,o.GetChildrenCount=retired,retired,retired,retired
    end
    local fresh_cell=node('StandCell','reused-cell',nil,calls)
    local fresh_root=node('CanvasPanel','reused-root',{fresh_cell},calls)
    local second=tree.cells(fresh_root,'StandCell',valid)
    assert(second and second[1]==fresh_cell and calls.GetFullName==4,'old named wrapper was retained')
    local rebound=node('UnknownNative','rebound',nil,calls)
    fresh_cell.GetFullName,fresh_cell.GetClass=rebound.GetFullName,rebound.GetClass
    local third,info=tree.cells(fresh_root,'StandCell',valid)
    assert(third==nil and info.stage=='GetChildrenCount' and info.class=='UnknownNative' and calls.GetFullName==6,
        'same wrapper reused an earlier full name or class')
    no_class_calls(calls)
end)

check('native terminal contracts avoid unsupported child probes',function()
    local probes=0
    local primitives={}
    for _,class in ipairs({'Image','Spacer','TextBlock'}) do
        primitives[#primitives+1]=setmetatable(node(class,class..'.leaf'),{__index=function(_,key)
            if key=='WidgetTree' or key=='GetChildrenCount' then
                probes=probes+1; error('unsupported native child probe')
            end
        end})
    end
    primitives[#primitives+1]=cell
    local root=node('CanvasPanel','terminal-root',primitives)
    local cells,info=tree.cells(root,'StandCell',valid)
    assert(cells and #cells==1 and cells[1]==cell and info.complete and info.visits==5)
    for i,class in ipairs({'Image','Spacer','TextBlock'}) do
        local target,done=tree.find(root,class..' '..class..'.leaf',valid)
        assert(target==primitives[i] and done,'terminal label was not available to named lookup')
    end
    assert(probes==0,'native leaf caused '..probes..' unsupported child probes')
    local unknown,reason=tree.cells(node('Image_C','unverified-subclass'),'StandCell',valid)
    assert(unknown==nil and reason.stage=='WidgetTree','terminal contract generalized to a subclass')
end)

check('checkbox child-count failure cannot establish absence',function()
    local checkbox=node('CheckBox','unavailable-content',{})
    function checkbox:GetChildrenCount() error('content temporarily unavailable') end
    local cells,info=tree.cells(checkbox,'StandCell',valid)
    assert(cells==nil and not info.complete and info.stage=='GetChildrenCount',
        'failed checkbox content read was treated as a complete empty branch')
    local target,complete=tree.find(checkbox,'StandCell missing',valid)
    assert(target==nil and not complete,'failed checkbox content permitted duplicate injection')
end)

assert(#failures==0,table.concat(failures,'\n'))
