-- Real panel + status + net/protocol, with delayed offline RPCs and mock UMG.
local file=assert(io.open(TEST_ROOT..'/tests/test_panel_render.lua','r'))
local source=file:read('*a');file:close()
local boundary=assert(source:find('\nrules%(1%)\r?\npanel.refresh'))
local scenario=[=[
local panel_api=package.loaded.palapi
local file=assert(io.open(TEST_ROOT..'/tests/test_net_storage.lua','r'))
local source=file:read('*a');file:close()
local boundary=assert(source:find('\nsetup%(%)\r?\nfor i=1,200'))
local network=assert(load(source:sub(1,boundary-1)..[==[
local sent={}
return {
 setup=setup,
 sent=sent,
 advance=function(seconds)time=time+seconds end,
 client=function()return client end,
 server=function()return server end,
 deliver_one=function()return client.receive_state(table.remove(down,1)) end,
 drop=function()down={} end,
 tick=function(deliver)
   time=time+0.1
   client.storage_tick()
   local messages=up;up={}
   for _,msg in ipairs(messages)do
     sent[#sent+1]=msg
     assert(server.receive_command(comp,msg,0))
   end
   server.storage_tick()
   if deliver~=false then
     local messages=down;down={}
     for _,msg in ipairs(messages)do client.receive_state(msg)end
   end
 end,
 drain=function()
   local messages=down;down={}
   for _,msg in ipairs(messages)do client.receive_state(msg)end
 end,
}
]==], '@panel-stock-network-fixture'))()
network.setup()
panel_api.my_guild=function()return 'guild-A' end
caps.is_client=true
caps.view_status=function()return network.client().status end
local built={}
network.server().on_storage_request=function(guild,selected)
    assert(guild=='guild-A')
    local camp=selected or 'camp-A'
    built[#built+1]=camp
    return {scope='camp',camp=camp,choices={'camp-A','camp-B'},verified=true,
        totals={Stone01=camp=='camp-A' and 27867 or 777},age_ms=0,remaining_ms=60000}
end
rules(1)
panel.refresh(cfg);panel.toggle();panel.refresh(cfg)
local function refresh(ticks,deliver)
    for _=1,ticks do network.tick(deliver);panel.refresh(cfg) end
end
refresh(15)
assert(rendered('Storage: Base 1 of 2, each base stops on its own count - change base'),'initial base never arrived')
assert(network.client().storage_view('guild-A',nil).totals.Stone01==27867)
assert(rendered('27,867'),'live-matched Base 1 count did not reach panel')
assert(panel.command(cfg,'click stock_scope'):find('true',1,true))
panel.refresh(cfg)
assert(rendered('?'),'previous base count remained visible while selection pending')
for _=1,100 do panel.refresh(cfg) end
refresh(15,false)
assert(built[#built]=='camp-B','real panel replaced requested Base 2 with Base 1 while pending')
assert(not network.client().storage_view('guild-A','camp-B').verified)
network.drain();panel.refresh(cfg)
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'),'delayed reply did not select Base 2')
assert(rendered('777'),'Base 2 count did not reach real panel')
refresh(10)
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'),'maintenance reverted Base 2')
assert(panel.click_named(cfg,'stock_scope',nil,-1):find('true',1,true))
panel.refresh(cfg);refresh(15)
assert(rendered('Storage: Base 1 of 2, each base stops on its own count - change base'),'selector did not wrap to Base 1')
-- Native callbacks queue the action; intervening refreshes must not change it.
local queued={}
ExecuteInGameThread=function(fn)queued[#queued+1]=fn end
assert(panel.command(cfg,'click stock_scope')==true)
assert(#queued==1)
panel.refresh(cfg)
assert(rendered('27,867'),'queued input changed selection before execution')
queued[1]();ExecuteInGameThread=nil
panel.refresh(cfg)
for _=1,100 do panel.refresh(cfg) end
refresh(15,false)
assert(built[#built]=='camp-B','queued named click lost Base 2 during pending redraws')
network.drain();panel.refresh(cfg)
assert(rendered('777'),'queued named click did not publish delayed Base 2')
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'))

-- Live candidate 2: a verified Base 2 reply can have less than eight seconds
-- left. Expiry removes quantities, not the user's selected/requested base.
local phase='short'
local phase_builds={}
local first_request=#network.sent+1
network.server().on_storage_request=function(guild,selected)
    phase_builds[#phase_builds+1]={phase=phase,selected=selected}
    assert(guild=='guild-A')
    if phase=='unknown_no_camp' or phase=='unknown_camp' then
        return {scope='camp',camp=phase=='unknown_camp' and selected or nil,
            choices={'camp-A','camp-B'},verified=false,totals={},age_ms=0,remaining_ms=0}
    end
    return {scope='camp',camp=selected or 'camp-A',choices={'camp-A','camp-B'},verified=true,
        totals={Stone01=phase=='short' and 5498 or (selected=='camp-A' and 111 or 5499)},
        age_ms=phase=='short' and 52000 or 0,remaining_ms=phase=='short' and 8000 or 60000}
end
network.advance(11);refresh(5)
local short=network.client().storage_view('guild-A','camp-B')
assert(short.verified and short.camp=='camp-B' and short.totals.Stone01==5498)
assert(short.expires_at>os.clock() and short.expires_at-os.clock()<8)
assert(rendered('5,498'),'short-lived Base 2 result did not render')
assert(#phase_builds==1 and phase_builds[1].selected=='camp-B')

network.advance(short.expires_at-os.clock())
panel.refresh(cfg) -- UI observes the deadline even before the network heartbeat.
assert(rendered('?') and not rendered('5,498'),'expired amount still looked current')
assert(not network.client().storage_view('guild-A','camp-B').verified)
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'),
    'expiry removed the base selector header/action while counts became unknown')
phase='unknown_no_camp'
for _=1,100 do panel.refresh(cfg) end
refresh(5) -- expire() clears the committed view and schedules bounded retry.
assert(#phase_builds==1,'expiry caused an immediate refresh storm')
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'),
    'expiry heartbeat discarded selector metadata')
-- The expired count keeps the 10 s poll already due for it (round 3: the
-- poll used to restart from the expiry), so each phase below is one poll
-- period long and gets exactly one request.
refresh(100)
local unknown=network.client().storage_view('guild-A','camp-B')
assert(#phase_builds==2 and phase_builds[2].selected=='camp-B')
assert(not unknown.verified and unknown.camp==nil and #unknown.choices==2)
assert(next(unknown.totals)==nil and rendered('?') and not rendered('5,498'))
for _=1,100 do panel.refresh(cfg) end

-- Both unavailable shapes are legal: choices alone, or choices plus the
-- selected camp. Neither may fall back to the first choice or infer zero.
phase='unknown_camp';refresh(100)
unknown=network.client().storage_view('guild-A','camp-B')
assert(#phase_builds==3 and phase_builds[3].selected=='camp-B')
assert(not unknown.verified and unknown.camp=='camp-B' and unknown.index==2)
assert(next(unknown.totals)==nil and rendered('?') and not rendered('5,498'))
phase='renew';refresh(100)
local renewed=network.client().storage_view('guild-A','camp-B')
assert(#phase_builds==4 and phase_builds[4].selected=='camp-B')
assert(renewed.verified and renewed.camp=='camp-B' and renewed.index==2)
assert(renewed.totals.Stone01==5499 and rendered('5,499'))
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'))
for i=first_request,#network.sent do
    assert(network.sent[i]:match('|camp%-B$'),'expiry/unavailable renewal reverted to auto/Base 1')
end
assert(#network.sent-first_request+1==4,'unexpected duplicate stock requests')

-- Physical hit testing must still find the header after counts expire. Merely
-- calling apply(stock_scope) would bypass the live failure (no registered hit).
local function expired_header_click(expected_camp)
    local view=network.client().storage_view('guild-A',expected_camp)
    assert(not view.verified and next(view.totals)==nil and #view.choices==2)
    assert(view.scope=='camp' and view.camp==expected_camp)
    assert(rendered('?'),'unknown stock borrowed an old amount')
    local original=Widget.IsHovered
    Widget.IsHovered=function(self)
        return type(self.text)=='string' and self.text:find('Storage: Base ',1,true)==1
    end
    local accepted=panel.handle_click(cfg,-1)
    Widget.IsHovered=original
    assert(accepted,'physical click ignored the expired/timeout selector header')
    panel.refresh(cfg)
end
network.advance(renewed.expires_at-os.clock())
panel.refresh(cfg)
expired_header_click('camp-B')
local pending_a=network.client().storage_view('guild-A','camp-A')
assert(not pending_a.verified and #pending_a.choices==0 and next(pending_a.totals)==nil,
    'selection change retained prior-base selector metadata or counts')
refresh(15)
assert(network.sent[#network.sent]:match('|camp%-A$'),'expired physical selector did not request Base 1')
assert(rendered('111') and not rendered('5,499'),'Base 1 borrowed expired Base 2 stock')
assert(rendered('Storage: Base 1 of 2, each base stops on its own count - change base'))

-- Lose all but B on a background renewal. Absolute snapshot timeout must keep
-- metadata usable while exposing no previous amounts or partial new counts.
network.advance(11);refresh(1,false)
assert(network.deliver_one())
network.drop()
refresh(110,false);network.drop()
panel.refresh(cfg)
assert(not rendered('111'),'timed-out refresh left old totals looking verified')
assert(rendered('Storage: Base 1 of 2, each base stops on its own count - change base'),
    'snapshot timeout removed selector metadata')
expired_header_click('camp-A')
refresh(15)
assert(network.sent[#network.sent]:match('|camp%-B$'),'timeout selector did not request Base 2')
assert(rendered('5,499') and not rendered('111'),'timeout selector borrowed another base count')
assert(rendered('Storage: Base 2 of 2, each base stops on its own count - change base'))
assert(network.client().status=='ready','storage expiry changed settings readiness')
assert(writes==0,'storage selection wrote limits')
assert(stale==0,'storage roundtrip touched stale widgets')
]=]
assert(load(source:sub(1,boundary-1)..'\n'..scenario,'@panel-stock-roundtrip-fixture'))()
print('PASS real panel storage: delayed/queued selection, expiry, unavailable metadata and same-base renewal')

