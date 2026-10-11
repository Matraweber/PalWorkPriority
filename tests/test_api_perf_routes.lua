-- Call-count and lifetime contracts, not native timing estimates.
package.loaded.log={count=function() end, warn=function() end}
local failures={}
local function check(name, fn)
    package.loaded.palapi=nil
    package.loaded.UEHelpers={GetEngine=function() error('no local engine') end}
    FindAllOf=function() error('unexpected global enumeration') end
    FindFirstOf=function() error('unexpected first-object lookup') end
    StaticFindObject=function() error('unexpected static lookup') end
    local api=require('palapi')
    local ok, why=pcall(fn, api)
    if not ok then failures[#failures+1]=name..': '..tostring(why) end
end
local function live(fields) fields.IsValid=function() return true end; return fields end
local function guid(n) return {A=n or 1,B=2,C=3,D=4} end
local function plain(value)
    if type(value)=='table' then
        assert(not getmetatable(value), 'diagnostic retained a wrapper')
        for key, child in pairs(value) do assert(type(key)=='string'); plain(child) end
    else
        assert(type(value)=='string' or type(value)=='number' or type(value)=='boolean')
    end
end
local function storage(scope, cls, calls, backing)
    backing=backing or live({GetFullName=function() return 'PalItemContainer shared' end,
        ItemSlotArray={{ItemId={StaticId={ToString=function() return 'Stone' end}},StackCount=50}}})
    local module=live({TargetContainer=backing})
    return live({GetItemContainerModule=function() calls.module=calls.module+1; return module end,
        GetBaseCampIdBelongTo=function() calls.scope=calls.scope+1; return scope end,
        GetFullName=function() calls.class=calls.class+1; return cls..' model' end})
end

check('534 unknown scopes retain evidence without 534 class reads', function(api)
    local calls={module=0,scope=0,class=0,walk=0}
    local models={}
    for i=1,534 do models[i]=storage({A=0,B=0,C=0,D=0},'Chest',calls) end
    FindAllOf=function(cls) assert(cls==api.CONTAINER_BASE_CLASS); calls.walk=calls.walk+1; return models end
    local totals, counts, e=api.chest_totals_by_camp({exclude={}})
    assert(not e.complete and e.deduplicated and e.unknown_scope==534 and e.failed_reads==534)
    assert(e.reasons.scope_zero_guid==534 and next(totals)==nil and next(counts)==nil)
    assert(calls.walk==1 and calls.module==534 and calls.scope==534)
    assert(calls.class==0, 'unfiltered unknown scopes still read every class name')
    assert(api.last_storage_scan.class_reads==0 and api.last_storage_scan.class_skips==534)
    plain(api.last_storage_scan)
end)

check('scope short circuit preserves filters and scenery', function(api)
    local calls={module=0,scope=0,class=0}
    local model=storage({A=0,B=0,C=0,D=0},'Excluded',calls)
    FindAllOf=function() return {model} end
    local _, _, e=api.chest_totals_by_camp({exclude={'Excluded'}})
    assert(e.complete and e.unknown_scope==0 and calls.scope==0 and calls.class==1)
    _, _, e=api.chest_totals_by_camp({include={'Other'},exclude={}})
    assert(e.complete and calls.scope==0)
    _, _, e=api.chest_totals_by_camp({include={'Excluded'},exclude={'Excluded'}})
    assert(not e.complete and e.unknown_scope==1, 'include precedence changed')
    _, _, e=api.chest_totals_by_camp({include={},exclude={}})
    assert(e.complete, 'explicit empty include stopped excluding all classes')
    FindAllOf=function() return {live({GetItemContainerModule=function() return nil end,
        GetBaseCampIdBelongTo=function() error('scenery scope must not be read') end})} end
    _, _, e=api.chest_totals_by_camp({exclude={}})
    assert(e.complete and e.unknown_scope==0)
end)

check('verified other camp avoids class read; included class errors remain unknown', function(api)
    local calls={module=0,scope=0,class=0}
    local model=storage(guid(9),'Chest',calls)
    FindAllOf=function() return {model} end
    local _, _, e=api.camp_item_totals('1-2-3-4',{exclude={}})
    assert(e.complete and e.unknown_scope==0)
    assert(calls.class==0, 'verified other-camp container still reads its class')
    model.GetFullName=function() error('class unavailable') end
    _, _, e=api.camp_item_totals('9-2-3-4',{exclude={}})
    assert(not e.complete and e.reasons.model_class==1)
end)

check('unknown class cannot conceal a scoped failure or filter membership', function(api)
    local calls={module=0,scope=0,class=0}
    local model=storage(nil,'Chest',calls)
    model.GetFullName=function() error('class unavailable') end
    FindAllOf=function() return {model} end
    local _, _, e=api.chest_totals_by_camp({exclude={}})
    assert(not e.complete and e.unknown_scope==1 and e.reasons.scope_missing_guid==1)
    _, _, e=api.chest_totals_by_camp({include={'Chest'},exclude={}})
    assert(not e.complete and e.reasons.model_class==1)
end)

check('complete containers, duplicate scopes and fresh scans remain intact', function(api)
    local calls={module=0,scope=0,class=0}
    local models={storage(guid(),'Chest',calls),storage(guid(),'Chest',calls)}
    FindAllOf=function() return models end
    local totals, counts, e=api.chest_totals_by_camp({exclude={}})
    assert(totals['1-2-3-4'].Stone==50 and counts['1-2-3-4']==1 and e.complete and e.deduplicated)
    models[2]=storage(guid(9),'Chest',calls)
    _, _, e=api.chest_totals_by_camp({exclude={}})
    assert(not e.complete and not e.deduplicated and e.reasons.duplicate_scope==1)
    models={storage({A=0,B=0,C=0,D=0},'Chest',calls)}
    totals, counts, e=api.all_chest_totals({exclude={}})
    assert(e.complete and totals.Stone==50 and counts==1, 'global reader discarded zero-GUID storage')
end)

check('zero GUID makes no string conversions; partial and negative GUID contracts stay intact', function(api)
    local original=tostring
    local conversions=0
    tostring=function(v) if type(v)=='number' then conversions=conversions+1 end; return original(v) end
    local ok, key=pcall(api.guid_key,{A=0,B=0,C=0,D=0})
    tostring=original
    assert(ok and key==nil and conversions==0, 'unset GUID still builds a throwaway identity string')
    assert(api.guid_key({A=-1,B=2,C=-3,D=4})=='-1-2--3-4')
    assert(api.guid_key({A=1,B=2,C=3})==nil and select('#',api.guid_key(nil))==1)
end)

check('required work manager is lazy, once per call, and never retained', function(api)
    local calls, stale_reads=0,0
    local work=live({GetWorkId=function() return guid() end})
    local manager=live({GetWork=function() return work end})
    local util=live({GetWorkProgressManager=function() calls=calls+1; return manager end})
    api.cdo=function() return util end
    api.player_controller=function() return live({}) end
    local entries={work}
    local camp={WorkerDirector=live({RequiredAssignWorks={ForEach=function(_,fn)
        for i,e in ipairs(entries) do fn(i,e) end
    end}})}
    local result, seen=api.camp_required_works(camp)
    assert(result[1]==work and seen==1 and calls==0, 'direct work needlessly resolved manager')
    entries={}; result,seen=api.camp_required_works(camp)
    assert(#result==0 and seen==0 and calls==0, 'empty list needlessly resolved manager')
    entries={guid(),guid(9),work}; result,seen=api.camp_required_works(camp)
    assert(#result==3 and seen==3 and calls==1)
    manager.IsValid=function() stale_reads=stale_reads+1; error('retired manager') end
    manager=live({GetWork=function() return work end})
    result=api.camp_required_works(camp)
    assert(#result==3 and calls==2 and stale_reads==0, 'manager survived its synchronous reader call')
    manager=nil; result,seen=api.camp_required_works(camp)
    assert(#result==1 and seen==3 and calls==3, 'missing manager was repeatedly resolved or hid unresolved entries')
end)

check('owned children route needs no controller name or global lookup', function(api)
    local names, components, static, stale_reads=0,0,0,0
    local comp=live({})
    local class=live({})
    StaticFindObject=function(path)
        assert(path=='/Script/Pal.PalNetworkBaseCampComponent'); static=static+1; return class
    end
    local tx=live({GetFullName=function() return 'PalNetworkTransmitter tx' end,
        GetComponentByClass=function(_,cls) assert(cls==class); components=components+1; return comp end})
    local pc=live({Children={tx},GetFullName=function() names=names+1; return 'PalPlayerController pc' end})
    api.player_controller=function() return pc end
    assert(api.owned_network_component()==comp and components==1 and static==1)
    assert(names==0, 'owned children route needlessly reads controller name')
    comp.IsValid=function() stale_reads=stale_reads+1; error('retired component') end
    comp=live({})
    assert(api.owned_network_component()==comp and components==2 and static==1 and stale_reads==0)
end)

check('camp enumeration stays fresh and publishes bounded fallback evidence', function(api)
    local walks, stale_reads=0,0
    local camp=live({})
    FindAllOf=function(cls) assert(cls=='PalBaseCampModel'); walks=walks+1; return {camp} end
    assert(api.base_camps()[1]==camp)
    camp.IsValid=function() stale_reads=stale_reads+1; error('retired camp') end
    camp=live({})
    assert(api.base_camps()[1]==camp and walks==2 and stale_reads==0)
    assert(api.last_camp_scan.route=='class_walk' and api.last_camp_scan.complete)
    plain(api.last_camp_scan)
    local unreadable={IsValid=function() return false end}
    FindAllOf=function() return {camp,unreadable} end
    assert(api.base_camps()[1]==camp and api.camps_available==false and not api.last_camp_scan.complete,
        'a partial camp sweep was reported as complete')
    FindAllOf=function() return nil end
    assert(#api.base_camps()==0 and api.camps_available==false and not api.last_camp_scan.complete)
    api.reset()
    assert(api.last_camp_scan==nil and api.camps_available==nil and api.camps_error==nil)
end)

check('controller callback memo clears on end, new begin and reset', function(api)
    local calls, stale_reads=0,0
    local pc=live({})
    package.loaded.UEHelpers={GetEngine=function()
        calls=calls+1; return {GameViewport={World={OwningGameInstance={LocalPlayers={{PlayerController=pc}}}}}}
    end}
    api.pc_memo_begin()
    assert(api.player_controller()==pc and api.player_controller()==pc and calls==1)
    api.pc_memo_end()
    pc.IsValid=function() stale_reads=stale_reads+1; error('retired pc') end
    pc=live({})
    assert(api.player_controller()==pc and calls==2 and stale_reads==0)
    api.pc_memo_begin(); assert(api.player_controller()==pc)
    pc=live({}); api.pc_memo_begin(); assert(api.player_controller()==pc)
    api.reset(); pc=live({}); assert(api.player_controller()==pc)
end)

check('local controller proves viewport and shares only its callback scope', function(api)
    local calls, stale_reads=0,0
    local pc=live({})
    local world=live({OwningGameInstance={LocalPlayers={{PlayerController=pc}}}})
    local viewport=live({World=world})
    package.loaded.UEHelpers={GetEngine=function() calls=calls+1; return {GameViewport=viewport} end}
    api.pc_memo_begin()
    assert(api.has_viewport() and api.local_player_controller()==pc and api.has_viewport())
    assert(api.player_controller()==pc and calls==1, 'local viewport/controller checks repeated the engine chain')
    api.pc_memo_end()
    pc.IsValid=function() stale_reads=stale_reads+1; error('retired local pc') end
    pc=live({}); world.OwningGameInstance.LocalPlayers[1].PlayerController=pc
    assert(api.local_player_controller()==pc and stale_reads==0 and calls==2)
    assert(api.local_player_controller()==pc and calls==3, 'local controller cached outside callback scope')
    api.pc_memo_begin(); assert(api.has_viewport())
    api.pc_memo_begin(); assert(api.local_player_controller()==pc and calls==5)
    api.reset(); assert(api.local_player_controller()==pc and calls==6)
end)

check('failed viewport cannot promote a fallback remote controller', function(api)
    local remote=live({})
    FindFirstOf=function() return remote end
    api.pc_memo_begin()
    assert(api.player_controller()==remote)
    assert(api.local_player_controller()==nil and not api.has_viewport())
    local pc=live({})
    local world=live({OwningGameInstance={LocalPlayers={{PlayerController=pc}}}})
    local viewport=live({World=world})
    package.loaded.UEHelpers={GetEngine=function() return {GameViewport=viewport} end}
    -- Misses are never latched, even in a scope that already found a remote pc.
    assert(api.local_player_controller()==pc and api.has_viewport())
    api.pc_memo_end()
    viewport.IsValid=function() return false end
    assert(api.local_player_controller()==nil, 'valid final controller concealed an invalid viewport')
    viewport.IsValid=function() return true end; world.IsValid=function() return false end
    assert(api.local_player_controller()==nil, 'valid final controller concealed an invalid world')
end)

check('unowned RPC fallback requires affirmative authority', function(api)
    local walks, sends=0,0
    local comp=live({RequestChangeWorkSuitability_ToServer=function() sends=sends+1 end,
        RequestReplicateBaseCampWork_ToServer=function() sends=sends+1 end})
    api.owned_network_component=function() return nil end
    api.network_component=function() walks=walks+1; return comp end
    local role
    api.has_authority=function() return role end
    local id={PlayerUId=guid(),InstanceId=guid(9)}
    for _, r in ipairs({false,'unknown'}) do
        if r=='unknown' then role=nil else role=r end
        assert(not api.set_work_enabled(id,1,true) and not api.request_work_replication(guid(),true))
        assert(walks==0 and sends==0, 'client/unknown fallback walked or sent through an unowned component')
    end
    role=true
    assert(api.set_work_enabled(id,1,true) and api.request_work_replication(guid(),true))
    assert(walks==2 and sends==2)
    role=nil
    assert(api.set_work_enabled(id,1,true,comp) and walks==2 and sends==3)
    api.owned_network_component=function() return comp end
    assert(api.set_work_enabled(id,1,true) and api.request_work_replication(guid(),true))
    assert(walks==2 and sends==5)
end)

assert(#failures==0, table.concat(failures,'\n'))
