-- Plain-data presentation of saved/synchronized rules and scoped evidence.
local M = {}
local stock_snapshot = require('storage_snapshot')
local empty = {}
-- The two failures point at the reason under them (round 3, newcomer P3-6).
local labels = {saving='Saving...', saved='Saved', error='Save failed - see the line below',
    missing='No saved limits yet', connecting='Connecting to server...', pending='Sending changes...',
    acknowledged='Server accepted - awaiting data', applied='Confirmed by server', accepted='Confirmed by server',
    applied_unsaved='Applied, not saved - see below', ready='Synced with server',
    rejected='Server rejected changes', incompatible='Server version incompatible', unavailable='Settings unavailable'}
-- Every reason code that can reach the panel's notice row, in plain words
-- (2026-10-21 review, P2-5/P2-6). net.lua, protocol.lua, caps.lua and the
-- settings writers each add their own codes; anything code-shaped that is
-- not listed falls back to plain_fallback below, never the raw code.
-- A version mismatch (round 3, onboarding P2-1). "Install the same version
-- as the server" sent Workshop players to a version they cannot get back;
-- the server's copy is what controls work there, so the host is who can fix
-- it. The version named is this mod's own (ui.MOD_VERSION), not a copy.
local MISMATCH='This server runs another Pal Work Priority version, which controls work here. '
    ..'Ask the host to update the server to %s.'
local function mismatch()
    local ui=package.loaded.ui
    local version=type(ui)=='table' and type(ui.MOD_VERSION)=='string' and ui.MOD_VERSION or nil
    if version then return string.format(MISMATCH,version) end
    return (MISMATCH:gsub(' to %%s%.$','.'))
end
M.mismatch_text=mismatch
local RESYNC='Waiting for fresh data from the server.'
local NO_NEW='This item cannot have a limit.'
local NO_RULE='There is no such limit to remove for your guild.'
local reasons = {awaiting_session='Connecting to the server...', awaiting_handshake='Waiting for the server handshake.',
    handshake_timeout='The server did not answer. Check that it runs the same Pal Work Priority version.',
    server_session_changed='The server restarted or changed. Reconnecting...',
    unsupported_limit=NO_NEW,
    no_active_legacy_rule=NO_RULE,
    too_many_limits='This guild already has 500 limits. Remove one first.',
    rejected='The server rejected this change; confirmed settings are unchanged.',
    handler_error='The server could not process this change.',
    invalid_edit='The server rejected an invalid change.',
    request_id_reused='The server rejected a repeated change. Try again.',
    stale_request='The server rejected an expired change. Try again.',
    rate_limited='Too many changes at once; this one was not applied. Wait a moment and try again.',
    not_authorized='The server did not allow this change.',
    awaiting_snapshots='Waiting for complete server data.', awaiting_snapshot='Waiting for confirmed server data.',
    transport_unavailable='Server connection unavailable; changes are not confirmed.',
    ack_timeout='Server did not acknowledge the change.', snapshot_timeout='Confirmed server data did not arrive.',
    queue_timeout='The change waited too long and was not sent. Try again.',
    timed_out='The change was not confirmed in time.',
    save_failed='The server applied this change but could not save it; it may be lost after a restart.',
    schema_or_work_width=mismatch,
    server_requires_matching_mod=mismatch,
    settings_restart_required='Server settings are locked. The host must restart the game or server before editing can resume.',
    settings_recovering='The server is loading saved settings. Editing is temporarily locked.',
    activation_busy='Settings are being loaded. Try again in a moment.',
    snapshot_apply_failed=RESYNC, snapshot_invalidated=RESYNC, invalid_packet=RESYNC, invalid_stream=RESYNC,
    invalid_kind=RESYNC, invalid_row=RESYNC, invalid_begin=RESYNC, invalid_delta=RESYNC, missing_begin=RESYNC,
    duplicate_row=RESYNC, delta_revision_gap=RESYNC, incomplete_snapshot=RESYNC, snapshot_too_large=RESYNC,
    invalid_storage=RESYNC, storage_too_large=RESYNC, storage_unrequested=RESYNC, storage_expired=RESYNC,
    wrong_storage_request=RESYNC, stale_revision=RESYNC, wrong_session=RESYNC,
    snapshot_changed='Limits changed while saving. Check them and try again.',
    ['scope unavailable']='Your guild could not be read. Try again in a moment.',
    -- caps.lua's own sentences, which used internal terms.
    ['No active legacy rule for this guild']=NO_RULE,
    ['ceiling out of range']='Enter a whole number from 1 to 9,999,999.',
    ['invalid item id']='This item cannot have a limit.',
    ['unknown work type']='This job cannot have a limit.'}
-- A code nobody listed is still not shown raw.
local plain_fallback='Limits are not confirmed right now. Try again in a moment.'
local function plain(err)
    if err==nil then return nil end
    local said=reasons[err]
    if type(said)=='function' then return said() end
    if said then return said end
    if type(err)=='string' and err:match('^[%l%d_]+$') then return plain_fallback end
    return err
end
M.plain_reason=plain
function M.save(caps)
    local state,err=caps.state,caps.error
    if caps.view_status then
        local ok,s,e=pcall(caps.view_status)
        if ok then state,err=s,e else state,err='unavailable','Save status unavailable' end
    end
    return state,labels[state] or 'Save status unavailable',plain(err)
end

-- Presentation of the trusted caps return contract, never an authority grant.
-- true retains its existing durable-local / sent-client meaning. A local pending
-- receipt must match this session, guild and the value now held by caps.
function M.submission(caps,written,why,receipt,guild,work,item,amount,epoch)
    if caps.session~=epoch then return false end
    if written==true then return true,false end
    if written~=false or why~='pending' or caps.is_client or caps.submit
        or not caps.decided or type(receipt)~='table' or getmetatable(receipt)
        or math.type(receipt.epoch)~='integer' or receipt.epoch~=epoch
        or math.type(receipt.revision)~='integer' or receipt.revision<1
        or receipt.revision>2147483646 then return false end
    for _,key in ipairs({'session','incarnation'})do
        local v=receipt[key]
        if type(v)~='string' or #v<1 or #v>256 or v:find('%c') then return false end
    end
    local storage,canonical
    if type(receipt.scope)=='string' then storage,canonical=receipt.scope:match('^PWP%-SCOPE%-1:([0-9a-f]+):([0-9a-f]+):limits$')end
    if not storage or #storage~=32 or not canonical or #canonical~=32
        or storage==string.rep('0',32) or canonical==string.rep('0',32) then return false end
    local wanted=guild
    if type(wanted)~='string' then return false end
    if wanted~=canonical then
        local a,b,c,d=wanted:match('^(%-?%d+)%-(%-?%d+)%-(%-?%d+)%-(%-?%d+)$')
        if not a then return false end
        local parts={}
        for _,word in ipairs({a,b,c,d})do
            local n=math.tointeger(tonumber(word))
            if not n or n< -2147483648 or n>4294967295 or tostring(n)~=word then return false end
            parts[#parts+1]=string.format('%08x',n & 0xffffffff)
        end
        if table.concat(parts)~=canonical then return false end
    end
    local state=M.save(caps)
    if state~='saving' or caps.error~=nil then return false end
    local rows=type(caps.data)=='table' and caps.data[guild]
    local value=rows and rows[work] and rows[work][item]
    if amount~=nil then
        if value~=amount then return false end
    elseif value~=nil and value~=false then return false end
    return true,true
end

-- The words after "Storage: " for a view, from its shape alone, so a
-- client's view (built by net) reads like the host's (round 3, newcomer).
-- Which base the player is in is not known (palapi has no player or camp
-- position), so with two or more the shown one is only "Base N of M" and the
-- line says each is counted alone. One base is just "your base" (P3-2).
-- Nothing counted is "not counted yet": "Storage: Storage unavailable"
-- said the word twice (P3-1).
function M.scope_label(view)
    if type(view)~='table' then return 'not counted yet' end
    if view.scope=='guild' then return 'All loaded bases in your guild' end
    local n=type(view.choices)=='table' and #view.choices or 0
    if view.scope=='camp' and math.type(view.index)=='integer' and view.index>=1 and view.index<=n then
        if n==1 then return 'your base' end
        return 'Base '..view.index..' of '..n..', counted alone'
    end
    return 'not counted yet'
end

-- One camp's totals, only while its evidence is this pass's, this guild's,
-- complete and fresh: the same test the panel's own view passes.
local function camp_totals(scheduler,guild,camp)
    local evidence=(scheduler.last_storage_by_camp or {})[camp]
    local totals=(scheduler.last_totals_by_camp or {})[camp]
    if type(evidence)=='table' and evidence.verified==true and evidence.pass==scheduler.pass_id
        and evidence.scope=='camp' and evidence.guild==guild and (evidence.unknown_scope or 0)==0
        and type(totals)=='table' and stock_snapshot.fresh(evidence,os.clock())~=nil then
        return totals
    end
end

-- The most of an item that any of these bases holds, or nil unless every
-- one of them is counted (host only; a client gets one base's count). A new
-- limit is seeded from this while the player has not chosen the base shown
-- (round 3, newcomer P1-1): seeded from one base, it could already be
-- reached at another and stop the job there the moment it was made.
function M.highest(scheduler,guild,choices,item)
    if type(scheduler)~='table' or type(choices)~='table' or #choices==0 then return nil end
    local best=0
    for _,camp in ipairs(choices) do
        local totals=camp_totals(scheduler,guild,camp)
        if not totals then return nil end
        local n=totals[item]
        if type(n)=='number' and n>best then best=n end
    end
    return best
end

function M.stock(cfg,scheduler,guild,selected,is_client,remote)
    local view={verified=false, guild=guild, choices={}, label='not counted yet', totals=empty}
    if not guild then return view end
    if is_client then
        if remote and remote.request_stock and remote.storage_view then
            local ok, received=pcall(function()
                remote.request_stock(guild,selected)
                return remote.storage_view(guild,selected)
            end)
            if ok and type(received)=='table' and received.guild==guild
                and type(received.choices)=='table' and type(received.totals)=='table'
                and type(received.label)=='string' and received.epoch==remote.epoch
                and received.epoch~=nil then
                if not received.verified then
                    view.choices,view.scope,view.camp,view.index=received.choices,received.scope,received.camp,received.index
                    view.label=received.label
                    return view
                end
                if (received.scope=='guild' or (received.scope=='camp'
                    and type(received.camp)=='string' and (selected==nil or received.camp==selected)))
                    and type(received.expires_at)=='number' and received.expires_at>os.clock() then
                    return received
                end
            end
        end
        return view
    end
    for camp,meta in pairs(scheduler.last_storage_by_camp or {}) do
        if meta.guild==guild and meta.pass==scheduler.pass_id and meta.scope=='camp' then
            view.choices[#view.choices+1]=camp
        end
    end
    table.sort(view.choices)
    local evidence,totals
    if cfg.storage_scope=='global' then
        view.scope='guild'; view.label='All loaded bases in your guild'
        evidence=(scheduler.last_storage or {})[guild]
        totals=(scheduler.last_totals_by_guild or {})[guild]
    else
        view.scope='camp'
        local index
        for i,camp in ipairs(view.choices) do if camp==selected then index=i end end
        index=index or (#view.choices>0 and 1 or nil)
        if index then
            view.camp=view.choices[index]; view.index=index
            evidence=(scheduler.last_storage_by_camp or {})[view.camp]
            totals=(scheduler.last_totals_by_camp or {})[view.camp]
        end
    end
    view.verified=type(evidence)=='table' and evidence.verified==true
        and evidence.pass==scheduler.pass_id and evidence.scope==view.scope
        and (view.scope~='camp' or evidence.guild==guild)
        and (evidence.unknown_scope or 0)==0 and type(totals)=='table'
        and stock_snapshot.fresh(evidence,os.clock())~=nil
    if view.verified then view.totals=totals end
    view.label=M.scope_label(view)
    return view
end

-- This machine's role, read where panel.lua reads it. Unloaded means host.
local function client()
    local caps=package.loaded.caps
    return type(caps)=='table' and caps.is_client==true
end
local function transport()
    local net=package.loaded.net
    return type(net)=='table' and net or nil
end

-- The scheduler's own record for one work type, if every camp it summarizes
-- is proven to belong to this displayed scope.
local function host_seen(scheduler,work,view)
    local seen=(scheduler.last_capped or {})[work]
    if not seen or seen.pass~=scheduler.pass_id or seen.unknown~=0
        or type(seen.camps)~='number' or seen.camps<=0 or type(seen.capped)~='number' then return nil end
    -- last_capped is currently server-wide. It is usable only if every camp
    -- it summarizes is proven to belong to this displayed scope. Otherwise
    -- await a scoped scheduler verdict instead of borrowing another guild's.
    local count=0
    for camp,meta in pairs(scheduler.last_storage_by_camp or {}) do
        if meta.pass==scheduler.pass_id then
            if meta.guild~=view.guild or meta.verified~=true then return nil end
            if view.scope=='camp' and camp~=view.camp then return nil end
            count=count+1
        end
    end
    if count~=seen.camps then return nil end
    return seen
end

-- The guild's camps in a view's scope this pass: {[camp]=true} and how many.
-- Camp scope is the view's own camp only, and only if it is the guild's.
local function scope_camps(scheduler,guild,view)
    local camps,n={},0
    if type(scheduler)~='table' or type(view)~='table' or type(guild)~='string' then return camps,n end
    for camp,meta in pairs(scheduler.last_storage_by_camp or {}) do
        if type(meta)=='table' and meta.pass==scheduler.pass_id and meta.guild==guild
            and (view.scope~='camp' or camp==view.camp) then camps[camp],n=true,n+1 end
    end
    return camps,n
end

-- Verdicts {[work]={camps=, capped=, unknown=}} of one guild for exactly the
-- scope of a view, plus that scope's camps. With
-- scheduler.last_capped_by_camp ({[camp]={pass=, works={[work]=true (capped)
-- | false (running) | 'unknown'}}}) it is exact for any number of bases and
-- guilds; without it the server-wide last_capped counts only where host_seen
-- proves it covers this scope alone. rules (work -> anything) limits the
-- answer to judged work types; nil judges every one. The host's own panel
-- and a client's reply (server_limits) both read it, so they cannot differ.
local function scoped_verdicts(scheduler,guild,view,rules)
    local out={}
    local camps,n=scope_camps(scheduler,guild,view)
    if n==0 or (view.scope=='camp' and n~=1) then return out,camps end
    local by_camp=scheduler.last_capped_by_camp
    local function judged(name) return rules==nil or rules[name]~=nil end
    if type(by_camp)=='table' then
        local function works(camp)
            local entry=by_camp[camp]
            if type(entry)=='table' and entry.pass==scheduler.pass_id and type(entry.works)=='table' then
                return entry.works
            end
        end
        local names={}
        if rules~=nil then
            -- Only the asked work types (round 3, performance P3-1): the
            -- panel asks one per row, up to 26 times a draw, and walking
            -- every job of every camp for each was the cost.
            for name in pairs(rules) do
                for camp in pairs(camps) do
                    if (works(camp) or empty)[name]~=nil then names[name]=true break end
                end
            end
        else
            for camp in pairs(camps) do
                for name in pairs(works(camp) or {}) do names[name]=true end
            end
        end
        for name in pairs(names) do
            local v={camps=n, capped=0, unknown=0}
            for camp in pairs(camps) do
                local state=(works(camp) or {})[name]
                if state==true then v.capped=v.capped+1
                elseif state~=false then v.unknown=v.unknown+1 end
            end
            out[name]=v
        end
    else
        local scope={verified=true, guild=guild, scope=view.scope, camp=view.camp}
        for name in pairs(scheduler.last_capped or {}) do
            local seen=judged(name) and host_seen(scheduler,name,scope)
            if seen then out[name]={camps=seen.camps, capped=seen.capped, unknown=0} end
        end
    end
    return out,camps
end

-- A client's view carries the server's verdicts (protocol schema 5), so the
-- client shows what the server decided instead of "No count yet". Nil until
-- a fresh count with verdicts arrived, and for a work type it did not judge.
function M.verdict(scheduler,work,view)
    if not view or not view.verified then return nil end
    local seen
    if view.limits~=nil or client() then
        local limits=type(view.limits)=='table' and view.limits or {}
        seen=type(limits.verdicts)=='table' and limits.verdicts[work] or nil
        if type(seen)~='table' or seen.unknown~=0 or type(seen.camps)~='number' or seen.camps<=0
            or type(seen.capped)~='number' then return nil end
    else
        -- The host judges its own panel's scope per camp, as a client's
        -- reply does: host_seen alone gave nil in camp scope with two or
        -- more bases (the default), so every group row said "No count yet".
        -- Judged for this work type alone (round 3, performance P3-1).
        seen=scoped_verdicts(scheduler,view.guild,view,{[work]=true})[work]
        if type(seen)~='table' or seen.unknown~=0 then return nil end
    end
    -- Third value: how many bases the partial count is out of ("Reached 2/3").
    return seen.capped>=seen.camps,
        seen.capped>0 and seen.capped<seen.camps and seen.capped or nil, seen.camps
end

-- Whether Mining limits work per item (on rocks). A client follows the
-- server, since the server is the one that holds rocks; until a reply said
-- so it falls back to its own config.
function M.per_item(cfg)
    if client() then
        local net=transport()
        local flag=net and net.server_item_limits
        if flag==true or flag==false then return flag end
    end
    return not (type(cfg)=='table' and cfg.item_limits_on_rocks==false)
end

-- Items whose rocks are held in these camps, {[item]=true}, or nil when
-- item_sources cannot say for exactly them. held_items answers per camp;
-- an older item_sources' item_stopped answers for every camp at once, which
-- is this scope's answer only while every camp holding rocks lies inside it.
local function held_in(sources,camps,items)
    if type(sources)~='table' then return nil end
    local out={}
    if type(sources.held_items)=='function' then
        for camp in pairs(camps) do
            local ok,held=pcall(sources.held_items,camp)
            if ok and type(held)=='table' then
                for item,yes in pairs(held) do if yes==true then out[item]=true end end
            end
        end
        return out
    end
    if type(sources.item_stopped)~='function' or type(sources.blocked)~='table'
        or type(items)~='table' then return nil end
    for camp,keys in pairs(sources.blocked) do
        if type(keys)=='table' and next(keys)~=nil and not camps[camp] then return nil end
    end
    for item in pairs(items) do
        local ok,stopped=pcall(sources.item_stopped,item)
        if ok and stopped==true then out[item]=true end
    end
    return out
end

-- Whether rocks of this item are held off. A client asks the server's last
-- fresh count (schema 5), which already covers its scope. The host asks
-- item_sources: with a view, only for that view's guild and scope (as
-- server_limits answers a client); without one, for every camp (callers
-- from before the view argument). False when unknown.
function M.item_stopped(item,view)
    if client() then
        local net=transport()
        if not net or type(net.item_stopped)~='function' then return false end
        local ok,stopped=pcall(net.item_stopped,item)
        return ok and stopped==true
    end
    local sources=package.loaded.item_sources
    if type(view)=='table' then
        local camps,n=scope_camps(package.loaded.scheduler,view.guild,view)
        if n==0 or (view.scope=='camp' and n~=1) then return false end
        local held=held_in(sources,camps,{[item]=true})
        return type(held)=='table' and held[item]==true
    end
    if type(sources)~='table' or type(sources.item_stopped)~='function' then return false end
    local ok,stopped=pcall(sources.item_stopped,item)
    return ok and stopped==true
end

-- Server side of schema 5, for net.on_limit_state: the limit state of one
-- guild for exactly the scope of a storage view it is about to send. Plain
-- data from the last pass, judged by scoped_verdicts for the guild's work
-- types with limits, and the rocks held in that scope's camps.
function M.server_limits(cfg,scheduler,guild,view,caps,sources)
    local out={per_item=not (type(cfg)=='table' and cfg.item_limits_on_rocks==false), verdicts={}, stopped={}}
    if type(view)~='table' or view.verified~=true or type(scheduler)~='table'
        or type(guild)~='string' then return out end
    caps=caps or package.loaded.caps
    sources=sources or package.loaded.item_sources
    local rules
    if type(caps)=='table' and type(caps.all)=='function' then
        local ok,got=pcall(caps.all,cfg,guild)
        if ok and type(got)=='table' then rules=got end
    end
    local verdicts,camps=scoped_verdicts(scheduler,guild,view,rules)
    out.verdicts=verdicts
    if not out.per_item or next(camps)==nil then return out end
    out.stopped=held_in(sources,camps,rules and type(rules.Mining)=='table' and rules.Mining or nil) or {}
    return out
end
return M
