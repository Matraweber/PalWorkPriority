-- Plain-data presentation of saved/synchronized rules and scoped evidence.
local M = {}
local stock_snapshot = require('storage_snapshot')
local empty = {}
local labels = {saving='Saving...', saved='Saved', error='Save failed - changes need attention',
    missing='No saved limits yet', connecting='Connecting to server...', pending='Sending changes...',
    acknowledged='Server accepted - awaiting data', applied='Confirmed by server', accepted='Confirmed by server',
    applied_unsaved='Applied - not saved', ready='Synced with server',
    rejected='Server rejected changes', incompatible='Server version incompatible', unavailable='Settings unavailable'}
-- Every reason code that can reach the panel's notice row, in plain words
-- (2026-10-21 review, P2-5/P2-6). net.lua, protocol.lua, caps.lua and the
-- settings writers each add their own codes; anything code-shaped that is
-- not listed falls back to plain_fallback below, never the raw code.
local MISMATCH='The server runs a different Pal Work Priority version. Install the same version as the server.'
local RESYNC='Waiting for fresh data from the server.'
local NO_NEW='This item cannot have a limit.'
local NO_RULE='There is no such limit to remove for your guild.'
local reasons = {awaiting_session='Connecting to the server...', awaiting_handshake='Waiting for the server handshake.',
    handshake_timeout='The server did not answer. Check that it runs the same Pal Work Priority version.',
    server_session_changed='The server restarted or changed. Reconnecting...',
    unsupported_limit=NO_NEW,
    no_active_legacy_rule=NO_RULE,
    rejected='The server rejected this change; confirmed settings are unchanged.',
    handler_error='The server could not process this change.',
    invalid_edit='The server rejected an invalid change.',
    request_id_reused='The server rejected a repeated change. Try again.',
    stale_request='The server rejected an expired change. Try again.',
    not_authorized='The server did not allow this change.',
    awaiting_snapshots='Waiting for complete server data.', awaiting_snapshot='Waiting for confirmed server data.',
    transport_unavailable='Server connection unavailable; changes are not confirmed.',
    ack_timeout='Server did not acknowledge the change.', snapshot_timeout='Confirmed server data did not arrive.',
    queue_timeout='The change waited too long and was not sent. Try again.',
    timed_out='The change was not confirmed in time.',
    save_failed='The server applied this change but could not save it; it may be lost after a restart.',
    schema_or_work_width=MISMATCH,
    server_requires_matching_mod=MISMATCH,
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
    ['Item-specific limits await a verified producer adapter and scope']=NO_NEW,
    ['No active legacy rule for this guild']=NO_RULE,
    ['ceiling out of range']='Enter a whole number from 1 to 9,999,999.',
    ['invalid item id']='This item cannot have a limit.',
    ['unknown work type']='This work type cannot have a limit.'}
-- A code nobody listed is still not shown raw.
local plain_fallback='Limits are not confirmed right now. Try again in a moment.'
local function plain(err)
    if err==nil then return nil end
    if reasons[err] then return reasons[err] end
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

function M.stock(cfg,scheduler,guild,selected,is_client,remote)
    local view={verified=false, guild=guild, choices={}, label='Storage unavailable', totals=empty}
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
            view.label='Base '..index..' of '..#view.choices
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
    return view
end

function M.verdict(scheduler,work,view)
    if not view or not view.verified then return nil end
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
    -- Third value: how many bases the partial count is out of ("Reached 2/3").
    return seen.capped>=seen.camps,
        seen.capped>0 and seen.capped<seen.camps and seen.capped or nil, seen.camps
end
return M
