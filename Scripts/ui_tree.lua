-- Current-call tree traversal. This module retains no engine objects between calls.
-- Missing and incompletely searched are different answers. Only a complete
-- absence permits injection of a replacement control.
local M = {}
local containers = {CanvasPanel=true, Overlay=true, VerticalBox=true, HorizontalBox=true,
    GridPanel=true, UniformGridPanel=true, WrapBox=true, ScrollBox=true, WidgetSwitcher=true,
    SizeBox=true, ScaleBox=true, Border=true, Button=true, SafeZone=true, RetainerBox=true,
    NamedSlot=true, PanelWidget=true, ContentWidget=true, CheckBox=true}
local leaves = {TextBlock=true, RichTextBlock=true, Image=true, Spacer=true,
    EditableText=true, EditableTextBox=true, MultiLineEditableText=true,
    MultiLineEditableTextBox=true, ProgressBar=true, Slider=true, SpinBox=true,
    Throbber=true, CircularThrobber=true}
-- Exact native classes with documented no-child contracts. Do not generalize
-- this to subclasses or CheckBox (a content widget). See the September retest.
local native_terminals = {Image=true, Spacer=true, TextBlock=true}

local function bounded(value, limit)
    if type(value)~='string' then return '?' end
    return value:sub(1,limit):gsub('%c','?')
end

-- Only plain, bounded scalar data escapes the current traversal. Record the
-- first refusal using values already read; diagnostics never re-query a widget.
local function refuse(meta, stage, class, name)
    meta.complete=false
    if meta.stage then return end
    meta.stage=stage
    meta.class=bounded(class,96)
    meta.name=bounded(name,256)
    meta.refusal_visit=meta.visits
end

-- These caches exist only inside a row search. Replaying owner edges during
-- fallback must not repeat native reads, but must still visit private trees
-- omitted by the owner pass. Never return this cache or store it in metadata.
local function read_name(widget, cache)
    local entry=cache and cache[widget]
    if entry then return true,entry.name end
    local ok,name=pcall(function() return widget:GetFullName() end)
    if cache and ok and type(name)=='string' then cache[widget]={name=name} end
    return ok,name
end

local function read_short(widget, cache)
    local entry=cache and cache[widget]
    if entry and entry.short then return true,entry.short end
    local ok,name=pcall(function() return widget:GetFName():ToString() end)
    if entry and ok and type(name)=='string' then entry.short=name end
    return ok,name
end

local function children(widget, valid, meta, name, follow_trees, cache, capture, streaming)
    local result = {}
    local edges=capture and {} or nil
    -- This visit already read GetFullName for the seen-set. Standard UE full
    -- names carry the class token; unfamiliar formatting keeps reflection as
    -- a fallback. Neither the name nor a class wrapper is cached across calls.
    local class=name:match('^([%a_][%w_]*) [^%s%c]+$')
    if not class then
        pcall(function() class=widget:GetClass():GetFName():ToString() end)
    end
    -- September's native stand contains BP_PalTextBlock_C without a child
    -- tree or panel API. Its explicit terminal contract precedes the suffix
    -- heuristic. Unknown _C/native classes (including PalUIActionWidgetBase)
    -- retain the conservative traversal rules until their contract is known.
    if class=='BP_PalTextBlock_C' or native_terminals[class] then return result end
    local user_widget=type(class)=='string' and (class=='UserWidget' or class:sub(-2)=='_C')
    -- Exact UPanelWidget/UContentWidget classes have panel children, never a
    -- UUserWidget WidgetTree. Subclasses are deliberately not inferred here.
    if follow_trees~=false and not containers[class] then
        local tree
        local tree_ok=pcall(function() tree=widget.WidgetTree end)
        if tree_ok and valid(tree) then
            local root
            local ok=pcall(function() root=tree.RootWidget end)
            if ok and valid(root) then
                result[#result+1]=root
                if edges then edges[#result]='tree' end
            else refuse(meta,'RootWidget',class,name) end
        elseif user_widget then
            refuse(meta,'WidgetTree',class,name)
        end
    end
    -- UUserWidget itself is not a UPanelWidget. A blueprint suffix alone is
    -- insufficient evidence for this shortcut (BP_PalTextBlock_C is one
    -- counterexample); unknown generated/native classes keep both probes.
    if class=='UserWidget' then return result,edges end
    local entry=cache and cache[widget]
    if containers[class] and entry and entry.panel then return entry.panel end
    local ok, count=pcall(function() return widget:GetChildrenCount() end)
    if ok and type(count)=='number' and count>=0 and count%1==0 and count<=meta.budget then
        if streaming then
            -- Only the stand walker consumes this frame. Each panel edge is
            -- fetched and validated immediately before visiting its child.
            -- Already-read tree roots and cached panel edges still go through
            -- the ordinary queued-node validation on every pass.
            return result,edges,{widget=widget,count=count,index=0,class=class,
                name=name,panel={},entry=containers[class] and entry or nil}
        end
        for i=0,count-1 do
            local got, child=pcall(function() return widget:GetChildAt(i) end)
            if got and valid(child) then
                result[#result+1]=child
                if edges then edges[#result]=i end
            else refuse(meta,'GetChildAt',class,name) end
        end
    elseif ok or containers[class] or not (leaves[class] or user_widget) then
        if ok and type(count)=='number' and count>meta.budget then meta.budget_exhausted=true end
        refuse(meta,'GetChildrenCount',class,name)
    end
    -- Native leaves lack GetChildrenCount. Failure on a known container,
    -- unlike a leaf, cannot establish absence of a child.
    if containers[class] and entry and meta.complete then entry.panel=result end
    return result,edges
end

local function walk(root, valid, visit, budget, follow_trees, shared, cache, root_name, capture)
    local meta=shared or {complete=true,visits=0,budget=budget,budget_exhausted=false}
    if not valid(root) then refuse(meta,'IsValid'); return meta end
    local stack, seen={root},{}
    local paths=capture and {} or nil
    while #stack>0 do
        if meta.visits>=budget then
            meta.budget_exhausted=true
            -- The next node has not been read. Do not dereference it just to
            -- name a refusal, or replace an earlier branch's refusal reason.
            refuse(meta,'budget')
            return meta
        end
        local path=paths and paths[#stack]
        if paths then paths[#stack]=nil end
        local widget=table.remove(stack)
        meta.visits=meta.visits+1
        if valid(widget) then
            local ok, name
            if root_name and widget==root then ok,name=true,root_name; root_name=nil
            else ok,name=read_name(widget,cache) end
            if not ok or type(name)~='string' then refuse(meta,'GetFullName')
            elseif not seen[name] then
                seen[name]=true
                local leaf,stop=visit(widget,name)
                if stop then meta.complete=true; return meta,path end
                if not leaf then
                    local next_widgets,edges=children(widget,valid,meta,name,follow_trees,cache,capture)
                    -- LIFO stack: reverse pushes to preserve native row order.
                    for i=#next_widgets,1,-1 do
                        stack[#stack+1]=next_widgets[i]
                        if paths then paths[#stack]={parent=path,step=edges[i]} end
                    end
                end
            end
        else refuse(meta,'IsValid') end
    end
    return meta
end

-- Stand-only iterative DFS. No early-success path: every searched scope must
-- finish before the caller may expose targets. Pending frames keep ownership
-- edges lazy, so a fresh panel child needs only one validity check, immediately
-- before its name/visitor reads. Frames, seen sets and caches never escape the
-- synchronous collector call. Generic find/cells and path hints use walk above.
local function stand_walk(root,valid,visit,budget,follow_trees,shared,cache)
    local meta=shared or {complete=true,visits=0,budget=budget,budget_exhausted=false}
    if not valid(root) then refuse(meta,'IsValid'); return meta end
    local stack,seen={{node=root}},{}
    while #stack>0 do
        local frame=stack[#stack]
        if frame.count and frame.index>=frame.count then
            -- Publish only a completely enumerated panel. Fallback gets a
            -- separate seen set and revalidates every cached child on dequeue.
            if frame.entry and meta.complete then frame.entry.panel=frame.panel end
            stack[#stack]=nil
        else
            if meta.visits>=budget then
                meta.budget_exhausted=true; refuse(meta,'budget'); return meta
            end
            local widget,live
            if frame.count then
                local got,child=pcall(function() return frame.widget:GetChildAt(frame.index) end)
                frame.index=frame.index+1
                if got and valid(child) then
                    widget,live=child,true
                    frame.panel[#frame.panel+1]=child
                    meta.visits=meta.visits+1
                else refuse(meta,'GetChildAt',frame.class,frame.name) end
            else
                widget=frame.node; stack[#stack]=nil
                meta.visits=meta.visits+1
                live=valid(widget)
                if not live then refuse(meta,'IsValid') end
            end
            if live then
                local ok,name=read_name(widget,cache)
                if not ok or type(name)~='string' then refuse(meta,'GetFullName')
                elseif not seen[name] then
                    seen[name]=true
                    if not visit(widget,name) then
                        local queued,_,pending=children(widget,valid,meta,name,follow_trees,cache,nil,true)
                        if pending then stack[#stack+1]=pending end
                        -- Tree-root edges precede panel edges, as in walk.
                        -- Cached panel arrays also take this revalidation path.
                        for i=#queued,1,-1 do stack[#stack+1]={node=queued[i]} end
                    end
                end
            end
        end
    end
    return meta
end

-- Hints are bounded plain data owned by the caller, never object caches.
-- Re-read every ownership edge from the current root. A positive target has
-- find's existing early-stop semantics; any replay failure triggers a complete
-- bounded search, never permission to inject or evidence of a previous write.
local function hint_steps(hint,root_name,target)
    if type(hint)~='table' or getmetatable(hint)~=nil or hint.root~=root_name
        or hint.target~=target or type(hint.steps)~='table'
        or getmetatable(hint.steps)~=nil then return end
    local steps,count={},0
    for k,v in pairs(hint.steps) do
        if type(k)~='number' or k%1~=0 or k<1 or k>255 then return end
        if v~='tree' and (type(v)~='number' or v%1~=0 or v<0 or v>255) then return end
        steps[k]=v; count=count+1
    end
    if count~=#steps then return end
    for i=1,count do if steps[i]==nil then return end end
    return steps
end

local function replay(root,target,valid,steps)
    local current=root
    for _,step in ipairs(steps) do
        local ok,child=pcall(function()
            if step=='tree' then
                local owned=current.WidgetTree
                if valid(owned) then return owned.RootWidget end
            else
                local count=current:GetChildrenCount()
                if type(count)=='number' and count%1==0 and count>step and count<=256 then
                    return current:GetChildAt(step)
                end
            end
        end)
        if not ok or not valid(child) then return end
        current=child
    end
    local ok,name=pcall(function() return current:GetFullName() end)
    if ok and name==target then return current end
end

-- Existing two returns are unchanged; optional fourth argument / third return
-- exchange {root=full_name,target=full_name,steps={'tree',zero_based_index,...}}.
-- Only this bounded plain hint may survive the callback, never the widget.
-- A failed lookup returns no hint. Root and target names are capped at 2048
-- bytes each and paths at 255 edges. Replay and fallback are separately bounded
-- by 256 visits; a failed replay can add work before the ordinary full search.
function M.find(root,target,valid,hint)
    if type(target)~='string' then return nil,true end
    if not valid(root) then return nil,false end
    local ok,root_name=read_name(root)
    if not ok or type(root_name)~='string' then return nil,false end
    local bounded_names=#root_name<=2048 and #target<=2048
    local steps=bounded_names and hint_steps(hint,root_name,target)
    if steps then
        local current=replay(root,target,valid,steps)
        if current then return current,true,{root=root_name,target=target,steps=steps} end
    end
    local found
    local meta,path=walk(root,valid,function(widget,name)
        if name==target then found=widget; return true,true end
    end,256,true,nil,nil,root_name,bounded_names)
    local new_hint
    if found and bounded_names then
        steps={}
        while path do table.insert(steps,1,path.step); path=path.parent end
        new_hint={root=root_name,target=target,steps=steps}
    end
    return found,meta.complete,new_hint
end

function M.cells(menu,class,valid)
    local found,prefix={},class..' '
    local meta=walk(menu,valid,function(widget,name)
        if name:sub(1,#prefix)==prefix then
            found[#found+1]=widget
            return true -- cell internals cannot contain another stand cell
        end
    end,4000)
    meta.matched_cells=#found
    -- The first return value retains its old contract: incomplete trees never
    -- supply editable targets, even when some cells were discovered.
    if not meta.complete then return nil,meta end
    return found,meta
end

-- September 13's native rows place their editable cells in the row-owned
-- HorizontalBox_CheckBox. Sanity/task UserWidgets own separate private trees;
-- those are not part of the priority editor. Prove the named bar is unique
-- through current owner edges, then search every child within that bar. No
-- instance, path or successful result survives this call.
local function stand_roster_cells(roster,class,valid,measure)
    local meta={complete=true,visits=0,budget=4000,budget_exhausted=false,
        row_scopes=0,row_fallbacks=0}
    local found,seen,names={},{},{}
    local prefix=class..' '
    local function collect(widget,name)
        if name:sub(1,#prefix)==prefix then
            if not seen[name] then
                found[#found+1]=widget; names[#found]=name; seen[name]=true
            end
            return true
        end
    end
    local function row_cells(row)
        local cache={}
        local ok,root=pcall(function()
            local owned=row.WidgetTree
            if valid(owned) then return owned.RootWidget end
        end)
        if not ok or not valid(root) then refuse(meta,'RootWidget'); return end
        local boxes,outside={},false
        local owner_token=measure and measure.begin('stand tree: row ownership')
        stand_walk(root,valid,function(widget,name)
            local kind=name:match('^([^ ]+) ')
            if kind=='HorizontalBox' then
                local read,short=read_short(widget,cache)
                if not read or type(short)~='string' then
                    refuse(meta,'checkbox bar identity',kind,name)
                elseif short=='HorizontalBox_CheckBox' then
                    boxes[#boxes+1]=widget
                    return true -- contents verify nested duplicates below
                end
            end
            if name:sub(1,#prefix)==prefix then outside=true end
            return kind=='UserWidget' or (kind and kind:sub(-2)=='_C')
        end,4000,false,meta,cache)
        if owner_token then measure.finish(owner_token) end
        if not meta.complete then return end
        if #boxes>1 then refuse(meta,'checkbox bar ambiguous','HorizontalBox','HorizontalBox_CheckBox'); return end
        local bars=0
        local function collect_checked(widget,name)
            if name:match('^([^ ]+) ')=='HorizontalBox' then
                local read,short=read_short(widget,cache)
                if not read or type(short)~='string' then
                    refuse(meta,'checkbox bar identity','HorizontalBox',name)
                elseif short=='HorizontalBox_CheckBox' then
                    bars=bars+1
                    if bars>1 then refuse(meta,'checkbox bar ambiguous','HorizontalBox',name) end
                end
            end
            return collect(widget,name)
        end
        if #boxes==1 and not outside then
            meta.row_scopes=meta.row_scopes+1
            local token=measure and measure.begin('stand tree: checkbox contents')
            stand_walk(boxes[1],valid,collect_checked,4000,true,meta,cache)
            if token then measure.finish(token) end
        else
            -- A different complete layout retains the old full-row behavior.
            -- Missing/read failures never establish permission to inject.
            meta.row_fallbacks=meta.row_fallbacks+1
            local token=measure and measure.begin('stand tree: full row fallback')
            stand_walk(root,valid,collect_checked,4000,true,meta,cache)
            if token then measure.finish(token) end
        end
    end
    local roster_token=measure and measure.begin('stand tree: roster including rows')
    stand_walk(roster,valid,function(widget,name)
        if collect(widget,name) then return true end
        if name:match('^([^ ]+) ')=='WBP_WorlSuitabilityPreference_PalList_C' then
            if meta.complete then row_cells(widget) end
            return true
        end
    end,4000,true,meta)
    if roster_token then measure.finish(roster_token) end
    meta.matched_cells=#found
    if not meta.complete then return nil,meta end
    return found,meta,names
end

-- Native contract captured 2026-09-12: this named roster belongs to the
-- Monitoring Stand's own WidgetTree. Discover it without entering other
-- UserWidget trees (header prompts, detail panes or nested menus). Completeness
-- and uniqueness are required within that owner, then within the roster. An
-- unreadable widget INSIDE either searched scope still refuses the result.
function M.stand_cells(menu,class,valid,measure)
    local roster_class='WBP_PalCommonScrollList_C'
    local roster_name='WBP_PalCommonScrollList_PalList'
    local meta={complete=true,visits=0,budget=512,budget_exhausted=false,scope='menu owner'}
    if not valid(menu) then refuse(meta,'IsValid'); return nil,meta end
    local ok,root=pcall(function()
        local owned=menu.WidgetTree
        if valid(owned) then return owned.RootWidget end
    end)
    if not ok or not valid(root) then refuse(meta,'RootWidget'); return nil,meta end
    local rosters={}
    local owner_token=measure and measure.begin('stand tree: menu ownership')
    meta=stand_walk(root,valid,function(widget,name)
        local kind=name:match('^([^ ]+) ')
        if kind==roster_class then
            local read,short=pcall(function() return widget:GetFName():ToString() end)
            -- A failed candidate identity read cannot rule out a duplicate.
            if not read or type(short)~='string' then
                rosters[#rosters+1]=false
            elseif short==roster_name then rosters[#rosters+1]=widget end
        end
        -- The _C rule is only an ownership boundary here, never a declaration
        -- that the widget has no children. Its tree is outside the search.
        return kind=='UserWidget' or (kind and kind:sub(-2)=='_C')
    end,512,false) -- Panel-child edges only; never read another private tree.
    if owner_token then measure.finish(owner_token) end
    meta.scope='menu owner'
    meta.scope_matches=#rosters
    if not meta.complete then return nil,meta end
    for _,candidate in ipairs(rosters) do
        if candidate==false then refuse(meta,'roster identity',roster_class,roster_name); return nil,meta end
    end
    if #rosters~=1 then
        refuse(meta,#rosters==0 and 'roster missing' or 'roster ambiguous',roster_class,roster_name)
        return nil,meta
    end
    local found,inner,names=stand_roster_cells(rosters[1],class,valid,measure)
    inner.scope='Pal roster'
    inner.owner_visits=meta.visits
    inner.owner_budget=meta.budget
    -- Aligned scalar names from this completed walk only. Callers must not
    -- retain targets or use these names as lifetime evidence across callbacks.
    return found,inner,names
end
return M
